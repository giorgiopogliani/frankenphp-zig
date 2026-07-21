const std = @import("std");

const Config = @import("Config.zig");
const Server = @import("Server.zig");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    defer args.deinit();
    _ = args.skip();

    const command = args.next() orelse return printHelp(init.io);
    if (std.mem.eql(u8, command, "run")) {
        var remaining: std.ArrayList([]const u8) = .empty;
        while (args.next()) |arg| try remaining.append(arena, arg);
        var config = Config.parse(remaining.items) catch |err| {
            std.log.err("invalid server configuration: {t}", .{err});
            return error.InvalidArguments;
        };
        config.applyEnvironment(init.environ_map) catch |err| {
            std.log.err("invalid server environment: {t}", .{err});
            return error.InvalidArguments;
        };
        return Server.run(init.io, init.gpa, arena, init.environ_map, config);
    }
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try std.Io.File.stdout().writeStreamingAll(init.io, "FrankenPHP Zig " ++ version ++ "\n");
        return;
    }
    if (std.mem.eql(u8, command, "build-info")) {
        try std.Io.File.stdout().writeStreamingAll(
            init.io,
            "dep github.com/dunglas/frankenphp v1.5.0\n",
        );
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        return printHelp(init.io);
    }

    std.log.err("unknown command: {s}", .{command});
    printHelp(init.io) catch {};
    return error.InvalidArguments;
}

fn printHelp(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\FrankenPHP Zig - a Caddy-free PHP application server
        \\
        \\Usage:
        \\  frankenphp run [options]
        \\  frankenphp version
        \\
        \\Run options:
        \\  --port PORT         Listen port (default: 8080)
        \\  --root PATH         Document root (default: current directory)
        \\  --max-body SIZE     Maximum request body; k/m/g suffix accepted (default: 10m)
        \\  --max-output SIZE   Maximum PHP response size (default: 16m)
        \\  --max-connections N Maximum concurrent connections (default: 128)
        \\  --request-timeout N Per-request timeout in seconds (default: 30)
        \\
    );
}
