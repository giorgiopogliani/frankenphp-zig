const std = @import("std");

/// Returns a conservative MIME type for a static file path.
pub fn fromPath(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    const types = .{
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".ico", "image/x-icon" },
        .{ ".wasm", "application/wasm" },
        .{ ".pdf", "application/pdf" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".ttf", "font/ttf" },
        .{ ".otf", "font/otf" },
        .{ ".txt", "text/plain; charset=utf-8" },
    };
    inline for (types) |entry| if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    return "application/octet-stream";
}

test fromPath {
    try std.testing.expectEqualStrings("text/css; charset=utf-8", fromPath("assets/site.CSS"));
    try std.testing.expectEqualStrings("application/octet-stream", fromPath("assets/file.unknown"));
}
