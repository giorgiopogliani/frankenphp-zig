const PhpRuntime = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

io: Io = undefined,
gpa: Allocator = undefined,
max_output: usize = 0,
worker_group: Io.Group = .init,
started: bool = false,
mutex: Io.Mutex = .init,
queue_condition: Io.Condition = .init,
state_condition: Io.Condition = .init,
queue_head: ?*Job = null,
queue_tail: ?*Job = null,
ready: bool = false,
initialized: bool = false,
stopping: bool = false,
worker: ?Worker = null,
worker_reached_acquire: bool = false,
lifecycle: Lifecycle = .standalone,

const Lifecycle = enum {
    standalone,
    pooled,
};

pub const Variable = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    script_filename: []const u8,
    method: []const u8,
    uri: []const u8,
    query: []const u8,
    content_type: ?[]const u8,
    cookies: ?[]const u8,
    body: []const u8,
    variables: []const Variable,
    headers_only: bool,
};

pub const Worker = struct {
    script_filename: []const u8,
    variables: []const Variable,
};

pub const Response = struct {
    status: std.http.Status,
    headers: []const std.http.Header,
    body: []const u8,
    allocator: Allocator,

    pub fn deinit(response: *Response) void {
        for (response.headers) |header| {
            response.allocator.free(header.name);
            response.allocator.free(header.value);
        }
        response.allocator.free(response.headers);
        response.allocator.free(response.body);
        response.* = undefined;
    }
};

pub const Error = error{
    ExecutionFailed,
    InvalidResponse,
    OutputTooLarge,
    RuntimeInitializationFailed,
    RuntimeStopped,
};

const CRequest = extern struct {
    script_filename: [*:0]const u8,
    request_method: [*:0]const u8,
    request_uri: [*:0]const u8,
    query_string: [*:0]const u8,
    content_type: ?[*:0]const u8,
    content_length: i64,
    headers_only: c_int,
};

extern fn frankenphp_zig_php_init() c_int;
extern fn frankenphp_zig_php_shutdown() void;
extern fn frankenphp_zig_php_is_zts() c_int;
extern fn frankenphp_zig_php_thread_init() void;
extern fn frankenphp_zig_php_thread_shutdown() void;
extern fn frankenphp_zig_php_execute(request: *const CRequest) c_int;
extern fn frankenphp_zig_php_execute_worker(request: *const CRequest) c_int;

const OwnedRequest = struct {
    script_filename: [:0]const u8,
    method: [:0]const u8,
    uri: [:0]const u8,
    query: [:0]const u8,
    content_type: ?[:0]const u8,
    cookies: ?[:0]const u8,
    body: []const u8,
    variables: []const OwnedVariable,
    headers_only: bool,
};

const OwnedVariable = struct {
    name: [:0]const u8,
    value: [:0]const u8,
};

const JobState = enum {
    queued,
    running,
    completed,
};

const Job = struct {
    runtime: *PhpRuntime,
    arena: std.heap.ArenaAllocator,
    request: OwnedRequest,
    output: std.ArrayList(u8) = .empty,
    stream_queue: Io.Queue(u8) = undefined,
    streaming: bool = false,
    has_flushed: bool = false,
    response_ready: Io.Event = .unset,
    headers: std.ArrayList(std.http.Header) = .empty,
    body_offset: usize = 0,
    status: u16 = 200,
    failure: ?anyerror = null,
    next: ?*Job = null,
    state: JobState = .queued,
    abandoned: bool = false,
    c_request: CRequest = undefined,

    fn create(runtime: *PhpRuntime, request: Request) !*Job {
        const job = try runtime.gpa.create(Job);
        errdefer runtime.gpa.destroy(job);

        job.* = .{
            .runtime = runtime,
            .arena = .init(runtime.gpa),
            .request = undefined,
        };
        errdefer job.arena.deinit();

        job.request = try cloneRequest(job.arena.allocator(), request);
        job.c_request = cRequest(&job.request);
        return job;
    }

    fn destroy(job: *Job) void {
        const gpa = job.runtime.gpa;
        job.arena.deinit();
        gpa.destroy(job);
    }

    fn run(job: *Job) void {
        active_job = job;
        defer active_job = null;

        if (frankenphp_zig_php_execute(&job.c_request) != 0 and job.failure == null) {
            job.failure = error.ExecutionFailed;
        }
    }

    fn response(job: *const Job, allocator: Allocator) !Response {
        if (job.failure) |failure| return failure;

        const headers = try allocator.alloc(std.http.Header, job.headers.items.len);
        var initialized_headers: usize = 0;
        errdefer {
            for (headers[0..initialized_headers]) |header| {
                allocator.free(header.name);
                allocator.free(header.value);
            }
            allocator.free(headers);
        }
        for (job.headers.items, headers) |source, *destination| {
            const name = try allocator.dupe(u8, source.name);
            errdefer allocator.free(name);
            destination.* = .{
                .name = name,
                .value = try allocator.dupe(u8, source.value),
            };
            initialized_headers += 1;
        }

        const status: std.http.Status = @enumFromInt(job.status);
        const status_code = @intFromEnum(status);
        const body = if ((status_code >= 100 and status_code < 200) or status_code == 204 or status_code == 304)
            try allocator.dupe(u8, "")
        else
            try allocator.dupe(u8, job.output.items);

        return .{
            .status = status,
            .headers = headers,
            .body = body,
            .allocator = allocator,
        };
    }
};

