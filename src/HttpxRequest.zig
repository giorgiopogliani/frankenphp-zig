const std = @import("std");
const Allocator = std.mem.Allocator;

const httpx = @import("httpx");
const PhpRuntime = @import("PhpRuntime.zig");

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

pub fn buildVariables(
    allocator: Allocator,
    parent_environ: *const std.process.Environ.Map,
    request: *const httpx.Request,
    options: VariableOptions,
) ![]const PhpRuntime.Variable {
    var variables: std.ArrayList(PhpRuntime.Variable) = .empty;

    for (parent_environ.keys(), parent_environ.values()) |name, value| {
        try variables.append(allocator, .{ .name = name, .value = value });
    }

    const server_port = try std.fmt.allocPrint(allocator, "{d}", .{options.server_port});
    const content_length = try std.fmt.allocPrint(allocator, "{d}", .{options.content_length});
    const php_self = try std.mem.concat(allocator, u8, &.{ options.script_name, options.path_info });
    const request_uri = request.uri.raw;
    const content_type = request.headers.get(httpx.HeaderName.CONTENT_TYPE) orelse "";
    try variables.appendSlice(allocator, &.{
        .{ .name = "GATEWAY_INTERFACE", .value = "CGI/1.1" },
        .{ .name = "SERVER_SOFTWARE", .value = "FrankenPHP-Zig" },
        .{ .name = "SERVER_PROTOCOL", .value = protocol(request.version) },
        .{ .name = "REQUEST_METHOD", .value = request.method.toString() },
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

    for (request.headers.entries.items) |header| {
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

pub fn cookies(request: *const httpx.Request) ?[]const u8 {
    return request.headers.get(httpx.HeaderName.COOKIE);
}

fn protocol(version: httpx.Version) []const u8 {
    return switch (version) {
        .HTTP_1_0 => "HTTP/1.0",
        .HTTP_1_1 => "HTTP/1.1",
        .HTTP_2 => "HTTP/2",
        .HTTP_3 => "HTTP/3",
    };
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

test "build PHP variables from an httpx request" {
    var request = try httpx.Request.init(std.testing.allocator, .POST, "/submit?source=test");
    defer request.deinit();
    try request.setHeader(httpx.HeaderName.HOST, "example.test:8443");
    try request.setHeader(httpx.HeaderName.AUTHORIZATION, "Bearer token");
    try request.setHeader("Proxy", "attacker.example");
    try request.setHeader(httpx.HeaderName.CONTENT_TYPE, "text/plain");

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
