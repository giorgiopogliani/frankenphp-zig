#ifndef FRANKENPHP_ZIG_PHP_SAPI_H
#define FRANKENPHP_ZIG_PHP_SAPI_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *script_filename;
    const char *request_method;
    const char *request_uri;
    const char *query_string;
    const char *content_type;
    int64_t content_length;
    int headers_only;
} frankenphp_zig_request;

int frankenphp_zig_php_init(void);
void frankenphp_zig_php_shutdown(void);
int frankenphp_zig_php_is_zts(void);
void frankenphp_zig_php_thread_init(void);
void frankenphp_zig_php_thread_shutdown(void);
int frankenphp_zig_php_execute(const frankenphp_zig_request *request);
int frankenphp_zig_php_execute_worker(const frankenphp_zig_request *request);

/* Implemented by PhpRuntime.zig and called only from the PHP runtime thread. */
size_t frankenphp_zig_write(const char *bytes, size_t length);
size_t frankenphp_zig_read_post(char *buffer, size_t length);
const char *frankenphp_zig_read_cookies(void);
size_t frankenphp_zig_variable_count(void);
const char *frankenphp_zig_variable_name(size_t index);
const char *frankenphp_zig_variable_value(size_t index, size_t *length);
const char *frankenphp_zig_getenv(const char *name, size_t name_length);
int frankenphp_zig_set_status(int status);
int frankenphp_zig_add_header(const char *header, size_t length);
void frankenphp_zig_log(const char *message);
const frankenphp_zig_request *frankenphp_zig_worker_acquire(void);
void frankenphp_zig_worker_complete(int success);

#endif
