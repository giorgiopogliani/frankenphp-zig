const std = @import("std");
const build_options = @import("build_options");

const PhpRuntime = @import("PhpRuntime.zig");

test "PHP stays embedded and resets request state" {
    var runtime: PhpRuntime = .{};
    try runtime.start(std.testing.io, std.testing.allocator, 1024 * 1024, null);
    defer runtime.stop();

    const first_variables = [_]PhpRuntime.Variable{
        .{ .name = "REQUEST_METHOD", .value = "POST" },
        .{ .name = "REQUEST_URI", .value = "/not-found?source=test" },
        .{ .name = "QUERY_STRING", .value = "source=test" },
        .{ .name = "PATH_INFO", .value = "/not-found" },
        .{ .name = "REMOTE_ADDR", .value = "127.0.0.1" },
        .{ .name = "REMOTE_PORT", .value = "12345" },
        .{ .name = "SERVER_NAME", .value = "example.test" },
        .{ .name = "SERVER_PORT", .value = "8080" },
        .{ .name = "CONTENT_TYPE", .value = "text/plain" },
        .{ .name = "CONTENT_LENGTH", .value = "13" },
    };
    var first = try runtime.execute(std.testing.allocator, .{
        .script_filename = build_options.fixture_path,
        .method = "POST",
        .uri = "/not-found?source=test",
        .query = "source=test",
        .content_type = "text/plain",
        .cookies = "session=abc",
        .body = "embedded-body",
        .variables = &first_variables,
        .headers_only = false,
    });
    defer first.deinit();

    try std.testing.expectEqual(std.http.Status.not_found, first.status);
    try std.testing.expectEqualStrings("application/json", headerValue(first.headers, "content-type").?);
    try std.testing.expectEqualStrings("zig", headerValue(first.headers, "x-frankenphp-engine").?);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"method\":\"POST\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"body\":\"embedded-body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"source\":\"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"session\":\"abc\"") != null);
    const first_pid = try responsePid(first.body);

    const second_variables = [_]PhpRuntime.Variable{
        .{ .name = "REQUEST_METHOD", .value = "GET" },
        .{ .name = "REQUEST_URI", .value = "/ok" },
        .{ .name = "QUERY_STRING", .value = "" },
        .{ .name = "PATH_INFO", .value = "/ok" },
        .{ .name = "REMOTE_ADDR", .value = "127.0.0.1" },
        .{ .name = "REMOTE_PORT", .value = "12346" },
        .{ .name = "SERVER_NAME", .value = "example.test" },
        .{ .name = "SERVER_PORT", .value = "8080" },
        .{ .name = "CONTENT_TYPE", .value = "" },
        .{ .name = "CONTENT_LENGTH", .value = "0" },
    };
    var second = try runtime.execute(std.testing.allocator, .{
        .script_filename = build_options.fixture_path,
        .method = "GET",
        .uri = "/ok",
        .query = "",
        .content_type = null,
        .cookies = null,
        .body = "",
        .variables = &second_variables,
        .headers_only = false,
    });
    defer second.deinit();

    try std.testing.expectEqual(std.http.Status.ok, second.status);
    try std.testing.expectEqual(first_pid, try responsePid(second.body));
}

test "embedded PHP provides Laravel string encoding support" {
    var runtime: PhpRuntime = .{};
    try runtime.start(std.testing.io, std.testing.allocator, 1024, null);
    defer runtime.stop();

    var response = try runtime.execute(std.testing.allocator, .{
        .script_filename = build_options.mbstring_fixture_path,
        .method = "GET",
        .uri = "/mbstring.php",
        .query = "",
        .content_type = null,
        .cookies = null,
        .body = "",
        .variables = &.{},
        .headers_only = false,
    });
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("{\"extension\":true,\"function\":true}", response.body);
}

test "embedded PHP provides Laravel database drivers" {
    var runtime: PhpRuntime = .{};
    try runtime.start(std.testing.io, std.testing.allocator, 1024, null);
    defer runtime.stop();

    var response = try runtime.execute(std.testing.allocator, .{
        .script_filename = build_options.pdo_fixture_path,
        .method = "GET",
        .uri = "/pdo.php",
        .query = "",
        .content_type = null,
        .cookies = null,
        .body = "",
        .variables = &.{},
        .headers_only = false,
    });
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "\"mysql\"") != null);
}

