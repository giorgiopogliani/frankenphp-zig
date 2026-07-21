const Config = @This();

const std = @import("std");

listen_host: []const u8 = "127.0.0.1",
listen_port: u16 = 8080,
document_root: []const u8 = ".",
mode: Mode = .classic,
worker_script: []const u8 = "frankenphp-worker.php",
config_path: ?[]const u8 = null,
max_request_body: usize = 10 * 1024 * 1024,
max_php_output: usize = 16 * 1024 * 1024,
max_connections: usize = 128,
request_timeout_seconds: u32 = 30,

pub const Mode = enum {
    classic,
    worker,
};

pub const ParseError = error{
    InvalidArgument,
    InvalidPort,
    InvalidSize,
    MissingOctaneEnvironment,
    MissingValue,
    UnsupportedConfig,
    UnsupportedHttps,
};

pub fn parse(args: []const []const u8) (ParseError || std.fmt.ParseIntError)!Config {
    var config: Config = .{};
    var index: usize = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.config_path = args[index];
        } else if (std.mem.eql(u8, arg, "--port")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.listen_port = try parsePort(args[index]);
        } else if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.document_root = args[index];
        } else if (std.mem.eql(u8, arg, "--max-body")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.max_request_body = try parseSize(args[index]);
        } else if (std.mem.eql(u8, arg, "--max-output")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.max_php_output = try parseSize(args[index]);
        } else if (std.mem.eql(u8, arg, "--max-connections")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.max_connections = try parsePositive(usize, args[index]);
        } else if (std.mem.eql(u8, arg, "--request-timeout")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            config.request_timeout_seconds = try parsePositive(u32, args[index]);
        }
    }

    return config;
}

pub fn applyEnvironment(config: *Config, environ: *const std.process.Environ.Map) (ParseError || std.fmt.ParseIntError)!void {
    if (config.config_path == null) return;
    if (!std.mem.eql(u8, environ.get("LARAVEL_OCTANE") orelse return error.UnsupportedConfig, "1")) {
        return error.UnsupportedConfig;
    }

    config.mode = .worker;
    config.document_root = environ.get("APP_PUBLIC_PATH") orelse return error.MissingOctaneEnvironment;
    config.listen_host = "0.0.0.0";
    config.listen_port = try parseOctaneServerName(
        environ.get("CADDY_SERVER_SERVER_NAME") orelse return error.MissingOctaneEnvironment,
    );

    if (environ.get("REQUEST_MAX_EXECUTION_TIME")) |value| {
        if (value.len != 0) config.request_timeout_seconds = try parsePositive(u32, value);
    }
}

fn parseOctaneServerName(value: []const u8) (ParseError || std.fmt.ParseIntError)!u16 {
    if (std.mem.startsWith(u8, value, "https://")) return error.UnsupportedHttps;
    if (!std.mem.startsWith(u8, value, "http://")) return error.InvalidArgument;
    const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidPort;
    return parsePort(value[separator + 1 ..]);
}

fn parsePort(value: []const u8) (ParseError || std.fmt.ParseIntError)!u16 {
    const port = try std.fmt.parseInt(u16, value, 10);
    if (port == 0) return error.InvalidPort;
    return port;
}

fn parseSize(value: []const u8) (ParseError || std.fmt.ParseIntError)!usize {
    if (value.len == 0) return error.InvalidSize;

    const suffix = std.ascii.toLower(value[value.len - 1]);
    const multiplier: usize = switch (suffix) {
        'k' => 1024,
        'm' => 1024 * 1024,
        'g' => 1024 * 1024 * 1024,
        else => 1,
    };
    const number = if (multiplier == 1) value else value[0 .. value.len - 1];
    const base = try std.fmt.parseInt(usize, number, 10);
    return std.math.mul(usize, base, multiplier) catch error.InvalidSize;
}

fn parsePositive(comptime T: type, value: []const u8) (ParseError || std.fmt.ParseIntError)!T {
    const parsed = try std.fmt.parseInt(T, value, 10);
    if (parsed == 0) return error.InvalidSize;
    return parsed;
}

test "parse server configuration" {
    const config = try parse(&.{
        "--port",
        "9000",
        "--root",
        "public",
        "--max-body",
        "2m",
        "--max-connections",
        "64",
        "--request-timeout",
        "15",
    });

    try std.testing.expectEqualStrings("127.0.0.1", config.listen_host);
    try std.testing.expectEqual(9000, config.listen_port);
    try std.testing.expectEqualStrings("public", config.document_root);
    try std.testing.expectEqual(2 * 1024 * 1024, config.max_request_body);
    try std.testing.expectEqual(64, config.max_connections);
    try std.testing.expectEqual(15, config.request_timeout_seconds);
}

test "configuration rejects port zero" {
    try std.testing.expectError(error.InvalidPort, parse(&.{ "--port", "0" }));
}

test "configuration rejects removed listen option" {
    try std.testing.expectError(error.InvalidArgument, parse(&.{ "--listen", "127.0.0.1:8080" }));
}

test "configuration derives worker mode from Octane environment" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("LARAVEL_OCTANE", "1");
    try environ.put("APP_PUBLIC_PATH", "/app/public");
    try environ.put("CADDY_SERVER_SERVER_NAME", "http://:8000");
    try environ.put("REQUEST_MAX_EXECUTION_TIME", "45");

    var config = try parse(&.{ "-c", "/app/vendor/laravel/octane/src/Commands/stubs/Caddyfile" });
    try config.applyEnvironment(&environ);

    try std.testing.expectEqual(Mode.worker, config.mode);
    try std.testing.expectEqualStrings("0.0.0.0", config.listen_host);
    try std.testing.expectEqual(8000, config.listen_port);
    try std.testing.expectEqualStrings("/app/public", config.document_root);
    try std.testing.expectEqual(45, config.request_timeout_seconds);
}

test "configuration rejects unbounded resource settings" {
    try std.testing.expectError(error.InvalidSize, parse(&.{ "--max-connections", "0" }));
    try std.testing.expectError(error.InvalidSize, parse(&.{ "--request-timeout", "0" }));
}
