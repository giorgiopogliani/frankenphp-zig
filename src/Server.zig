const Server = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Config = @import("Config.zig");
const HttpRequest = @import("HttpRequest.zig");
const PhpRuntime = @import("PhpRuntime.zig");
const routing = @import("routing.zig");

io: Io,
gpa: Allocator,
parent_environ: *const std.process.Environ.Map,
config: Config,
document_root_path: []const u8,
document_root: Io.Dir,
connection_slots: Io.Semaphore,
php_runtime: *PhpRuntime,

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

    var php_runtime: PhpRuntime = .{};
    try php_runtime.start(io, gpa, config.max_php_output, worker);
    defer php_runtime.stop();

    const address = try Io.net.IpAddress.parse(config.listen_host, config.listen_port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var server: Server = .{
        .io = io,
        .gpa = gpa,
        .parent_environ = parent_environ,
        .config = config,
        .document_root_path = document_root_path,
        .document_root = document_root,
        .connection_slots = .{ .permits = config.max_connections },
        .php_runtime = &php_runtime,
    };

    std.log.info("serving {s} at http://{s}:{d}", .{
        document_root_path,
        config.listen_host,
        config.listen_port,
    });

    var connections: Io.Group = .init;
    defer connections.cancel(io);
    while (true) {
        try server.connection_slots.wait(io);
        const stream = listener.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => {
                server.connection_slots.post(io);
                continue;
            },
            else => {
                server.connection_slots.post(io);
                return err;
            },
        };
        connections.async(io, handleConnectionSlot, .{ &server, stream });
    }
}

fn handleConnectionSlot(server: *Server, stream: Io.net.Stream) void {
    defer server.connection_slots.post(server.io);
    defer stream.close(server.io);
    handleConnection(server, stream);
}

fn handleConnection(server: *Server, stream: Io.net.Stream) void {
    var input_buffer: [16 * 1024]u8 = undefined;
    var output_buffer: [16 * 1024]u8 = undefined;
    var input = stream.reader(server.io, &input_buffer);
    var output = stream.writer(server.io, &output_buffer);
    var http_server = std.http.Server.init(&input.interface, &output.interface);

    var request_arena = std.heap.ArenaAllocator.init(server.gpa);
    defer request_arena.deinit();
    const remote = peerEndpoint(stream);

    while (http_server.reader.state == .ready) {
        const Result = union(enum) {
            request: bool,
            timeout: Io.Cancelable!void,
        };
        var results: [2]Result = undefined;
        var select = Io.Select(Result).init(server.io, &results);
        select.concurrent(.request, serveNextRequest, .{ server, &http_server, &request_arena, &remote }) catch return;
        select.concurrent(.timeout, waitRequestTimeout, .{ server.io, server.config.request_timeout_seconds }) catch {
            select.cancelDiscard();
            return;
        };

        const result = select.await() catch {
            select.cancelDiscard();
            return;
        };
        switch (result) {
            .request => |keep_alive| {
                select.cancelDiscard();
                if (!keep_alive) return;
            },
            .timeout => |timeout_result| {
                timeout_result catch {};
                stream.shutdown(server.io, .both) catch {};
                select.cancelDiscard();
                std.log.warn("request timed out after {d}s", .{server.config.request_timeout_seconds});
                return;
            },
        }
    }
}

fn waitRequestTimeout(io: Io, seconds: u32) Io.Cancelable!void {
    try Io.Clock.Duration.sleep(.{
        .clock = .awake,
        .raw = .fromSeconds(@intCast(seconds)),
    }, io);
}

fn serveNextRequest(
    server: *Server,
    http_server: *std.http.Server,
    request_arena: *std.heap.ArenaAllocator,
    remote: *const Endpoint,
) bool {
    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return false,
        else => {
            std.log.debug("closing invalid HTTP connection: {t}", .{err});
            return false;
        },
    };

    serveRequest(server, request_arena.allocator(), &request, remote) catch |err| switch (err) {
        error.Canceled => return false,
        else => {
            std.log.err("request failed: {t}", .{err});
            return false;
        },
    };
    _ = request_arena.reset(.retain_capacity);
    return true;
}