threadlocal var active_job: ?*Job = null;
threadlocal var active_runtime: ?*PhpRuntime = null;

pub fn start(runtime: *PhpRuntime, io: Io, gpa: Allocator, max_output: usize, worker: ?Worker) !void {
    try runtime.startWithLifecycle(io, gpa, max_output, worker, .standalone);
}

fn startPooled(runtime: *PhpRuntime, io: Io, gpa: Allocator, max_output: usize, worker: ?Worker) !void {
    try runtime.startWithLifecycle(io, gpa, max_output, worker, .pooled);
}

fn startWithLifecycle(runtime: *PhpRuntime, io: Io, gpa: Allocator, max_output: usize, worker: ?Worker, lifecycle: Lifecycle) !void {
    runtime.* = .{
        .io = io,
        .gpa = gpa,
        .max_output = max_output,
        .worker = worker,
        .lifecycle = lifecycle,
    };
    runtime.worker_group.concurrent(io, workerMain, .{runtime}) catch return error.RuntimeInitializationFailed;
    runtime.started = true;

    runtime.mutex.lockUncancelable(io);
    while (!runtime.ready) runtime.state_condition.waitUncancelable(io, &runtime.mutex);
    const initialized = runtime.initialized;
    runtime.mutex.unlock(io);

    if (!initialized) {
        runtime.stop();
        return error.RuntimeInitializationFailed;
    }
}

pub const Stream = struct {
    job: *Job,

    pub fn waitForHeaders(stream: *Stream) !void {
        try stream.job.response_ready.wait(stream.job.runtime.io);
        if (stream.job.failure) |failure| return failure;
    }

    pub fn status(stream: *const Stream) std.http.Status {
        return @enumFromInt(stream.job.status);
    }

    pub fn headers(stream: *const Stream) []const std.http.Header {
        return stream.job.headers.items;
    }

    pub fn bufferedBody(stream: *const Stream) ?[]const u8 {
        return if (stream.job.has_flushed) null else stream.job.output.items;
    }

    pub fn read(stream: *Stream, buffer: []u8) !usize {
        return stream.job.stream_queue.get(stream.job.runtime.io, buffer, 1) catch |err| switch (err) {
            error.Closed => 0,
            else => return err,
        };
    }

    pub fn deinit(stream: *Stream) void {
        const runtime = stream.job.runtime;
        runtime.mutex.lockUncancelable(runtime.io);
        while (stream.job.state != .completed) runtime.state_condition.waitUncancelable(runtime.io, &runtime.mutex);
        runtime.mutex.unlock(runtime.io);
        stream.job.destroy();
        stream.* = undefined;
    }
};

