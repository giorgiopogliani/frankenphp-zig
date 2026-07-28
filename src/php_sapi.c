#include "php_sapi.h"

#include <signal.h>
#include <string.h>

#include "php.h"
#include "php_main.h"
#include "php_output.h"
#include "php_streams.h"
#include "php_variables.h"
#include "SAPI.h"
#include "zend_exceptions.h"
#include "zend_signal.h"

#ifdef HAVE_PHP_SESSION
#include "ext/session/php_session.h"
#endif

static const char FRANKENPHP_INI[] =
    "html_errors=0\n"
    "implicit_flush=1\n"
    "output_buffering=0\n"
    "max_execution_time=0\n"
    "max_input_time=-1\n"
    "expose_php=0\n";

static const char *WORKER_MODULES_TO_RELOAD[] = {"filter", NULL};
ZEND_TLS int frankenphp_worker_mode = 0;
ZEND_TLS int frankenphp_worker_booting = 0;

PHP_FUNCTION(frankenphp_handle_request);

ZEND_BEGIN_ARG_WITH_RETURN_TYPE_INFO_EX(arginfo_frankenphp_handle_request, 0, 1, _IS_BOOL, 0)
    ZEND_ARG_TYPE_INFO(0, callback, IS_CALLABLE, 0)
ZEND_END_ARG_INFO()

static const zend_function_entry frankenphp_functions[] = {
    ZEND_FE(frankenphp_handle_request, arginfo_frankenphp_handle_request)
    ZEND_FE_END
};

static zend_module_entry frankenphp_module = {
    STANDARD_MODULE_HEADER,
    "frankenphp",
    frankenphp_functions,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    "0.1.0",
    STANDARD_MODULE_PROPERTIES
};

#if defined(PHP_WIN32) && defined(ZTS)
ZEND_TSRMLS_CACHE_DEFINE()
#endif

static int frankenphp_startup(sapi_module_struct *module)
{
    return php_module_startup(module, &frankenphp_module);
}

static int frankenphp_deactivate(void)
{
    return SUCCESS;
}

static size_t frankenphp_write(const char *bytes, size_t length)
{
    size_t written = frankenphp_zig_write(bytes, length);
    if (written != length) {
        php_handle_aborted_connection();
    }
    return written;
}

static void frankenphp_flush(void *server_context)
{
    (void) server_context;
    sapi_send_headers();
}

static char *frankenphp_getenv(const char *name, size_t name_length)
{
    return (char *) frankenphp_zig_getenv(name, name_length);
}

static int frankenphp_send_headers(sapi_headers_struct *headers)
{
    int status = headers->http_response_code;
    if (status == 0) {
        status = 200;
    }
    if (!frankenphp_zig_set_status(status)) {
        return SAPI_HEADER_SEND_FAILED;
    }

    zend_llist_position position;
    sapi_header_struct *header = zend_llist_get_first_ex(&headers->headers, &position);
    while (header != NULL) {
        if (!frankenphp_zig_add_header(header->header, header->header_len)) {
            return SAPI_HEADER_SEND_FAILED;
        }
        header = zend_llist_get_next_ex(&headers->headers, &position);
    }

    return SAPI_HEADER_SENT_SUCCESSFULLY;
}

static size_t frankenphp_read_post(char *buffer, size_t length)
{
    return frankenphp_zig_read_post(buffer, length);
}

static char *frankenphp_read_cookies(void)
{
    return (char *) frankenphp_zig_read_cookies();
}

static void frankenphp_register_variables(zval *track_vars_array)
{
    size_t count = frankenphp_zig_variable_count();
    for (size_t index = 0; index < count; index++) {
        size_t value_length = 0;
        const char *name = frankenphp_zig_variable_name(index);
        const char *value = frankenphp_zig_variable_value(index, &value_length);
        if (name != NULL && value != NULL) {
            php_register_variable_safe(name, value, value_length, track_vars_array);
        }
    }
}

static void frankenphp_log(const char *message, int syslog_type)
{
    (void) syslog_type;
    frankenphp_zig_log(message);
}

static void frankenphp_set_request(const frankenphp_zig_request *request)
{
    SG(server_context) = (void *) request;
    SG(request_info).request_method = request->request_method;
    SG(request_info).query_string = (char *) request->query_string;
    SG(request_info).path_translated = (char *) request->script_filename;
    SG(request_info).request_uri = (char *) request->request_uri;
    SG(request_info).content_type = request->content_type;
    SG(request_info).content_length = (zend_long) request->content_length;
    SG(request_info).headers_only = request->headers_only != 0;
    SG(request_info).no_headers = 0;
    SG(sapi_headers).http_response_code = 200;
}