const Endpoint = struct {
    address_buffer: [64]u8 = undefined,
    address_len: u8 = 0,
    port_buffer: [5]u8 = undefined,
    port_len: u8 = 0,

    fn init(ip_address: Io.net.IpAddress) Endpoint {
        var endpoint: Endpoint = .{};
        var writer = Io.Writer.fixed(&endpoint.address_buffer);
        const port_number = switch (ip_address) {
            .ip4 => |ip4| blk: {
                writer.print("{d}.{d}.{d}.{d}", .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] }) catch unreachable;
                break :blk ip4.port;
            },
            .ip6 => |ip6| blk: {
                const unresolved: Io.net.Ip6Address.Unresolved = .{
                    .bytes = ip6.bytes,
                    .interface_name = null,
                };
                writer.print("{f}", .{unresolved}) catch unreachable;
                break :blk ip6.port;
            },
        };
        endpoint.address_len = @intCast(writer.end);
        const port_text = std.fmt.bufPrint(&endpoint.port_buffer, "{d}", .{port_number}) catch unreachable;
        endpoint.port_len = @intCast(port_text.len);
        return endpoint;
    }

    fn address(endpoint: *const Endpoint) []const u8 {
        return endpoint.address_buffer[0..endpoint.address_len];
    }

    fn port(endpoint: *const Endpoint) []const u8 {
        return endpoint.port_buffer[0..endpoint.port_len];
    }
};

fn peerEndpoint(stream: Io.net.Stream) Endpoint {
    return switch (builtin.os.tag) {
        .windows => Endpoint.init(.{ .ip4 = .loopback(0) }),
        else => peerEndpointPosix(stream) catch Endpoint.init(.{ .ip4 = .loopback(0) }),
    };
}

fn peerEndpointPosix(stream: Io.net.Stream) !Endpoint {
    const PosixAddress = extern union {
        any: std.posix.sockaddr,
        in: std.posix.sockaddr.in,
        in6: std.posix.sockaddr.in6,
    };
    var address: PosixAddress = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(PosixAddress);
    try std.posix.getpeername(stream.socket.handle, &address.any, &address_len);

    const ip: Io.net.IpAddress = switch (address.any.family) {
        std.posix.AF.INET => .{ .ip4 = .{
            .bytes = @bitCast(address.in.addr),
            .port = std.mem.bigToNative(u16, address.in.port),
        } },
        std.posix.AF.INET6 => .{ .ip6 = .{
            .bytes = address.in6.addr,
            .port = std.mem.bigToNative(u16, address.in6.port),
            .flow = address.in6.flowinfo,
            .interface = .{ .index = address.in6.scope_id },
        } },
        else => return error.UnsupportedAddressFamily,
    };
    return Endpoint.init(ip);
}

fn serveRequest(
    server: *Server,
    allocator: Allocator,
    request: *std.http.Server.Request,
    remote: *const Endpoint,
) !void {
    const target = routing.normalizeTarget(allocator, request.head.target) catch |err| switch (err) {
        error.PathTraversal, error.InvalidEscape, error.InvalidPath => return respondText(request, .bad_request, "bad request\n"),
        else => return err,
    };

    const route = try server.resolveRoute(allocator, target.path);
    switch (route) {
        .not_found => try respondText(request, .not_found, "not found\n"),
        .php => |php| try server.servePhp(allocator, request, target.query, php, remote),
    }
}

const Route = union(enum) {
    not_found,
    php: PhpRoute,
};

const PhpRoute = struct {
    path: []const u8,
    script_name: []const u8,
    path_info: []const u8,
};

fn resolveRoute(server: *Server, allocator: Allocator, request_path: []const u8) !Route {
    if (server.config.mode == .worker) return server.workerRoute(allocator, request_path);

    if (request_path.len == 0) {
        if (!server.isFile("index.php")) return .not_found;
        return .{ .php = .{
            .path = "index.php",
            .script_name = "/index.php",
            .path_info = "",
        } };
    }

    return server.resolvePhpPrefixOrFrontController(allocator, request_path);
}