pub const Pool = struct {
    gpa: Allocator,
    runtimes: []PhpRuntime,
    shared_global_lifecycle: bool,
    next: std.atomic.Value(usize) = .init(0),

    pub fn start(io: Io, gpa: Allocator, max_output: usize, worker: ?Worker, count: usize) !Pool {
        if (count == 0) return error.InvalidWorkerCount;

        const runtimes = try gpa.alloc(PhpRuntime, count);
        errdefer gpa.free(runtimes);
        if (count == 1) {
            try runtimes[0].start(io, gpa, max_output, worker);
            return .{ .gpa = gpa, .runtimes = runtimes, .shared_global_lifecycle = false };
        }

        if (frankenphp_zig_php_is_zts() == 0) return error.ZtsRequired;
        if (frankenphp_zig_php_init() != 0) return error.RuntimeInitializationFailed;
        errdefer frankenphp_zig_php_shutdown();

        var started: usize = 0;
        errdefer {
            for (runtimes[0..started]) |*runtime| runtime.stop();
        }
        for (runtimes) |*runtime| {
            try runtime.startPooled(io, gpa, max_output, worker);
            started += 1;
        }
        return .{ .gpa = gpa, .runtimes = runtimes, .shared_global_lifecycle = true };
    }

    pub fn stop(pool: *Pool) void {
        for (pool.runtimes) |*runtime| runtime.stop();
        pool.gpa.free(pool.runtimes);
        if (pool.shared_global_lifecycle) frankenphp_zig_php_shutdown();
        pool.* = undefined;
    }

    pub fn execute(pool: *Pool, allocator: Allocator, request: Request) !Response {
        const index = pool.next.fetchAdd(1, .monotonic) % pool.runtimes.len;
        return pool.runtimes[index].execute(allocator, request);
    }

    pub fn startStream(pool: *Pool, request: Request, queue_buffer: []u8) !Stream {
        const index = pool.next.fetchAdd(1, .monotonic) % pool.runtimes.len;
        return pool.runtimes[index].startStream(request, queue_buffer);
    }
};

pub fn stop(runtime: *PhpRuntime) void {
    if (!runtime.started) return;
    failQueuedJobs(runtime, false);
    runtime.worker_group.await(runtime.io) catch |err| switch (err) {
        error.Canceled => {},
    };
    runtime.started = false;
}

pub fn startStream(runtime: *PhpRuntime, request: Request, queue_buffer: []u8) !Stream {
    if (queue_buffer.len == 0) return error.InvalidStreamQueueCapacity;
    const job = try Job.create(runtime, request);
    errdefer job.destroy();
    job.streaming = true;
    job.stream_queue = .init(queue_buffer);
    try enqueue(runtime, job);
    return .{ .job = job };
}

fn enqueue(runtime: *PhpRuntime, job: *Job) !void {
    try runtime.mutex.lock(runtime.io);
    errdefer runtime.mutex.unlock(runtime.io);
    if (runtime.stopping) return error.RuntimeStopped;
    if (runtime.queue_tail) |tail| tail.next = job else runtime.queue_head = job;
    runtime.queue_tail = job;
    runtime.queue_condition.signal(runtime.io);
    runtime.mutex.unlock(runtime.io);
}

pub fn execute(runtime: *PhpRuntime, allocator: Allocator, request: Request) !Response {
    const job = try Job.create(runtime, request);
    var enqueued = false;
    errdefer if (!enqueued) job.destroy();

    try runtime.mutex.lock(runtime.io);
    if (runtime.stopping) {
        runtime.mutex.unlock(runtime.io);
        return error.RuntimeStopped;
    }
    if (runtime.queue_tail) |tail| tail.next = job else runtime.queue_head = job;
    runtime.queue_tail = job;
    enqueued = true;
    runtime.queue_condition.signal(runtime.io);

    while (job.state != .completed) {
        runtime.state_condition.wait(runtime.io, &runtime.mutex) catch |err| {
            if (job.state != .completed) {
                job.abandoned = true;
                runtime.mutex.unlock(runtime.io);
                return err;
            }
        };
    }
    runtime.mutex.unlock(runtime.io);

    defer job.destroy();
    return job.response(allocator);
}

fn workerMain(runtime: *PhpRuntime) void {
    const initialized = switch (runtime.lifecycle) {
        .standalone => frankenphp_zig_php_init() == 0,
        .pooled => blk: {
            frankenphp_zig_php_thread_init();
            break :blk true;
        },
    };

    active_runtime = runtime;
    defer active_runtime = null;

    runtime.mutex.lockUncancelable(runtime.io);
    if (!initialized or runtime.worker == null) {
        runtime.initialized = initialized;
        runtime.ready = true;
        runtime.state_condition.broadcast(runtime.io);
    }
    runtime.mutex.unlock(runtime.io);
    if (!initialized) return;

    defer switch (runtime.lifecycle) {
        .standalone => frankenphp_zig_php_shutdown(),
        .pooled => frankenphp_zig_php_thread_shutdown(),
    };
    if (runtime.worker) |worker| return runWorker(runtime, worker);

    runClassic(runtime);
}

