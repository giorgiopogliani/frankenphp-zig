const Server = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const httpx = @import("httpx");
const Config = @import("Config.zig");
const HttpxRequest = @import("HttpxRequest.zig");
const PhpRuntime = @import("PhpRuntime.zig");
const routing = @import("routing.zig");

// httpx handlers are plain function pointers. FrankenPHP runs exactly one
// process-wide application server, so the adapter keeps the active instance at
// the executable boundary rather than introducing request-global state.
var active_server: ?*Server = null;

io: Io,
gpa: Allocator,
parent_environ: *const std.process.Environ.Map,
config: Config,
document_root_path: []const u8,
document_root: Io.Dir,
php_runtimes: *PhpRuntime.Pool,

pub fn run(
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    parent_environ: *const std.process.Environ.Map,
    config: Config,
) !void {
    const cwd = try std.process.currentPathAlloc(io, arena);
    const document_root_path = try std.fs.path.resolve(arena, &.{ cwd, config.document_root });
    var document_root = try Io.Dir.cwd().openDir(io, document_root_path, .{});
    defer document_root.close(io);

    const worker = if (config.mode == .worker) worker: {
        const variables = try arena.alloc(PhpRuntime.Variable, parent_environ.keys().len + 1);
        for (parent_environ.keys(), parent_environ.values(), variables[0 .. variables.len - 1]) |name, value, *variable| {
            variable.* = .{ .name = name, .value = value };
        }
        variables[variables.len - 1] = .{ .name = "FRANKENPHP_WORKER", .value = "1" };
        break :worker PhpRuntime.Worker{
            .script_filename = try std.fs.path.join(arena, &.{ document_root_path, config.worker_script }),
            .variables = variables,
        };
    } else null;

    var php_runtimes = try PhpRuntime.Pool.start(io, gpa, config.max_php_output, worker, config.php_workers);
    defer php_runtimes.stop();

    var app: Server = .{
        .io = io,
        .gpa = gpa,
        .parent_environ = parent_environ,
        .config = config,
        .document_root_path = document_root_path,
        .document_root = document_root,
        .php_runtimes = &php_runtimes,
    };

    const worker_threads = @max(@as(usize, 1), @min(
        config.max_connections,
        std.Thread.getCpuCount() catch 1,
    ));
    var http_server = httpx.Server.initWithConfig(gpa, .{
        .host = config.listen_host,
        .port = config.listen_port,
        .max_body_size = config.max_request_body,
        .request_timeout_ms = @as(u64, config.request_timeout_seconds) * 1000,
        .keep_alive_timeout_ms = @as(u64, config.request_timeout_seconds) * 1000,
        .max_connections = @intCast(@min(config.max_connections, std.math.maxInt(u32))),
        .threads = @intCast(@min(worker_threads, std.math.maxInt(u32))),
        .log_fn = discardHttpxLog,
    });
    defer http_server.deinit();

    try http_server.any("/", handleHttpxRequest);
    try http_server.any("/*", handleHttpxRequest);

    if (active_server != null) return error.ServerAlreadyRunning;
    active_server = &app;
    defer active_server = null;

    std.log.info("serving {s} at http://{s}:{d}", .{
        document_root_path,
        config.listen_host,
        config.listen_port,
    });
    try http_server.listen();
}

fn discardHttpxLog(_: httpx.LogLevel, _: []const u8) void {}

fn handleHttpxRequest(context: *httpx.Context) !httpx.Response {
    const server = active_server orelse return error.ServerNotRunning;
    return server.serveRequest(context);
}

fn serveRequest(server: *Server, context: *httpx.Context) !httpx.Response {
    const target = routing.normalizeTarget(context.allocator, context.request.uri.raw) catch |err| switch (err) {
        error.PathTraversal, error.InvalidEscape, error.InvalidPath => return context.status(400).text("bad request\n"),
        else => return err,
    };

    const route = try server.resolveRoute(context.allocator, target.path, target.trailing_slash);
    switch (route) {
        .not_found => return context.status(404).text("not found\n"),
        .redirect => |location| return context.redirect(location, 308),
        .static => |static_file| return server.serveStatic(context, static_file),
        .php => |php| return server.servePhp(context, target.query, php),
    }
}

