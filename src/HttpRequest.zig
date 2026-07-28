const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const PhpRuntime = @import("PhpRuntime.zig");

pub const RequestBody = struct {
    bytes: []const u8,
    has_body: bool,
};

pub const VariableOptions = struct {
    document_root: []const u8,
    script_filename: []const u8,
    script_name: []const u8,
    path_info: []const u8,
    query: []const u8,
    remote_addr: []const u8,
    remote_port: []const u8,
    server_addr: []const u8,
    server_name: []const u8,
    server_port: u16,
    content_length: usize,
};

pub fn readBody(
    allocator: Allocator,
    request: *std.http.Server.Request,
    max_body: usize,
) !RequestBody {
    const original_method = request.head.method;
    const has_framed_body = request.head.content_length != null or request.head.transfer_encoding != .none;
    const should_read_body = original_method.requestHasBody() or has_framed_body;

    // Zig exposes a body reader only for its method whitelist. Explicitly
    // framed bodies on methods such as DELETE still belong to the PHP request.
    if (has_framed_body and !original_method.requestHasBody()) request.head.method = .POST;
    defer request.head.method = original_method;

    var body_buffer: [16 * 1024]u8 = undefined;
    const reader = try request.readerExpectContinue(&body_buffer);
    const body = reader.allocRemaining(allocator, .limited(max_body)) catch |err| switch (err) {
        error.StreamTooLong => return error.BodyTooLarge,
        else => |other| return other,
    };
    return .{ .bytes = body, .has_body = should_read_body };
}

pub fn buildVariables(
    allocator: Allocator,
    parent_environ: *const std.process.Environ.Map,
    request: *const std.http.Server.Request,
    options: VariableOptions,
) ![]const PhpRuntime.Variable {
    var variables: std.ArrayList(PhpRuntime.Variable) = .empty;

    for (parent_environ.keys(), parent_environ.values()) |name, value| {
        try variables.append(allocator, .{ .name = name, .value = value });
    }

    const server_port = try std.fmt.allocPrint(allocator, "{d}", .{options.server_port});
    const content_length = try std.fmt.allocPrint(allocator, "{d}", .{options.content_length});
    const php_self = try std.mem.concat(allocator, u8, &.{ options.script_name, options.path_info });
    const request_uri = try allocator.dupe(u8, request.head.target);
    const content_type = try allocator.dupe(u8, request.head.content_type orelse "");
    try variables.appendSlice(allocator, &.{
        .{ .name = "GATEWAY_INTERFACE", .value = "CGI/1.1" },
        .{ .name = "SERVER_SOFTWARE", .value = "FrankenPHP-Zig" },
        .{ .name = "SERVER_PROTOCOL", .value = @tagName(request.head.version) },
        .{ .name = "REQUEST_METHOD", .value = @tagName(request.head.method) },
        .{ .name = "REQUEST_URI", .value = request_uri },
        .{ .name = "QUERY_STRING", .value = options.query },
        .{ .name = "DOCUMENT_ROOT", .value = options.document_root },
        .{ .name = "DOCUMENT_URI", .value = options.script_name },
        .{ .name = "SCRIPT_FILENAME", .value = options.script_filename },
        .{ .name = "SCRIPT_NAME", .value = options.script_name },
        .{ .name = "PHP_SELF", .value = php_self },
        .{ .name = "PATH_INFO", .value = options.path_info },
        .{ .name = "PATH_TRANSLATED", .value = options.script_filename },
        .{ .name = "REMOTE_ADDR", .value = options.remote_addr },
        .{ .name = "REMOTE_HOST", .value = options.remote_addr },
        .{ .name = "REMOTE_PORT", .value = options.remote_port },
        .{ .name = "SERVER_ADDR", .value = options.server_addr },
        .{ .name = "SERVER_NAME", .value = options.server_name },
        .{ .name = "SERVER_PORT", .value = server_port },
        .{ .name = "REQUEST_SCHEME", .value = "http" },
        .{ .name = "HTTPS", .value = "off" },
        .{ .name = "CONTENT_TYPE", .value = content_type },
        .{ .name = "CONTENT_LENGTH", .value = content_length },
    });

    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            const host = parseHost(header.value);
            try variables.append(allocator, .{ .name = "SERVER_NAME", .value = try allocator.dupe(u8, host.name) });
            if (host.port) |port| {
                try variables.append(allocator, .{ .name = "SERVER_PORT", .value = try allocator.dupe(u8, port) });
            }
        }
        if (std.ascii.eqlIgnoreCase(header.name, "content-type") or
            std.ascii.eqlIgnoreCase(header.name, "content-length") or
            std.ascii.eqlIgnoreCase(header.name, "proxy")) continue;

        const key = try allocator.alloc(u8, "HTTP_".len + header.name.len);
        @memcpy(key[0.."HTTP_".len], "HTTP_");
        for (header.name, key["HTTP_".len..]) |source, *destination| {
            destination.* = if (source == '-') '_' else std.ascii.toUpper(source);
        }
        try variables.append(allocator, .{ .name = key, .value = try allocator.dupe(u8, header.value) });
    }

    return variables.toOwnedSlice(allocator);
}

pub fn cookies(request: *const std.http.Server.Request) ?[]const u8 {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "cookie")) return header.value;
    }
    return null;
}

const ParsedHost = struct {
    name: []const u8,
    port: ?[]const u8,
};

fn parseHost(value: []const u8) ParsedHost {
    const host = std.mem.trim(u8, value, " \t");
    if (host.len == 0) return .{ .name = host, .port = null };
    if (host[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return .{ .name = host, .port = null };
        const port = if (close + 1 < host.len and host[close + 1] == ':') host[close + 2 ..] else null;
        return .{ .name = host[1..close], .port = port };
    }
    const colon = std.mem.lastIndexOfScalar(u8, host, ':') orelse return .{ .name = host, .port = null };
    return .{ .name = host[0..colon], .port = host[colon + 1 ..] };
}

test "build embedded PHP server variables without trusting Proxy" {
    var input = Io.Reader.fixed(
        "POST /submit?source=test HTTP/1.1\r\n" ++
            "Host: example.test:8443\r\n" ++
            "Authorization: Bearer token\r\n" ++
            "Proxy: attacker.example\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 4\r\n\r\nbody",
    );
    var output_buffer: [64]u8 = undefined;
    var output: Io.Writer.Discarding = .init(&output_buffer);
    var server = std.http.Server.init(&input, &output.writer);
    var request = try server.receiveHead();

    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const variables = try buildVariables(arena_state.allocator(), &environ, &request, .{
        .document_root = "/srv/app",
        .script_filename = "/srv/app/index.php",
        .script_name = "/index.php",
        .path_info = "/submit",
        .query = "source=test",
        .remote_addr = "127.0.0.1",
        .remote_port = "12345",
        .server_addr = "127.0.0.1",
        .server_name = "localhost",
        .server_port = 8080,
        .content_length = 4,
    });

    try std.testing.expectEqualStrings("example.test", findVariable(variables, "SERVER_NAME").?);
    try std.testing.expectEqualStrings("8443", findVariable(variables, "SERVER_PORT").?);
    try std.testing.expectEqualStrings("Bearer token", findVariable(variables, "HTTP_AUTHORIZATION").?);
    try std.testing.expect(findVariable(variables, "HTTP_PROXY") == null);
}

fn findVariable(variables: []const PhpRuntime.Variable, name: []const u8) ?[]const u8 {
    var index = variables.len;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, variables[index].name, name)) return variables[index].value;
    }
    return null;
}