static void frankenphp_clear_request(void)
{
    SG(request_info).request_method = NULL;
    SG(request_info).query_string = NULL;
    SG(request_info).path_translated = NULL;
    SG(request_info).request_uri = NULL;
    SG(request_info).content_type = NULL;
    SG(server_context) = NULL;
}

static void frankenphp_reset_super_globals(void)
{
    zend_try {
        zval *files = &PG(http_globals)[TRACK_VARS_FILES];
        zval_ptr_dtor_nogc(files);
        memset(files, 0, sizeof(*files));
        zend_hash_str_del(&EG(symbol_table), "_SESSION", sizeof("_SESSION") - 1);
    } zend_end_try();

    zend_auto_global *auto_global;
    zend_string *env = ZSTR_KNOWN(ZEND_STR_AUTOGLOBAL_ENV);
    zend_string *server = ZSTR_KNOWN(ZEND_STR_AUTOGLOBAL_SERVER);
    ZEND_HASH_MAP_FOREACH_PTR(CG(auto_globals), auto_global) {
        if (auto_global->name == env) {
            continue;
        }
        if (auto_global->name == server) {
            auto_global->armed = auto_global->auto_global_callback(auto_global->name);
        } else if (auto_global->jit) {
            if (auto_global->name == ZSTR_KNOWN(ZEND_STR_AUTOGLOBAL_REQUEST) &&
                zend_hash_exists(&EG(symbol_table), auto_global->name)) {
                auto_global->armed = auto_global->auto_global_callback(auto_global->name);
            }
        } else if (auto_global->auto_global_callback) {
            auto_global->armed = auto_global->auto_global_callback(auto_global->name);
        } else {
            auto_global->armed = 0;
        }
    } ZEND_HASH_FOREACH_END();
}

static void frankenphp_release_temporary_streams(void)
{
    zend_resource *resource;
    int stream_type = php_file_le_stream();
    ZEND_HASH_FOREACH_PTR(&EG(regular_list), resource) {
        if (resource->type != stream_type) {
            continue;
        }
        php_stream *stream = (php_stream *) resource->ptr;
        if (stream && stream->ops == &php_stream_temp_ops &&
            stream->__exposed == 0 && GC_REFCOUNT(resource) == 1) {
            ZEND_ASSERT(!stream->is_persistent);
            zend_list_delete(resource);
        }
    } ZEND_HASH_FOREACH_END();
}

#ifdef HAVE_PHP_SESSION
static void frankenphp_reset_session(void)
{
    if (PS(session_status) == php_session_active) {
        php_session_flush(1);
    }
    if (!Z_ISUNDEF(PS(http_session_vars))) {
        zval_ptr_dtor(&PS(http_session_vars));
        ZVAL_UNDEF(&PS(http_session_vars));
    }
    if (PS(mod_data) || PS(mod_user_implemented)) {
        zend_try { PS(mod)->s_close(&PS(mod_data)); } zend_end_try();
    }
    if (PS(id)) {
        zend_string_release_ex(PS(id), 0);
        PS(id) = NULL;
    }
    if (PS(session_vars)) {
        zend_string_release_ex(PS(session_vars), 0);
        PS(session_vars) = NULL;
    }
#if PHP_VERSION_ID >= 80300
    if (PS(session_started_filename)) {
        zend_string_release(PS(session_started_filename));
        PS(session_started_filename) = NULL;
        PS(session_started_lineno) = 0;
    }
#endif
    PS(session_status) = php_session_none;
    PS(in_save_handler) = 0;
    PS(set_handler) = 0;
    PS(mod_data) = NULL;
    PS(mod_user_is_open) = 0;
    PS(define_sid) = 1;
}
#endif

static void frankenphp_worker_request_shutdown(void)
{
    zend_try { php_output_end_all(); } zend_end_try();

    const char **module_name;
    zend_module_entry *module;
    for (module_name = WORKER_MODULES_TO_RELOAD; *module_name; module_name++) {
        module = zend_hash_str_find_ptr(&module_registry, *module_name, strlen(*module_name));
        if (module && module->request_shutdown_func) {
            module->request_shutdown_func(module->type, module->module_number);
        }
    }

#ifdef HAVE_PHP_SESSION
    frankenphp_reset_session();
#endif

    zend_try { php_output_deactivate(); } zend_end_try();
    zend_try { sapi_deactivate(); } zend_end_try();
    frankenphp_clear_request();
    zend_set_memory_limit(PG(memory_limit));
}

