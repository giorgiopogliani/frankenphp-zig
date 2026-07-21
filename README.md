# FrankenPHP Zig

A Caddy-free PHP application server written in Zig 0.16.

The Zig executable owns HTTP serving, PHP routing, and request scheduling. PHP is linked into the executable through a small custom SAPI
bridge, initialized once, and executed in-process. The server never launches
`php`, `php-cgi`, or another PHP child process.

## Requirements

- Zig 0.16.0
- Standard PHP build prerequisites, including a C compiler, `make`, `curl`,
  `tar`, `pkg-config`, and ICU development files for `intl`.

## Build

```console
zig build
```

The default build downloads and SHA-256 verifies the currently pinned stable
PHP source release from php.net into `.phpsrc/php-<version>/`, then builds
PHP's embed library locally. To download only the source, run
`zig build fetch-php`. Update the version and its audited digest together in
`build.zig` when upgrading PHP.

The default bootstrap builds PHP's static embed library (`libphp.a`) under
`.phpsrc/embed`. Its PHP code is linked into the FrankenPHP executable; operating
system libraries used by PHP extensions may still be dynamic. Pass
`-Dphp-prefix=/path/to/php` to use an existing static embed-enabled PHP
installation. A nonstandard library name can be selected with
`-Dphp-library=name`.

The default build configures and installs PHP's static embed SAPI automatically.

The binary is written to `zig-out/bin/frankenphp`.

## Run a PHP application

```console
zig-out/bin/frankenphp run --root public --port 8080
```

The server resolves requests in this order:

1. Existing `*.php` paths are executed by embedded PHP.
2. All other paths fall back to the document root's `index.php`, with the
   original path exposed through `PATH_INFO`.

URL paths are percent-decoded and normalized before filesystem access.
Traversal components, NUL bytes, and backslash-based separator bypasses are
rejected.

### Options

```text
--port PORT         Listen port (default: 8080)
--root PATH         Document root (default: current directory)
--max-body SIZE     Maximum request body (default: 10m)
--max-output SIZE   Maximum PHP response size (default: 16m)
--max-connections N Maximum concurrent connections (default: 128)
--request-timeout N HTTP request deadline in seconds (default: 30)
```

Sizes accept `k`, `m`, and `g` suffixes.

## Laravel Octane worker mode

Laravel Octane can launch the binary directly:

```console
php artisan octane:start --server=frankenphp --workers=1
```

Octane invokes `frankenphp run -c <path>`. The `-c` value is accepted for
compatibility but the Caddyfile is not read. Worker mode instead uses Octane's
environment and always boots `${APP_PUBLIC_PATH}/frankenphp-worker.php` inside
the embedded PHP runtime. The Laravel application remains booted while request
state is reset between calls to `frankenphp_handle_request()`.

The current runtime uses one persistent PHP worker. `MAX_REQUESTS` is honored
by the Octane worker script, which is restarted in-process when its request
limit is reached.

## Embedded runtime

PHP module startup and shutdown happen once on a dedicated native thread. Each
HTTP request receives its own `php_request_startup()` / `php_request_shutdown()`
cycle. Zig implements the SAPI callbacks for request bodies, cookies,
`$_SERVER`, response headers, logging, and output.

The initial runtime intentionally uses one PHP execution thread. This safely
supports both NTS and ZTS PHP builds while keeping the engine persistent. PHP
requests are queued onto the runtime thread. A ZTS worker pool is future work.

The HTTP deadline closes timed-out connections and safely abandons their
response, but it does not forcibly interrupt PHP code already running in the
embedded thread.

## Test

```console
zig build unit-test
zig build test -Dphp-prefix=/opt/php-embed
zig build check -Dphp-prefix=/opt/php-embed
php -l tests/index.php
```

For the behavior test, start the server against the fixture and send a request:

```console
zig-out/bin/frankenphp run --root tests --port 8080
curl -X POST 'http://127.0.0.1:8080/example?source=test' --data 'embedded-body'
```

The JSON response includes PHP's process ID. Repeated requests return the same
ID because they execute inside the persistent Zig server process.

## Current scope

This rewrite provides bounded concurrent HTTP/1.1 serving, keep-alive,
persistent embedded PHP request execution, front-controller routing,
SAPI header/status handling, request bodies, and safe cancellation of queued
responses.

The previous Caddy integration supplied automatic TLS, HTTP/2, HTTP/3,
Mercure, Vulcain, hot reload, metrics, and other features. Those need native
Zig implementations before feature parity can be claimed.