const Route = union(enum) {
    not_found,
    redirect: []const u8,
    static: []const u8,
    php: PhpRoute,
};

const PhpRoute = struct {
    path: []const u8,
    script_name: []const u8,
    path_info: []const u8,
};

fn resolveRoute(server: *Server, allocator: Allocator, request_path: []const u8, trailing_slash: bool) !Route {
    if (server.config.mode == .worker) return server.workerOrStaticRoute(allocator, request_path, trailing_slash);

    if (request_path.len == 0) {
        if (server.isFile("index.php")) return .{ .php = .{
            .path = "index.php",
            .script_name = "/index.php",
            .path_info = "",
        } };
        if (server.isFile("index.html")) return .{ .static = "index.html" };
        return .not_found;
    }

    if (try server.phpPrefixRoute(allocator, request_path)) |route| return route;

    if (server.isFile(request_path)) return .{ .static = request_path };

    if (server.isDirectory(request_path)) {
        if (!trailing_slash) return .{ .redirect = try directoryLocation(allocator, request_path) };

        if (try server.directoryIndexRoute(allocator, request_path)) |route| return route;
    }

    return server.frontControllerRoute(allocator, request_path);
}

fn phpPrefixRoute(server: *Server, allocator: Allocator, request_path: []const u8) !?Route {
    var end = request_path.len;
    while (std.mem.lastIndexOf(u8, request_path[0..end], ".php")) |extension_start| {
        const script_end = extension_start + ".php".len;
        const script_path = request_path[0..script_end];
        const valid_boundary = script_end == request_path.len or request_path[script_end] == std.fs.path.sep;
        if (valid_boundary and server.isFile(script_path)) {
            return .{ .php = .{
                .path = script_path,
                .script_name = try std.fmt.allocPrint(allocator, "/{s}", .{script_path}),
                .path_info = request_path[script_end..],
            } };
        }
        if (extension_start == 0) break;
        end = extension_start;
    }
    return null;
}

fn directoryIndexRoute(server: *Server, allocator: Allocator, directory: []const u8) !?Route {
    const php_index = try std.fs.path.join(allocator, &.{ directory, "index.php" });
    if (server.isFile(php_index)) return .{ .php = .{
        .path = php_index,
        .script_name = try std.fmt.allocPrint(allocator, "/{s}", .{php_index}),
        .path_info = "",
    } };

    const html_index = try std.fs.path.join(allocator, &.{ directory, "index.html" });
    if (server.isFile(html_index)) return .{ .static = html_index };
    return null;
}

fn frontControllerRoute(server: *Server, allocator: Allocator, request_path: []const u8) !Route {
    if (!server.isFile("index.php")) return .not_found;
    return .{ .php = .{
        .path = "index.php",
        .script_name = "/index.php",
        .path_info = try std.fmt.allocPrint(allocator, "/{s}", .{request_path}),
    } };
}

fn workerOrStaticRoute(server: *Server, allocator: Allocator, request_path: []const u8, trailing_slash: bool) !Route {
    if (request_path.len != 0 and server.isFile(request_path)) return .{ .static = request_path };

    if (request_path.len != 0 and server.isDirectory(request_path)) {
        if (!trailing_slash) return .{ .redirect = try directoryLocation(allocator, request_path) };

        const html_index = try std.fs.path.join(allocator, &.{ request_path, "index.html" });
        if (server.isFile(html_index)) return .{ .static = html_index };
    }

    return server.workerRoute(allocator, request_path);
}

fn workerRoute(server: *Server, allocator: Allocator, request_path: []const u8) !Route {
    if (!server.isFile(server.config.worker_script)) return .not_found;
    return .{ .php = .{
        .path = server.config.worker_script,
        .script_name = try std.fmt.allocPrint(allocator, "/{s}", .{server.config.worker_script}),
        .path_info = if (request_path.len == 0)
            "/"
        else
            try std.fmt.allocPrint(allocator, "/{s}", .{request_path}),
    } };
}