static int frankenphp_worker_request_startup(const frankenphp_zig_request *request)
{
    int result = SUCCESS;
    frankenphp_set_request(request);

    zend_try {
        frankenphp_release_temporary_streams();
        php_output_activate();
        PG(header_is_being_sent) = 0;
        PG(connection_status) = PHP_CONNECTION_NORMAL;
        sapi_activate();

        if (PG(output_handler) && PG(output_handler)[0]) {
            zval output_handler;
            ZVAL_STRING(&output_handler, PG(output_handler));
            php_output_start_user(&output_handler, 0, PHP_OUTPUT_HANDLER_STDFLAGS);
            zval_ptr_dtor(&output_handler);
        } else if (PG(output_buffering)) {
            php_output_start_user(NULL, PG(output_buffering) > 1 ? PG(output_buffering) : 0,
                                  PHP_OUTPUT_HANDLER_STDFLAGS);
        } else if (PG(implicit_flush)) {
            php_output_set_implicit_flush(1);
        }

        frankenphp_reset_super_globals();

        const char **module_name;
        zend_module_entry *module;
        for (module_name = WORKER_MODULES_TO_RELOAD; *module_name; module_name++) {
            module = zend_hash_str_find_ptr(&module_registry, *module_name, strlen(*module_name));
            if (module && module->request_startup_func) {
                module->request_startup_func(module->type, module->module_number);
            }
        }
    } zend_catch {
        if (PG(last_error_message)) {
            frankenphp_zig_log(ZSTR_VAL(PG(last_error_message)));
        }
        result = FAILURE;
    } zend_end_try();

    SG(sapi_started) = 1;
    return result;
}

static void frankenphp_register_standard_streams(void)
{
    if (zend_get_constant_str("STDERR", sizeof("STDERR") - 1) != NULL) {
        return;
    }

    php_stream *input = php_stream_open_wrapper("php://stdin", "rb", 0, NULL);
    php_stream *output = php_stream_open_wrapper("php://stdout", "wb", 0, NULL);
    php_stream *error = php_stream_open_wrapper("php://stderr", "wb", 0, NULL);
    if (!input || !output || !error) {
        if (input) php_stream_close(input);
        if (output) php_stream_close(output);
        if (error) php_stream_close(error);
        return;
    }

    input->flags |= PHP_STREAM_FLAG_NO_RSCR_DTOR_CLOSE;
    output->flags |= PHP_STREAM_FLAG_NO_RSCR_DTOR_CLOSE;
    error->flags |= PHP_STREAM_FLAG_NO_RSCR_DTOR_CLOSE;

    zend_constant input_constant;
    zend_constant output_constant;
    zend_constant error_constant;
    php_stream_to_zval(input, &input_constant.value);
    php_stream_to_zval(output, &output_constant.value);
    php_stream_to_zval(error, &error_constant.value);

    ZEND_CONSTANT_SET_FLAGS(&input_constant, CONST_CS, 0);
    input_constant.name = zend_string_init_interned("STDIN", sizeof("STDIN") - 1, 0);
    zend_register_constant(&input_constant);
    ZEND_CONSTANT_SET_FLAGS(&output_constant, CONST_CS, 0);
    output_constant.name = zend_string_init_interned("STDOUT", sizeof("STDOUT") - 1, 0);
    zend_register_constant(&output_constant);
    ZEND_CONSTANT_SET_FLAGS(&error_constant, CONST_CS, 0);
    error_constant.name = zend_string_init_interned("STDERR", sizeof("STDERR") - 1, 0);
    zend_register_constant(&error_constant);
}

PHP_FUNCTION(frankenphp_handle_request)
{
    zend_fcall_info fci;
    zend_fcall_info_cache fcc;

    ZEND_PARSE_PARAMETERS_START(1, 1)
        Z_PARAM_FUNC(fci, fcc)
    ZEND_PARSE_PARAMETERS_END();

    if (!frankenphp_worker_mode) {
        php_error(E_WARNING, "frankenphp_handle_request() called outside worker mode");
        RETURN_FALSE;
    }

    if (frankenphp_worker_booting) {
        frankenphp_worker_booting = 0;
        frankenphp_worker_request_shutdown();
    }

    const frankenphp_zig_request *request = frankenphp_zig_worker_acquire();
    if (request == NULL) {
        RETURN_FALSE;
    }
    if (frankenphp_worker_request_startup(request) == FAILURE) {
        frankenphp_worker_request_shutdown();
        frankenphp_zig_worker_complete(0);
        RETURN_FALSE;
    }

    zval retval;
    ZVAL_UNDEF(&retval);
    fci.size = sizeof(fci);
    fci.retval = &retval;
    fci.params = NULL;
    fci.param_count = 0;

    int success = zend_call_function(&fci, &fcc) == SUCCESS;
    if (EG(exception)) {
        if (!zend_is_unwind_exit(EG(exception)) && !zend_is_graceful_exit(EG(exception))) {
            zend_exception_error(EG(exception), E_ERROR);
        } else {
            zend_bailout();
        }
        success = 0;
    }

    frankenphp_worker_request_shutdown();
    frankenphp_zig_worker_complete(success);
    if (!Z_ISUNDEF(retval)) {
        zval_ptr_dtor(&retval);
    }
    RETURN_TRUE;
}