fn resolvePhpPrefixOrFrontController(server: *Server, allocator: Allocator, request_path: []const u8) !Route {
    if (server.config.mode == .worker) return server.workerRoute(allocator, request_path);

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

    if (server.isFile("index.php")) {
        return .{ .php = .{
            .path = "index.php",
            .script_name = "/index.php",
            .path_info = try std.fmt.allocPrint(allocator, "/{s}", .{request_path}),
        } };
    }
    return .not_found;
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
    const stat = server.document_root.statFile(server.io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn servePhp(
    server: *Server,
    allocator: Allocator,
    request: *std.http.Server.Request,
    query: []const u8,
    route: PhpRoute,
    remote: *const Endpoint,
) !void {
    const absolute_script = try std.fs.path.join(allocator, &.{ server.document_root_path, route.path });
    const variables = try HttpRequest.buildVariables(allocator, server.parent_environ, request, .{
        .document_root = server.document_root_path,
        .script_filename = absolute_script,
        .script_name = route.script_name,
        .path_info = route.path_info,
        .query = query,
        .remote_addr = remote.address(),
        .remote_port = remote.port(),
        .server_addr = server.config.listen_host,
        .server_name = server.config.listen_host,
        .server_port = server.config.listen_port,
        .content_length = request.head.content_length orelse 0,
    });
    const request_uri = try allocator.dupe(u8, request.head.target);
    const request_content_type = if (request.head.content_type) |value| try allocator.dupe(u8, value) else null;
    const request_cookies = if (HttpRequest.cookies(request)) |value| try allocator.dupe(u8, value) else null;
    const request_method = @tagName(request.head.method);
    const headers_only = request.head.method == .HEAD;
    const body = HttpRequest.readBody(allocator, request, server.config.max_request_body) catch |err| switch (err) {
        error.BodyTooLarge => return respondText(request, .payload_too_large, "request body too large\n"),
        else => return err,
    };

    var response = server.php_runtime.execute(allocator, .{
        .script_filename = absolute_script,
        .method = request_method,
        .uri = request_uri,
        .query = query,
        .content_type = request_content_type,
        .cookies = request_cookies,
        .body = body.bytes,
        .variables = variables,
        .headers_only = headers_only,
    }) catch |err| switch (err) {
        error.OutputTooLarge => return respondText(request, .bad_gateway, "PHP output too large\n"),
        error.InvalidResponse, error.ExecutionFailed => return respondText(request, .bad_gateway, "PHP execution failed\n"),
        error.RuntimeStopped => return respondText(request, .service_unavailable, "PHP runtime unavailable\n"),
        else => return err,
    };
    defer response.deinit();

    try request.respond(response.body, .{
        .status = response.status,
        .extra_headers = response.headers,
    });
}

fn respondText(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .extra_headers = &.{.{ .name = "content-type", .value = "text/plain; charset=utf-8" }},
    });
}

test "resolve PHP and front-controller routes without serving static files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.php", .data = "<?php" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "asset.txt", .data = "asset" });

    var server: Server = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .parent_environ = undefined,
        .config = .{},
        .document_root_path = "",
        .document_root = tmp.dir,
        .connection_slots = .{ .permits = 1 },
        .php_runtime = undefined,
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try server.resolveRoute(arena, "");
    try std.testing.expectEqualStrings("index.php", root.php.path);
    try std.testing.expectEqualStrings("/index.php", root.php.script_name);

    const asset = try server.resolveRoute(arena, "asset.txt");
    try std.testing.expectEqualStrings("index.php", asset.php.path);
    try std.testing.expectEqualStrings("/asset.txt", asset.php.path_info);

    const fallback = try server.resolveRoute(arena, "articles/zig");
    try std.testing.expectEqualStrings("index.php", fallback.php.path);
    try std.testing.expectEqualStrings("/articles/zig", fallback.php.path_info);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "secret.php", .data = "<?php" });
    const with_path_info = try server.resolveRoute(arena, "secret.php/extra");
    try std.testing.expectEqualStrings("secret.php", with_path_info.php.path);
    try std.testing.expectEqualStrings("/extra", with_path_info.php.path_info);

    const disguised = try server.resolveRoute(arena, "secret.php.jpg");
    try std.testing.expectEqualStrings("index.php", disguised.php.path);
    try std.testing.expectEqualStrings("/secret.php.jpg", disguised.php.path_info);

    const suffix = try server.resolveRoute(arena, "index.phpanything");
    try std.testing.expectEqualStrings("index.php", suffix.php.path);
    try std.testing.expectEqualStrings("/index.phpanything", suffix.php.path_info);
}