fn isFile(server: *Server, path: []const u8) bool {
    const stat = server.document_root.statFile(server.io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .file;
}

fn isDirectory(server: *Server, path: []const u8) bool {
    const stat = server.document_root.statFile(server.io, path, .{ .follow_symlinks = false }) catch return false;
    return stat.kind == .directory;
}

fn directoryLocation(allocator: Allocator, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/{s}/", .{path});
}

fn serveStatic(server: *Server, context: *httpx.Context, path: []const u8) !httpx.Response {
    if (context.request.method != .GET and context.request.method != .HEAD) {
        try context.setHeader("Allow", "GET, HEAD");
        return context.status(405).text("method not allowed\n");
    }

    const absolute_path = try std.fs.path.join(context.allocator, &.{ server.document_root_path, path });
    return context.fileWithOptions(absolute_path, .{
        .add_etag = true,
        .add_nosniff = true,
        .conditional_get = true,
    });
}

fn servePhp(
    server: *Server,
    context: *httpx.Context,
    query: []const u8,
    route: PhpRoute,
) !httpx.Response {
    const absolute_script = try std.fs.path.join(context.allocator, &.{ server.document_root_path, route.path });
    const body = context.request.body orelse "";
    const variables = try HttpxRequest.buildVariables(context.allocator, server.parent_environ, context.request, .{
        .document_root = server.document_root_path,
        .script_filename = absolute_script,
        .script_name = route.script_name,
        .path_info = route.path_info,
        .query = query,
        // httpx does not expose the accepted peer endpoint to a handler.
        .remote_addr = "127.0.0.1",
        .remote_port = "0",
        .server_addr = server.config.listen_host,
        .server_name = server.config.listen_host,
        .server_port = server.config.listen_port,
        .content_length = body.len,
    });

    var response = server.php_runtimes.execute(context.allocator, .{
        .script_filename = absolute_script,
        .method = context.request.method.toString(),
        .uri = context.request.uri.raw,
        .query = query,
        .content_type = context.request.headers.get(httpx.HeaderName.CONTENT_TYPE),
        .cookies = HttpxRequest.cookies(context.request),
        .body = body,
        .variables = variables,
        .headers_only = context.request.method == .HEAD,
    }) catch |err| switch (err) {
        error.OutputTooLarge => return context.status(502).text("PHP output too large\n"),
        error.InvalidResponse, error.ExecutionFailed => return context.status(502).text("PHP execution failed\n"),
        error.RuntimeStopped => return context.status(503).text("PHP runtime unavailable\n"),
        else => return err,
    };
    defer response.deinit();

    _ = context.response.status(@intFromEnum(response.status));
    for (response.headers) |header| {
        try context.setHeader(header.name, header.value);
    }
    _ = context.response.body(response.body);
    return context.response.build();
}

test "resolve PHP, static files, directory indexes, and the front controller" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.php", .data = "<?php" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "asset.txt", .data = "asset" });
    try tmp.dir.createDir(std.testing.io, "docs", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/index.html", .data = "docs" });

    var server: Server = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .parent_environ = undefined,
        .config = .{},
        .document_root_path = "",
        .document_root = tmp.dir,
        .php_runtimes = undefined,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try server.resolveRoute(arena, "", true);
    try std.testing.expectEqualStrings("index.php", root.php.path);

    const asset = try server.resolveRoute(arena, "asset.txt", false);
    try std.testing.expectEqualStrings("asset.txt", asset.static);

    const directory_redirect = try server.resolveRoute(arena, "docs", false);
    try std.testing.expectEqualStrings("/docs/", directory_redirect.redirect);

    const directory_index = try server.resolveRoute(arena, "docs", true);
    try std.testing.expectEqualStrings("docs/index.html", directory_index.static);

    const fallback = try server.resolveRoute(arena, "articles/zig", false);
    try std.testing.expectEqualStrings("index.php", fallback.php.path);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.php", .data = "<?php" });
    const with_path_info = try server.resolveRoute(arena, "secret.php/extra", false);
    try std.testing.expectEqualStrings("secret.php", with_path_info.php.path);

    server.config.mode = .worker;
    const worker_asset = try server.resolveRoute(arena, "asset.txt", false);
    try std.testing.expectEqualStrings("asset.txt", worker_asset.static);
}
