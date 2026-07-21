const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Target = struct {
    path: []const u8,
    query: []const u8,
};

pub const NormalizeError = error{
    InvalidEscape,
    InvalidPath,
    PathTraversal,
};

/// Splits an origin-form request target and returns a safe document-root-relative path.
pub fn normalizeTarget(allocator: Allocator, raw_target: []const u8) (NormalizeError || Allocator.Error)!Target {
    if (raw_target.len == 0 or raw_target[0] != '/') return error.InvalidPath;

    const query_start = std.mem.indexOfScalar(u8, raw_target, '?') orelse raw_target.len;
    const raw_path = raw_target[0..query_start];
    const query = if (query_start < raw_target.len) raw_target[query_start + 1 ..] else "";

    const decoded_storage = try allocator.alloc(u8, raw_path.len);
    defer allocator.free(decoded_storage);
    var decoded = decoded_storage;
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < raw_path.len) {
        const byte = raw_path[read_index];
        if (byte == '%') {
            if (read_index + 2 >= raw_path.len) return error.InvalidEscape;
            decoded[write_index] = decodeHexPair(raw_path[read_index + 1], raw_path[read_index + 2]) orelse
                return error.InvalidEscape;
            read_index += 3;
        } else {
            decoded[write_index] = byte;
            read_index += 1;
        }

        const decoded_byte = decoded[write_index];
        if (decoded_byte == 0 or decoded_byte == '\\') return error.InvalidPath;
        write_index += 1;
    }
    decoded = decoded[0..write_index];

    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var segments = std.mem.splitScalar(u8, decoded, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) return error.PathTraversal;
        if (normalized.items.len > 0) try normalized.append(allocator, std.fs.path.sep);
        try normalized.appendSlice(allocator, segment);
    }

    const path = try normalized.toOwnedSlice(allocator);
    errdefer allocator.free(path);
    return .{
        .path = path,
        .query = try allocator.dupe(u8, query),
    };
}

fn decodeHexPair(high: u8, low: u8) ?u8 {
    const high_value = std.fmt.charToDigit(high, 16) catch return null;
    const low_value = std.fmt.charToDigit(low, 16) catch return null;
    return high_value * 16 + low_value;
}

test "normalize request target" {
    const raw_target = try std.testing.allocator.dupe(u8, "/images/logo%20wide.svg?v=2");
    defer std.testing.allocator.free(raw_target);
    const target = try normalizeTarget(std.testing.allocator, raw_target);
    defer std.testing.allocator.free(target.path);
    defer std.testing.allocator.free(target.query);
    @memset(raw_target, 'x');

    try std.testing.expectEqualStrings("images/logo wide.svg", target.path);
    try std.testing.expectEqualStrings("v=2", target.query);
}

test "normalization rejects traversal and encoded separators" {
    try std.testing.expectError(error.PathTraversal, normalizeTarget(std.testing.allocator, "/public/../secret"));
    try std.testing.expectError(error.InvalidPath, normalizeTarget(std.testing.allocator, "/public%5csecret"));
    try std.testing.expectError(error.InvalidEscape, normalizeTarget(std.testing.allocator, "/bad%2"));
}