fn runClassic(runtime: *PhpRuntime) void {
    while (true) {
        runtime.mutex.lockUncancelable(runtime.io);
        while (runtime.queue_head == null and !runtime.stopping) {
            runtime.queue_condition.waitUncancelable(runtime.io, &runtime.mutex);
        }
        if (runtime.queue_head == null and runtime.stopping) {
            runtime.mutex.unlock(runtime.io);
            return;
        }

        const job = runtime.queue_head.?;
        runtime.queue_head = job.next;
        if (runtime.queue_head == null) runtime.queue_tail = null;
        job.next = null;
        if (job.abandoned) {
            job.state = .completed;
            runtime.mutex.unlock(runtime.io);
            job.destroy();
            continue;
        }
        job.state = .running;
        runtime.mutex.unlock(runtime.io);

        job.run();

        if (job.streaming) {
            job.response_ready.set(runtime.io);
            if (job.has_flushed) {
                publishPendingOutput(job);
                job.stream_queue.close(runtime.io);
            }
        }
        runtime.mutex.lockUncancelable(runtime.io);
        const abandoned = job.abandoned;
        job.state = .completed;
        runtime.state_condition.broadcast(runtime.io);
        runtime.mutex.unlock(runtime.io);

        if (abandoned) job.destroy();
    }
}

fn runWorker(runtime: *PhpRuntime, worker: Worker) void {
    while (!isStopping(runtime)) {
        runtime.mutex.lockUncancelable(runtime.io);
        runtime.worker_reached_acquire = false;
        runtime.mutex.unlock(runtime.io);

        const bootstrap = Job.create(runtime, .{
            .script_filename = worker.script_filename,
            .method = "GET",
            .uri = "/",
            .query = "",
            .content_type = null,
            .cookies = null,
            .body = "",
            .variables = worker.variables,
            .headers_only = false,
        }) catch {
            markWorkerFailed(runtime);
            return;
        };
        active_job = bootstrap;
        const result = frankenphp_zig_php_execute_worker(&bootstrap.c_request);
        var request_failed = false;
        if (active_job) |job| {
            if (job != bootstrap) {
                request_failed = true;
                frankenphp_zig_worker_complete(0);
            }
        }
        active_job = null;

        runtime.mutex.lockUncancelable(runtime.io);
        const stopping = runtime.stopping;
        const reached_acquire = runtime.worker_reached_acquire;
        runtime.mutex.unlock(runtime.io);
        if (bootstrap.output.items.len != 0 and (result != 0 or !reached_acquire)) {
            std.log.err("PHP worker bootstrap: {s}", .{bootstrap.output.items});
        }
        bootstrap.destroy();
        if (stopping) return;
        if (!reached_acquire) {
            markWorkerFailed(runtime);
            return;
        }
        if (result != 0 and !request_failed) {
            // Octane workers may intentionally exit after their request limit.
            // The runtime thread remains valid, so run a fresh worker bootstrap
            // instead of permanently removing this slot from the pool.
            std.log.warn("PHP worker exited; restarting it", .{});
            continue;
        }
    }
}

fn markWorkerFailed(runtime: *PhpRuntime) void {
    failQueuedJobs(runtime, true);
}

fn failQueuedJobs(runtime: *PhpRuntime, initialization_failed: bool) void {
    runtime.mutex.lockUncancelable(runtime.io);
    runtime.stopping = true;
    if (initialization_failed) {
        runtime.initialized = false;
        runtime.ready = true;
    }

    var abandoned: ?*Job = null;
    while (runtime.queue_head) |job| {
        runtime.queue_head = job.next;
        job.next = null;
        job.failure = error.RuntimeStopped;
        job.state = .completed;
        if (job.abandoned) {
            job.next = abandoned;
            abandoned = job;
        }
    }
    runtime.queue_tail = null;
    runtime.state_condition.broadcast(runtime.io);
    runtime.queue_condition.broadcast(runtime.io);
    runtime.mutex.unlock(runtime.io);

    while (abandoned) |job| {
        abandoned = job.next;
        job.destroy();
    }
}

fn isStopping(runtime: *PhpRuntime) bool {
    runtime.mutex.lockUncancelable(runtime.io);
    defer runtime.mutex.unlock(runtime.io);
    return runtime.stopping;
}

fn cRequest(request: *const OwnedRequest) CRequest {
    return .{
        .script_filename = request.script_filename.ptr,
        .request_method = request.method.ptr,
        .request_uri = request.uri.ptr,
        .query_string = request.query.ptr,
        .content_type = if (request.content_type) |value| value.ptr else null,
        .content_length = @intCast(request.body.len),
        .headers_only = @intFromBool(request.headers_only),
    };
}

