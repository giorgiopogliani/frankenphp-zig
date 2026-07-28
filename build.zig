const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const php_prefix_option = b.option(
        []const u8,
        "php-prefix",
        "Prefix containing a static embed-enabled PHP in include/php and lib",
    );
    const php_prefix = php_prefix_option orelse ".phpsrc/embed";
    const php_bootstrap = if (php_prefix_option == null) addPhpBootstrapStep(b, addFetchPhpStep(b)) else null;
    if (php_bootstrap) |bootstrap| {
        b.step("php-bootstrap", "Build the embedded PHP runtime").dependOn(&bootstrap.step);
    }
    const php_library = b.option(
        []const u8,
        "php-library",
        "Embed PHP library name (default: php)",
    ) orelse "php";

    const executable_module = embeddedPhpModule(b, b.path("src/main.zig"), target, optimize, php_prefix, php_library);
    const frankenphp = b.addExecutable(.{
        .name = "frankenphp",
        .root_module = executable_module,
    });
    if (php_bootstrap) |bootstrap| frankenphp.step.dependOn(&bootstrap.step);
    b.installArtifact(frankenphp);

    const run = b.addRunArtifact(frankenphp);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the Caddy-free FrankenPHP server").dependOn(&run.step);

    const unit_test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addHttpxImport(b, unit_test_module, target, optimize);
    const tests = b.addTest(.{ .root_module = unit_test_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("unit-test", "Run unit tests that do not require libphp").dependOn(&run_tests.step);

    const integration_module = embeddedPhpModule(
        b,
        b.path("src/embedded_test.zig"),
        target,
        optimize,
        php_prefix,
        php_library,
    );
    const integration_options = b.addOptions();
    integration_options.addOption([]const u8, "fixture_path", b.pathFromRoot("tests/index.php"));
    integration_options.addOption([]const u8, "mbstring_fixture_path", b.pathFromRoot("tests/mbstring.php"));
    integration_options.addOption([]const u8, "pdo_fixture_path", b.pathFromRoot("tests/pdo.php"));
    integration_options.addOption([]const u8, "sodium_fixture_path", b.pathFromRoot("tests/sodium.php"));
    integration_options.addOption([]const u8, "intl_fixture_path", b.pathFromRoot("tests/intl.php"));
    integration_options.addOption([]const u8, "worker_fixture_path", b.pathFromRoot("tests/frankenphp-worker.php"));
    integration_options.addOption([]const u8, "worker_exit_fixture_path", b.pathFromRoot("tests/worker-exit.php"));
    integration_module.addOptions("build_options", integration_options);
    const integration_tests = b.addTest(.{ .root_module = integration_module });
    if (php_bootstrap) |bootstrap| integration_tests.step.dependOn(&bootstrap.step);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    b.step("integration-test", "Run the embedded PHP integration test").dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run unit and embedded PHP integration tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    const check = b.addExecutable(.{
        .name = "frankenphp",
        .root_module = embeddedPhpModule(b, b.path("src/main.zig"), target, optimize, php_prefix, php_library),
    });
    if (php_bootstrap) |bootstrap| check.step.dependOn(&bootstrap.step);
    b.step("check", "Compile the executable without installing it").dependOn(&check.step);
}

fn addFetchPhpStep(b: *std.Build) *std.Build.Step.Run {
    const php_version = "8.5.8";
    const php_sha256 = "6ebc55e52af4396385e689f7af0f28944fbbf966843433b573e9dc1dc03df539";
    const fetch = b.addSystemCommand(&.{
        "sh",        "-eu",       "-c",
        \\php_version="$1"
        \\expected_sha256="$2"
        \\source_root='.phpsrc'
        \\mkdir -p "$source_root"
        \\source_dir="$source_root/php-$php_version"
        \\archive="$source_root/php-$php_version.tar.gz"
        \\temporary_archive="$archive.tmp"
        \\trap 'rm -f "$temporary_archive"' EXIT
        \\if [ ! -f "$archive" ]; then
        \\    curl --fail --location --silent --show-error "https://www.php.net/distributions/php-$php_version.tar.gz" --output "$temporary_archive"
        \\    mv "$temporary_archive" "$archive"
        \\fi
        \\if command -v sha256sum >/dev/null 2>&1; then
        \\    actual_sha256="$(sha256sum "$archive" | awk '{print $1}')"
        \\else
        \\    actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
        \\fi
        \\if [ "$actual_sha256" != "$expected_sha256" ]; then
        \\    echo "PHP source checksum mismatch for $php_version." >&2
        \\    exit 1
        \\fi
        \\trap - EXIT
        \\if [ ! -f "$source_dir/main/php.h" ]; then
        \\    tar -xzf "$archive" -C "$source_root"
        \\fi
        \\ln -sfn "php-$php_version" "$source_root/current"
        \\printf '%s\n' "$php_version" > "$source_root/current-version"
        ,
        "fetch-php", php_version, php_sha256,
    });
    fetch.setCwd(b.path("."));
    b.step("fetch-php", "Download the latest stable PHP source into .phpsrc").dependOn(&fetch.step);
    return fetch;
}

fn addPhpBootstrapStep(b: *std.Build, fetch_php: *std.Build.Step.Run) *std.Build.Step.Run {
    const bootstrap = b.addSystemCommand(&.{
        "sh", "-eu", "-c",
        \\php_prefix='.phpsrc/embed'
        \\php_version="$(cat .phpsrc/current-version)"
        \\php_build_id="$php_version:static-embed-v5-zts-openssl-sodium"
        \\if [ -f "$php_prefix/php-version" ] && [ "$(cat "$php_prefix/php-version")" = "$php_build_id" ] && find "$php_prefix/lib" -maxdepth 1 -name 'libphp.*' -type f | grep -q .; then
        \\    exit 0
        \\fi
        \\source_dir='.phpsrc/current'
        \\test -x "$source_dir/configure"
        \\if ! pkg-config --exists icu-uc icu-io icu-i18n && command -v brew >/dev/null 2>&1; then
        \\    icu_prefix="$(brew --prefix icu4c)"
        \\    if [ -d "$icu_prefix/lib/pkgconfig" ]; then
        \\        export PKG_CONFIG_PATH="$icu_prefix/lib/pkgconfig"
        \\    fi
        \\fi
        \\pkg-config --exists icu-uc icu-io icu-i18n
        \\if ! pkg-config --exists openssl && command -v brew >/dev/null 2>&1; then
        \\    openssl_prefix="$(brew --prefix openssl@3)"
        \\    if [ -d "$openssl_prefix/lib/pkgconfig" ]; then
        \\        export PKG_CONFIG_PATH="$openssl_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        \\    fi
        \\fi
        \\pkg-config --exists openssl
        \\if ! pkg-config --exists libxml-2.0 && command -v brew >/dev/null 2>&1; then
        \\    libxml_prefix="$(brew --prefix libxml2)"
        \\    if [ -d "$libxml_prefix/lib/pkgconfig" ]; then
        \\        export PKG_CONFIG_PATH="$libxml_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        \\    fi
        \\fi
        \\pkg-config --exists libxml-2.0
        \\if ! pkg-config --exists libsodium && command -v brew >/dev/null 2>&1; then
        \\    sodium_prefix="$(brew --prefix libsodium)"
        \\    if [ -d "$sodium_prefix/lib/pkgconfig" ]; then
        \\        export PKG_CONFIG_PATH="$sodium_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        \\    fi
        \\fi
        \\pkg-config --exists libsodium
        \\iconv_option=''
        \\if iconv_prefix="$(pkg-config --variable=prefix libiconv 2>/dev/null)"; then
        \\    iconv_option="--with-iconv=$iconv_prefix"
        \\fi
        \\jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)"
        \\(
        \\    cd "$source_dir"
        \\    rm -f config.cache config.log config.nice
        \\    ./configure --prefix="$(cd ../.. && pwd)/$php_prefix" --enable-embed=static --enable-zts --disable-cgi --disable-phpdbg --enable-dom --enable-simplexml --enable-xml --enable-xmlreader --enable-xmlwriter --enable-mbstring --enable-intl --enable-pcntl $iconv_option --with-openssl --with-sodium --with-mysqlnd-ssl --with-pdo-mysql=mysqlnd
        \\    make clean
        \\    make -j "$jobs"
        \\    make install
        \\)
        \\printf '%s\n' "$php_build_id" > "$php_prefix/php-version"
        \\find "$php_prefix/lib" -maxdepth 1 -name 'libphp.*' -type f | grep -q .
    });
    bootstrap.setCwd(b.path("."));
    bootstrap.step.dependOn(&fetch_php.step);
    return bootstrap;
}