static sapi_module_struct frankenphp_sapi_module = {
    "frankenphp-zig",
    "FrankenPHP Zig Embedded SAPI",

    frankenphp_startup,
    php_module_shutdown_wrapper,

    NULL,
    frankenphp_deactivate,

    frankenphp_write,
    frankenphp_flush,
    NULL,
    frankenphp_getenv,

    php_error,

    NULL,
    frankenphp_send_headers,
    NULL,

    frankenphp_read_post,
    frankenphp_read_cookies,

    frankenphp_register_variables,
    frankenphp_log,
    NULL,
    NULL,

    STANDARD_SAPI_MODULE_PROPERTIES
};

int frankenphp_zig_php_init(void)
{
#if defined(SIGPIPE) && defined(SIG_IGN)
    signal(SIGPIPE, SIG_IGN);
#endif

#ifdef ZTS
    if (!php_tsrm_startup()) {
        return FAILURE;
    }
#ifdef PHP_WIN32
    ZEND_TSRMLS_CACHE_UPDATE();
#endif
#endif

    zend_signal_startup();
    sapi_startup(&frankenphp_sapi_module);
    frankenphp_sapi_module.ini_entries = FRANKENPHP_INI;

    if (frankenphp_sapi_module.startup(&frankenphp_sapi_module) == FAILURE) {
        sapi_shutdown();
#ifdef ZTS
        tsrm_shutdown();
#endif
        return FAILURE;
    }

    SG(options) |= SAPI_OPTION_NO_CHDIR;
    return SUCCESS;
}

void frankenphp_zig_php_shutdown(void)
{
    frankenphp_sapi_module.shutdown(&frankenphp_sapi_module);
    sapi_shutdown();
#ifdef ZTS
    tsrm_shutdown();
#endif
}

int frankenphp_zig_php_is_zts(void)
{
#ifdef ZTS
    return 1;
#else
    return 0;
#endif
}

void frankenphp_zig_php_thread_init(void)
{
#ifdef ZTS
    (void)ts_resource(0);
#ifdef PHP_WIN32
    ZEND_TSRMLS_CACHE_UPDATE();
#endif
#endif
}

void frankenphp_zig_php_thread_shutdown(void)
{
#ifdef ZTS
    ts_free_thread();
#endif
}

int frankenphp_zig_php_execute(const frankenphp_zig_request *request)
{
    int request_started = 0;
    int result = SUCCESS;

    frankenphp_set_request(request);

    zend_first_try {
        if (php_request_startup() == FAILURE) {
            result = FAILURE;
        } else {
            request_started = 1;
            if (frankenphp_worker_mode) {
                frankenphp_register_standard_streams();
            }

            zend_file_handle file_handle;
            zend_stream_init_filename(&file_handle, request->script_filename);
            file_handle.primary_script = 1;
            EG(exit_status) = 0;

            php_execute_script(&file_handle);
            zend_destroy_file_handle(&file_handle);
        }
    } zend_catch {
        if (PG(last_error_message)) {
            frankenphp_zig_log(ZSTR_VAL(PG(last_error_message)));
        }
        result = FAILURE;
    } zend_end_try();

    if (request_started) {
        zend_try {
            php_request_shutdown(NULL);
        } zend_catch {
            result = FAILURE;
        } zend_end_try();
    }

    frankenphp_clear_request();
    return result;
}

int frankenphp_zig_php_execute_worker(const frankenphp_zig_request *request)
{
    frankenphp_worker_mode = 1;
    frankenphp_worker_booting = 1;
    int result = frankenphp_zig_php_execute(request);
    if (EG(exit_status) != 0) {
        if (PG(last_error_message)) {
            frankenphp_zig_log(ZSTR_VAL(PG(last_error_message)));
        }
        result = FAILURE;
    }
    frankenphp_worker_booting = 0;
    frankenphp_worker_mode = 0;
    return result;
}