export fn frankenphp_zig_worker_acquire() callconv(.c) ?*const CRequest {
    const runtime = active_runtime orelse return null;
    active_job = null;

    runtime.mutex.lockUncancelable(runtime.io);
    if (!runtime.ready) {
        runtime.initialized = true;
        runtime.ready = true;
        runtime.state_condition.broadcast(runtime.io);
    }
    runtime.worker_reached_acquire = true;

    while (true) {
        while (runtime.queue_head == null and !runtime.stopping) {
            runtime.queue_condition.waitUncancelable(runtime.io, &runtime.mutex);
        }
        if (runtime.stopping) {
            runtime.mutex.unlock(runtime.io);
            return null;
        }

        const job = runtime.queue_head.?;
        runtime.queue_head = job.next;
        if (runtime.queue_head == null) runtime.queue_tail = null;
        job.next = null;
        if (job.abandoned) {
            job.state = .completed;
            job.destroy();
            continue;
        }

        job.state = .running;
        active_job = job;
        runtime.mutex.unlock(runtime.io);
        return &job.c_request;
    }
}

export fn frankenphp_zig_worker_complete(success: c_int) callconv(.c) void {
    const job = active_job orelse return;
    const runtime = job.runtime;
    if (success == 0 and job.failure == null) job.failure = error.ExecutionFailed;
    active_job = null;

    if (job.streaming) {
        job.response_ready.set(runtime.io);
        if (job.has_flushed) {
            publishPendingOutput(job);
            job.stream_queue.close(runtime.io);
        }
    }
    runtime.mutex.lockUncancelable(runtime.io);
    const abandoned = job.abandoned;
    job.state = .completed;
    runtime.state_condition.broadcast(runtime.io);
    runtime.mutex.unlock(runtime.io);

    if (abandoned) job.destroy();
}

fn cloneRequest(allocator: Allocator, request: Request) !OwnedRequest {
    const variables = try allocator.alloc(OwnedVariable, request.variables.len);
    for (request.variables, variables) |source, *destination| {
        destination.* = .{
            .name = try allocator.dupeZ(u8, source.name),
            .value = try allocator.dupeZ(u8, source.value),
        };
    }

    return .{
        .script_filename = try allocator.dupeZ(u8, request.script_filename),
        .method = try allocator.dupeZ(u8, request.method),
        .uri = try allocator.dupeZ(u8, request.uri),
        .query = try allocator.dupeZ(u8, request.query),
        .content_type = if (request.content_type) |value| try allocator.dupeZ(u8, value) else null,
        .cookies = if (request.cookies) |value| try allocator.dupeZ(u8, value) else null,
        .body = try allocator.dupe(u8, request.body),
        .variables = variables,
        .headers_only = request.headers_only,
    };
}

fn currentJob() ?*Job {
    return active_job;
}

fn publishPendingOutput(job: *Job) void {
    if (job.output.items.len == 0) return;
    job.stream_queue.putAll(job.runtime.io, job.output.items) catch {
        job.failure = error.RuntimeStopped;
        return;
    };
    job.output.clearRetainingCapacity();
}

export fn frankenphp_zig_flush() callconv(.c) void {
    const job = currentJob() orelse return;
    if (!job.streaming) return;
    job.has_flushed = true;
    job.response_ready.set(job.runtime.io);
    publishPendingOutput(job);
}

export fn frankenphp_zig_write(bytes: [*]const u8, length: usize) callconv(.c) usize {
    const job = currentJob() orelse return 0;
    if (job.failure != null) return 0;
    if (length > job.runtime.max_output -| job.output.items.len) {
        job.failure = error.OutputTooLarge;
        return 0;
    }
    job.output.appendSlice(job.arena.allocator(), bytes[0..length]) catch {
        job.failure = error.OutOfMemory;
        return 0;
    };
    return length;
}

export fn frankenphp_zig_read_post(buffer: [*]u8, length: usize) callconv(.c) usize {
    const job = currentJob() orelse return 0;
    const remaining = job.request.body[job.body_offset..];
    const read_length = @min(length, remaining.len);
    @memcpy(buffer[0..read_length], remaining[0..read_length]);
    job.body_offset += read_length;
    return read_length;
}

export fn frankenphp_zig_read_cookies() callconv(.c) ?[*:0]const u8 {
    const job = currentJob() orelse return null;
    return if (job.request.cookies) |cookies| cookies.ptr else null;
}