fn embeddedPhpModule(
    b: *std.Build,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    php_prefix: []const u8,
    php_library: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const include_root = b.pathJoin(&.{ php_prefix, "include", "php" });
    const include_subdirectories = [_][]const u8{ "", "main", "TSRM", "Zend", "ext", "ext/date/lib" };
    for (&include_subdirectories) |subdirectory| {
        const include_path = if (subdirectory.len == 0)
            include_root
        else
            b.pathJoin(&.{ include_root, subdirectory });
        module.addSystemIncludePath(.{ .cwd_relative = include_path });
    }

    const library_path = b.pathJoin(&.{ php_prefix, "lib" });
    module.addLibraryPath(.{ .cwd_relative = library_path });
    module.linkSystemLibrary(php_library, .{
        .use_pkg_config = .no,
        .preferred_link_mode = .static,
        .search_strategy = .paths_first,
    });
    linkPhpDependencies(module, target);
    module.addCSourceFile(.{
        .file = b.path("src/php_sapi.c"),
        // PHP's Linux headers require POSIX signal and jump-buffer APIs.
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    addHttpxImport(b, module, target, optimize);
    return module;
}

fn addHttpxImport(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const httpx = b.dependency("httpx", .{
        .target = target,
        .optimize = optimize,
    });
    module.addImport("httpx", httpx.module("httpx"));
}

fn linkPhpDependencies(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .macos) {
        const homebrew_library_paths = [_][]const u8{
            "/opt/homebrew/opt/icu4c/lib",
            "/opt/homebrew/opt/libiconv/lib",
            "/opt/homebrew/opt/openssl@3/lib",
            "/opt/homebrew/opt/libsodium/lib",
            "/opt/homebrew/opt/libxml2/lib",
            "/opt/homebrew/opt/oniguruma/lib",
        };
        for (&homebrew_library_paths) |path| {
            module.addLibraryPath(.{ .cwd_relative = path });
        }
    }

    const common_dependencies = [_][]const u8{
        "onig",
        "ssl",
        "crypto",
        "sodium",
        "xml2",
        "sqlite3",
        "icuio",
        "icui18n",
        "icuuc",
        "icudata",
        "resolv",
        "z",
    };
    for (&common_dependencies) |dependency| {
        module.linkSystemLibrary(dependency, .{
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .paths_first,
        });
    }
    if (target.result.os.tag == .macos) {
        module.linkSystemLibrary("iconv", .{
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .paths_first,
        });
    }

    if (target.result.os.tag == .macos) {
        module.linkSystemLibrary("c++", .{
            .use_pkg_config = .no,
            .preferred_link_mode = .dynamic,
            .search_strategy = .paths_first,
        });
    } else if (target.result.os.tag == .linux) {
        // PHP's intl extension is built with GNU libstdc++. Link its ABI
        // library directly because Zig maps a "stdc++" system library to
        // libc++, which has an incompatible ABI.
        const libstdcxx_path = switch (target.result.cpu.arch) {
            .x86_64 => "/usr/lib/x86_64-linux-gnu/libstdc++.so.6",
            .aarch64 => "/usr/lib/aarch64-linux-gnu/libstdc++.so.6",
            else => @panic("unsupported Linux C++ runtime architecture"),
        };
        const libgcc_path = switch (target.result.cpu.arch) {
            .x86_64 => "/usr/lib/x86_64-linux-gnu/libgcc_s.so.1",
            .aarch64 => "/usr/lib/aarch64-linux-gnu/libgcc_s.so.1",
            else => @panic("unsupported Linux C++ runtime architecture"),
        };
        const libgcc_static_path = switch (target.result.cpu.arch) {
            .x86_64 => "/usr/lib/gcc/x86_64-linux-gnu/12/libgcc.a",
            .aarch64 => "/usr/lib/gcc/aarch64-linux-gnu/12/libgcc.a",
            else => @panic("unsupported Linux C++ runtime architecture"),
        };
        module.addObjectFile(.{ .cwd_relative = libstdcxx_path });
        module.addObjectFile(.{ .cwd_relative = libgcc_path });
        module.addObjectFile(.{ .cwd_relative = libgcc_static_path });
    }
}