test "embedded PHP provides Laravel internationalization support" {
    var runtime: PhpRuntime = .{};
    try runtime.start(std.testing.io, std.testing.allocator, 1024, null);
    defer runtime.stop();

    var response = try runtime.execute(std.testing.allocator, .{
        .script_filename = build_options.intl_fixture_path,
        .method = "GET",
        .uri = "/intl.php",
        .query = "",
        .content_type = null,
        .cookies = null,
        .body = "",
        .variables = &.{},
        .headers_only = false,
    });
    defer response.deinit();

    try std.testing.expectEqual(std.http.Status.ok, response.status);
    try std.testing.expectEqualStrings("{\"extension\":true,\"formatter\":true}", response.body);
}

test "PHP worker boots once and handles multiple requests" {
    const bootstrap_variables = [_]PhpRuntime.Variable{
        .{ .name = "FRANKENPHP_WORKER", .value = "1" },
        .{ .name = "MAX_REQUESTS", .value = "2" },
    };
    var runtime: PhpRuntime = .{};
    try runtime.start(std.testing.io, std.testing.allocator, 1024 * 1024, .{
        .script_filename = build_options.worker_fixture_path,
        .variables = &bootstrap_variables,
    });
    defer runtime.stop();

    var first = try executeWorkerRequest(&runtime, "/first");
    defer first.deinit();
    try std.testing.expectEqualStrings("{\"count\":1,\"uri\":\"/first\"}", first.body);

    var second = try executeWorkerRequest(&runtime, "/second");
    defer second.deinit();
    try std.testing.expectEqualStrings("{\"count\":2,\"uri\":\"/second\"}", second.body);

    var after_restart = try executeWorkerRequest(&runtime, "/after-restart");
    defer after_restart.deinit();
    try std.testing.expectEqualStrings("{\"count\":1,\"uri\":\"/after-restart\"}", after_restart.body);

    try std.testing.expectError(error.ExecutionFailed, executeWorkerRequest(&runtime, "/exit"));

    var after_exit = try executeWorkerRequest(&runtime, "/after-exit");
    defer after_exit.deinit();
    try std.testing.expectEqualStrings("{\"count\":1,\"uri\":\"/after-exit\"}", after_exit.body);
}

test "PHP worker isolates request input and output state" {
    const bootstrap_variables = [_]PhpRuntime.Variable{
        .{ .name = "FRANKENPHP_WORKER", .value = "1" },
        .{ .name = "MAX_REQUESTS", .value = "100" },
    };
    var runtime: PhpRuntime = .{};
    try runtime.start(std.testing.io, std.testing.allocator, 1024 * 1024, .{
        .script_filename = build_options.worker_fixture_path,
        .variables = &bootstrap_variables,
    });
    defer runtime.stop();

    var post = try executeWorkerRequestWith(&runtime, .{
        .method = "POST",
        .uri = "/inspect?q=first",
        .query = "q=first",
        .content_type = "application/x-www-form-urlencoded",
        .cookies = "session=abc",
        .body = "alpha=one",
    });
    defer post.deinit();
    try expectJsonString(post.body, "raw_body", "alpha=one");
    try expectJsonString(post.body, "get", "first");
    try expectJsonString(post.body, "post", "one");
    try expectJsonString(post.body, "cookie", "abc");
    try expectJsonInteger(post.body, "output_level", 0);
    const session_available = try jsonBoolean(post.body, "session_available");

    var clean = try executeWorkerRequestWith(&runtime, .{ .uri = "/inspect" });
    defer clean.deinit();
    try expectJsonString(clean.body, "raw_body", "");
    try expectJsonNull(clean.body, "get");
    try expectJsonNull(clean.body, "post");
    try expectJsonNull(clean.body, "cookie");
    try expectJsonInteger(clean.body, "output_level", 0);

    var buffered = try executeWorkerRequestWith(&runtime, .{ .uri = "/buffer" });
    defer buffered.deinit();
    try std.testing.expect(std.mem.startsWith(u8, buffered.body, "buffered:"));

    var after_buffer = try executeWorkerRequestWith(&runtime, .{ .uri = "/inspect" });
    defer after_buffer.deinit();
    try expectJsonInteger(after_buffer.body, "output_level", 0);

    const multipart_body =
        "--zig-boundary\r\n" ++
        "Content-Disposition: form-data; name=\"upload\"; filename=\"note.txt\"\r\n" ++
        "Content-Type: text/plain\r\n\r\n" ++
        "hello worker\r\n" ++
        "--zig-boundary--\r\n";
    var upload = try executeWorkerRequestWith(&runtime, .{
        .method = "POST",
        .uri = "/inspect",
        .content_type = "multipart/form-data; boundary=zig-boundary",
        .body = multipart_body,
    });
    defer upload.deinit();
    try expectJsonArrayContains(upload.body, "files", "upload");

    if (session_available) {
        var first_session = try executeWorkerRequestWith(&runtime, .{ .uri = "/session" });
        defer first_session.deinit();
        try expectJsonInteger(first_session.body, "session_count", 1);

        var second_session = try executeWorkerRequestWith(&runtime, .{ .uri = "/session" });
        defer second_session.deinit();
        try expectJsonInteger(second_session.body, "session_count", 2);
    }
}