export fn frankenphp_zig_variable_count() callconv(.c) usize {
    const job = currentJob() orelse return 0;
    return job.request.variables.len;
}

export fn frankenphp_zig_variable_name(index: usize) callconv(.c) ?[*:0]const u8 {
    const job = currentJob() orelse return null;
    if (index >= job.request.variables.len) return null;
    return job.request.variables[index].name.ptr;
}

export fn frankenphp_zig_variable_value(index: usize, length: *usize) callconv(.c) ?[*:0]const u8 {
    const job = currentJob() orelse return null;
    if (index >= job.request.variables.len) return null;
    const value = job.request.variables[index].value;
    length.* = value.len;
    return value.ptr;
}

export fn frankenphp_zig_getenv(name: [*]const u8, name_length: usize) callconv(.c) ?[*:0]const u8 {
    const job = currentJob() orelse return null;
    const name_slice = name[0..name_length];
    var index = job.request.variables.len;
    while (index > 0) {
        index -= 1;
        const variable = job.request.variables[index];
        if (std.mem.eql(u8, variable.name, name_slice)) return variable.value.ptr;
    }
    return null;
}

export fn frankenphp_zig_set_status(status: c_int) callconv(.c) c_int {
    const job = currentJob() orelse return 0;
    if (status < 200 or status > 599) {
        job.failure = error.InvalidResponse;
        return 0;
    }
    job.status = @intCast(status);
    return 1;
}

export fn frankenphp_zig_add_header(header: [*]const u8, length: usize) callconv(.c) c_int {
    const job = currentJob() orelse return 0;
    const line = header[0..length];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
        job.failure = error.InvalidResponse;
        return 0;
    };
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (!isValidHeaderName(name) or !isValidHeaderValue(value)) {
        job.failure = error.InvalidResponse;
        return 0;
    }
    if (isHopByHopOrFramingHeader(name)) return 1;

    const allocator = job.arena.allocator();
    const owned_name = allocator.dupe(u8, name) catch {
        job.failure = error.OutOfMemory;
        return 0;
    };
    const owned_value = allocator.dupe(u8, value) catch {
        job.failure = error.OutOfMemory;
        return 0;
    };
    job.headers.append(allocator, .{ .name = owned_name, .value = owned_value }) catch {
        job.failure = error.OutOfMemory;
        return 0;
    };
    return 1;
}

export fn frankenphp_zig_log(message: [*:0]const u8) callconv(.c) void {
    std.log.err("PHP: {s}", .{std.mem.span(message)});
}

fn isHopByHopOrFramingHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-authenticate") or
        std.ascii.eqlIgnoreCase(name, "proxy-authorization") or
        std.ascii.eqlIgnoreCase(name, "te") or
        std.ascii.eqlIgnoreCase(name, "trailer") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "upgrade") or
        std.ascii.eqlIgnoreCase(name, "content-length");
}

fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
            else => return false,
        }
    }
    return true;
}

fn isValidHeaderValue(value: []const u8) bool {
    return std.mem.indexOfAny(u8, value, &.{ 0, '\r', '\n' }) == null;
}

test "embedded response headers reject invalid data and framing headers" {
    try std.testing.expect(isValidHeaderName("X-FrankenPHP"));
    try std.testing.expect(!isValidHeaderName("Bad Header"));
    try std.testing.expect(isValidHeaderValue("application/json"));
    try std.testing.expect(!isValidHeaderValue("value\r\ninjected: true"));
    try std.testing.expect(isHopByHopOrFramingHeader("Content-Length"));
}

test "worker failure completes every queued job" {
    var runtime: PhpRuntime = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
    };
    const request: Request = .{
        .script_filename = "/worker.php",
        .method = "GET",
        .uri = "/",
        .query = "",
        .content_type = null,
        .cookies = null,
        .body = "",
        .variables = &.{},
        .headers_only = false,
    };
    const first = try Job.create(&runtime, request);
    defer first.destroy();
    const second = try Job.create(&runtime, request);
    defer second.destroy();
    first.next = second;
    runtime.queue_head = first;
    runtime.queue_tail = second;

    markWorkerFailed(&runtime);

    try std.testing.expectEqual(JobState.completed, first.state);
    try std.testing.expectEqual(JobState.completed, second.state);
    try std.testing.expect(first.failure.? == error.RuntimeStopped);
    try std.testing.expect(second.failure.? == error.RuntimeStopped);
    try std.testing.expect(runtime.queue_head == null);
    try std.testing.expect(runtime.queue_tail == null);
}