test "worker bootstrap must reach request loop" {
    var runtime: PhpRuntime = .{};
    try std.testing.expectError(error.RuntimeInitializationFailed, runtime.start(
        std.testing.io,
        std.testing.allocator,
        1024 * 1024,
        .{ .script_filename = build_options.worker_exit_fixture_path, .variables = &.{} },
    ));
}

const WorkerRequestOptions = struct {
    method: []const u8 = "GET",
    uri: []const u8,
    query: []const u8 = "",
    content_type: ?[]const u8 = null,
    cookies: ?[]const u8 = null,
    body: []const u8 = "",
};

fn executeWorkerRequest(runtime: *PhpRuntime, uri: []const u8) !PhpRuntime.Response {
    return executeWorkerRequestWith(runtime, .{ .uri = uri });
}

fn executeWorkerRequestWith(runtime: *PhpRuntime, options: WorkerRequestOptions) !PhpRuntime.Response {
    const content_length = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{options.body.len});
    defer std.testing.allocator.free(content_length);
    const variables = [_]PhpRuntime.Variable{
        .{ .name = "REQUEST_METHOD", .value = options.method },
        .{ .name = "REQUEST_URI", .value = options.uri },
        .{ .name = "QUERY_STRING", .value = options.query },
        .{ .name = "SERVER_NAME", .value = "localhost" },
        .{ .name = "SERVER_PORT", .value = "8080" },
        .{ .name = "CONTENT_TYPE", .value = options.content_type orelse "" },
        .{ .name = "CONTENT_LENGTH", .value = content_length },
    };
    return runtime.execute(std.testing.allocator, .{
        .script_filename = build_options.worker_fixture_path,
        .method = options.method,
        .uri = options.uri,
        .query = options.query,
        .content_type = options.content_type,
        .cookies = options.cookies,
        .body = options.body,
        .variables = &variables,
        .headers_only = false,
    });
}

fn parseJson(body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
}

fn expectJsonString(body: []const u8, name: []const u8, expected: []const u8) !void {
    const parsed = try parseJson(body);
    defer parsed.deinit();
    try std.testing.expectEqualStrings(expected, parsed.value.object.get(name).?.string);
}

fn expectJsonInteger(body: []const u8, name: []const u8, expected: i64) !void {
    const parsed = try parseJson(body);
    defer parsed.deinit();
    try std.testing.expectEqual(expected, parsed.value.object.get(name).?.integer);
}

fn expectJsonNull(body: []const u8, name: []const u8) !void {
    const parsed = try parseJson(body);
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get(name).? == .null);
}

fn expectJsonArrayContains(body: []const u8, name: []const u8, expected: []const u8) !void {
    const parsed = try parseJson(body);
    defer parsed.deinit();
    for (parsed.value.object.get(name).?.array.items) |item| {
        if (std.mem.eql(u8, item.string, expected)) return;
    }
    return error.ExpectedArrayValueMissing;
}

fn jsonBoolean(body: []const u8, name: []const u8) !bool {
    const parsed = try parseJson(body);
    defer parsed.deinit();
    return parsed.value.object.get(name).?.bool;
}

fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

fn responsePid(body: []const u8) !i64 {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const pid = parsed.value.object.get("pid") orelse return error.MissingPid;
    return switch (pid) {
        .integer => |value| value,
        else => error.InvalidPid,
    };
}
