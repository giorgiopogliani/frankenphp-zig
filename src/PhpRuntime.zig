const PhpRuntime = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

io: Io = undefined,
gpa: Allocator = undefined,
max_output: usize = 0,
worker_group: Io.Group = .init,
started: bool = false,
queue: *JobQueue = undefined,
owned_queue: ?*JobQueue = null,
mutex: Io.Mutex = .init,
state_condition: Io.Condition = .init,
ready: bool = false,
initialized: bool = false,
worker: ?Worker = null,
worker_reached_acquire: bool = false,
interrupt_handle: CInterruptHandle = .{},
interrupt_fn: *const fn (CInterruptHandle) void = ignoreInterrupt,
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

const CInterruptHandle = extern struct {
    vm_interrupt: ?*anyopaque = null,
    timed_out: ?*anyopaque = null,
    thread: usize = 0,
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
extern fn frankenphp_zig_php_capture_interrupt_handle() CInterruptHandle;
extern fn frankenphp_zig_php_interrupt(handle: CInterruptHandle) void;
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
};

const DirectTransport = struct {
    request: *std.http.Server.Request,
    buffer: []u8,
    writer: ?std.http.BodyWriter = null,
};

const Job = struct {
    runtime: *PhpRuntime,
    arena: std.heap.ArenaAllocator,
    request: OwnedRequest,
    output: std.ArrayList(u8) = .empty,
    direct_transport: ?DirectTransport = null,
    headers: std.ArrayList(std.http.Header) = .empty,
    body_offset: usize = 0,
    status: u16 = 200,
    failure: ?anyerror = null,
    next: ?*Job = null,
    running_next: ?*Job = null,
    state: JobState = .queued,
    complete: Io.Event = .unset,
    submitted: bool = false,
    canceled: std.atomic.Value(bool) = .init(false),
    interrupt_handle: CInterruptHandle = .{},
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
        const runtime = job.runtime;
        if (job.submitted) {
            runtime.queue.mutex.lockUncancelable(runtime.io);
            std.debug.assert(runtime.queue.outstanding != 0);
            runtime.queue.outstanding -= 1;
            if (runtime.queue.outstanding == 0) runtime.queue.idle_condition.broadcast(runtime.io);
            runtime.queue.mutex.unlock(runtime.io);
        }
        job.arena.deinit();
        runtime.gpa.destroy(job);
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

const JobQueue = struct {
    mutex: Io.Mutex = .init,
    condition: Io.Condition = .init,
    idle_condition: Io.Condition = .init,
    head: ?*Job = null,
    tail: ?*Job = null,
    running_head: ?*Job = null,
    outstanding: usize = 0,
    stopping: bool = false,

    fn enqueue(queue: *JobQueue, io: Io, job: *Job) !void {
        try queue.mutex.lock(io);
        defer queue.mutex.unlock(io);
        if (queue.stopping) return error.RuntimeStopped;
        if (queue.tail) |tail| tail.next = job else queue.head = job;
        queue.tail = job;
        job.submitted = true;
        queue.outstanding += 1;
        queue.condition.signal(io);
    }

    fn stop(queue: *JobQueue, io: Io) void {
        queue.mutex.lockUncancelable(io);
        queue.stopping = true;
        queue.condition.broadcast(io);
        queue.mutex.unlock(io);
    }

    fn waitUntilIdle(queue: *JobQueue, io: Io) void {
        queue.mutex.lockUncancelable(io);
        while (queue.outstanding != 0) queue.idle_condition.waitUncancelable(io, &queue.mutex);
        queue.mutex.unlock(io);
    }
};

threadlocal var active_job: ?*Job = null;
threadlocal var active_runtime: ?*PhpRuntime = null;

pub fn start(runtime: *PhpRuntime, io: Io, gpa: Allocator, max_output: usize, worker: ?Worker) !void {
    const queue = try gpa.create(JobQueue);
    errdefer gpa.destroy(queue);
    queue.* = .{};
    try runtime.startWithLifecycle(io, gpa, max_output, worker, queue, queue, .standalone);
}

fn startPooled(
    runtime: *PhpRuntime,
    io: Io,
    gpa: Allocator,
    max_output: usize,
    worker: ?Worker,
    queue: *JobQueue,
) !void {
    try runtime.startWithLifecycle(io, gpa, max_output, worker, queue, null, .pooled);
}

fn startWithLifecycle(
    runtime: *PhpRuntime,
    io: Io,
    gpa: Allocator,
    max_output: usize,
    worker: ?Worker,
    queue: *JobQueue,
    owned_queue: ?*JobQueue,
    lifecycle: Lifecycle,
) !void {
    runtime.* = .{
        .io = io,
        .gpa = gpa,
        .max_output = max_output,
        .queue = queue,
        .owned_queue = owned_queue,
        .interrupt_fn = phpInterrupt,
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
        failQueuedJobs(runtime, false);
        runtime.awaitStopped();
        runtime.owned_queue = null;
        return error.RuntimeInitializationFailed;
    }
}

pub const DirectResponse = struct {
    job: *Job,

    pub fn started(response: *const DirectResponse) bool {
        return response.job.direct_transport.?.writer != null;
    }

    /// Waits until PHP has ended the response and returned connection ownership.
    pub fn waitForCompletion(response: *DirectResponse) !void {
        response.job.complete.wait(response.job.runtime.io) catch |err| {
            _ = cancelJob(response.job, false);
            response.job.complete.waitUncancelable(response.job.runtime.io);
            return err;
        };
        if (response.job.failure) |failure| return failure;
    }

    pub fn deinit(response: *DirectResponse) void {
        response.job.complete.waitUncancelable(response.job.runtime.io);
        response.job.destroy();
        response.* = undefined;
    }
};

pub const Pool = struct {
    gpa: Allocator,
    io: Io,
    queue: *JobQueue,
    runtimes: []PhpRuntime,
    shared_global_lifecycle: bool,

    pub fn start(io: Io, gpa: Allocator, max_output: usize, worker: ?Worker, count: usize) !Pool {
        if (count == 0) return error.InvalidWorkerCount;

        const queue = try gpa.create(JobQueue);
        errdefer gpa.destroy(queue);
        queue.* = .{};
        const runtimes = try gpa.alloc(PhpRuntime, count);
        errdefer gpa.free(runtimes);

        if (count == 1) {
            try runtimes[0].startWithLifecycle(io, gpa, max_output, worker, queue, null, .standalone);
            return .{ .gpa = gpa, .io = io, .queue = queue, .runtimes = runtimes, .shared_global_lifecycle = false };
        }

        if (frankenphp_zig_php_is_zts() == 0) return error.ZtsRequired;
        if (frankenphp_zig_php_init() != 0) return error.RuntimeInitializationFailed;
        errdefer frankenphp_zig_php_shutdown();

        var started: usize = 0;
        errdefer {
            queue.stop(io);
            for (runtimes[0..started]) |*runtime| runtime.awaitStopped();
        }
        for (runtimes) |*runtime| {
            try runtime.startPooled(io, gpa, max_output, worker, queue);
            started += 1;
        }
        return .{ .gpa = gpa, .io = io, .queue = queue, .runtimes = runtimes, .shared_global_lifecycle = true };
    }

    pub fn stop(pool: *Pool) void {
        failQueuedJobs(&pool.runtimes[0], false);
        for (pool.runtimes) |*runtime| runtime.awaitStopped();
        pool.queue.waitUntilIdle(pool.io);
        pool.gpa.free(pool.runtimes);
        pool.gpa.destroy(pool.queue);
        if (pool.shared_global_lifecycle) frankenphp_zig_php_shutdown();
        pool.* = undefined;
    }

    pub fn execute(pool: *Pool, allocator: Allocator, request: Request) !Response {
        return pool.runtimes[0].execute(allocator, request);
    }

    pub fn startDirectResponse(
        pool: *Pool,
        request: Request,
        server_request: *std.http.Server.Request,
        response_buffer: []u8,
    ) !DirectResponse {
        return pool.runtimes[0].startDirectResponse(request, server_request, response_buffer);
    }
};

pub fn stop(runtime: *PhpRuntime) void {
    if (!runtime.started) return;
    failQueuedJobs(runtime, false);
    runtime.awaitStopped();
    runtime.queue.waitUntilIdle(runtime.io);
    if (runtime.owned_queue) |queue| runtime.gpa.destroy(queue);
    runtime.owned_queue = null;
}

fn awaitStopped(runtime: *PhpRuntime) void {
    if (!runtime.started) return;
    runtime.worker_group.await(runtime.io) catch |err| switch (err) {
        error.Canceled => {},
    };
    runtime.started = false;
}

pub fn startDirectResponse(
    runtime: *PhpRuntime,
    request: Request,
    server_request: *std.http.Server.Request,
    response_buffer: []u8,
) !DirectResponse {
    if (response_buffer.len == 0) return error.InvalidResponseBuffer;
    const job = try Job.create(runtime, request);
    errdefer job.destroy();
    job.direct_transport = .{
        .request = server_request,
        .buffer = response_buffer,
    };
    try runtime.queue.enqueue(runtime.io, job);
    return .{ .job = job };
}

pub fn execute(runtime: *PhpRuntime, allocator: Allocator, request: Request) !Response {
    const job = try Job.create(runtime, request);
    var enqueued = false;
    errdefer if (!enqueued) job.destroy();
    try runtime.queue.enqueue(runtime.io, job);
    enqueued = true;

    job.complete.wait(runtime.io) catch |err| {
        if (cancelJob(job, true)) job.destroy();
        return err;
    };

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
    runtime.interrupt_handle = frankenphp_zig_php_capture_interrupt_handle();

    defer switch (runtime.lifecycle) {
        .standalone => frankenphp_zig_php_shutdown(),
        .pooled => frankenphp_zig_php_thread_shutdown(),
    };
    if (runtime.worker) |worker| return runWorker(runtime, worker);

    runClassic(runtime);
}

fn runClassic(runtime: *PhpRuntime) void {
    while (acquireJob(runtime)) |job| {
        job.run();
        completeJob(job);
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
        const reached_acquire = runtime.worker_reached_acquire;
        runtime.mutex.unlock(runtime.io);
        const stopping = isStopping(runtime);
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
    if (initialization_failed) {
        runtime.mutex.lockUncancelable(runtime.io);
        runtime.initialized = false;
        runtime.ready = true;
        runtime.state_condition.broadcast(runtime.io);
        runtime.mutex.unlock(runtime.io);
    }

    const queue = runtime.queue;
    queue.mutex.lockUncancelable(runtime.io);
    queue.stopping = true;
    var abandoned: ?*Job = null;
    while (queue.head) |job| {
        queue.head = job.next;
        job.next = null;
        job.failure = error.RuntimeStopped;
        job.complete.set(runtime.io);
        if (job.abandoned) {
            job.next = abandoned;
            abandoned = job;
        }
    }
    queue.tail = null;
    var running = queue.running_head;
    while (running) |job| : (running = job.running_next) {
        job.canceled.store(true, .release);
        runtime.interrupt_fn(job.interrupt_handle);
    }
    queue.condition.broadcast(runtime.io);
    queue.mutex.unlock(runtime.io);

    while (abandoned) |job| {
        abandoned = job.next;
        job.destroy();
    }
}

fn isStopping(runtime: *PhpRuntime) bool {
    runtime.queue.mutex.lockUncancelable(runtime.io);
    defer runtime.queue.mutex.unlock(runtime.io);
    return runtime.queue.stopping;
}

fn acquireJob(runtime: *PhpRuntime) ?*Job {
    const queue = runtime.queue;
    queue.mutex.lockUncancelable(runtime.io);
    while (true) {
        while (queue.head == null and !queue.stopping) {
            queue.condition.waitUncancelable(runtime.io, &queue.mutex);
        }
        if (queue.stopping) {
            queue.mutex.unlock(runtime.io);
            return null;
        }

        const job = queue.head.?;
        queue.head = job.next;
        if (queue.head == null) queue.tail = null;
        job.next = null;
        if (job.abandoned) {
            queue.mutex.unlock(runtime.io);
            job.complete.set(runtime.io);
            job.destroy();
            queue.mutex.lockUncancelable(runtime.io);
            continue;
        }

        job.state = .running;
        job.interrupt_handle = runtime.interrupt_handle;
        job.running_next = queue.running_head;
        queue.running_head = job;
        queue.mutex.unlock(runtime.io);
        return job;
    }
}

fn completeJob(job: *Job) void {
    const runtime = job.runtime;
    if (job.canceled.load(.acquire)) job.failure = error.Canceled;
    if (job.direct_transport) |*direct| finishDirectResponse(job, direct);

    const queue = runtime.queue;
    queue.mutex.lockUncancelable(runtime.io);
    var running = &queue.running_head;
    while (running.*) |current| {
        if (current == job) {
            running.* = current.running_next;
            break;
        }
        running = &current.running_next;
    }
    job.running_next = null;
    const abandoned = job.abandoned;
    job.complete.set(runtime.io);
    queue.mutex.unlock(runtime.io);

    if (abandoned) job.destroy();
}

/// Cancels a job and returns whether its caller still owns its allocation.
fn cancelJob(job: *Job, abandon: bool) bool {
    const runtime = job.runtime;
    const queue = runtime.queue;
    queue.mutex.lockUncancelable(runtime.io);
    if (job.complete.isSet()) {
        queue.mutex.unlock(runtime.io);
        return true;
    }

    job.canceled.store(true, .release);
    job.abandoned = abandon;
    if (job.state == .queued) {
        var current = queue.head;
        var previous: ?*Job = null;
        while (current) |candidate| {
            if (candidate == job) {
                if (previous) |before| before.next = candidate.next else queue.head = candidate.next;
                if (queue.tail == candidate) queue.tail = previous;
                candidate.next = null;
                candidate.failure = error.Canceled;
                candidate.complete.set(runtime.io);
                queue.mutex.unlock(runtime.io);
                if (abandon) candidate.destroy();
                return !abandon;
            }
            previous = candidate;
            current = candidate.next;
        }
    }

    const interrupt_handle = job.interrupt_handle;
    queue.mutex.unlock(runtime.io);
    runtime.interrupt_fn(interrupt_handle);
    return !abandon;
}

fn ignoreInterrupt(_: CInterruptHandle) void {}

fn phpInterrupt(handle: CInterruptHandle) void {
    frankenphp_zig_php_interrupt(handle);
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
    runtime.mutex.unlock(runtime.io);

    const job = acquireJob(runtime) orelse return null;
    active_job = job;
    return &job.c_request;
}

export fn frankenphp_zig_worker_complete(success: c_int) callconv(.c) void {
    const job = active_job orelse return;
    if (success == 0 and job.failure == null) job.failure = error.ExecutionFailed;
    active_job = null;

    completeJob(job);
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

fn statusAllowsBody(status: u16) bool {
    return !((status >= 100 and status < 200) or status == 204 or status == 304);
}

fn beginDirectResponse(job: *Job, direct: *DirectTransport) bool {
    if (job.canceled.load(.acquire)) return false;
    if (direct.writer != null) return true;
    direct.writer = direct.request.respondStreaming(direct.buffer, .{
        .respond_options = .{
            .status = @enumFromInt(job.status),
            .extra_headers = job.headers.items,
        },
    }) catch {
        job.failure = error.WriteFailed;
        return false;
    };
    return true;
}

fn finishDirectResponse(job: *Job, direct: *DirectTransport) void {
    if (job.failure == null and !beginDirectResponse(job, direct)) return;
    if (direct.writer) |*writer| writer.end() catch {
        job.failure = error.WriteFailed;
    };
}

export fn frankenphp_zig_headers_complete() callconv(.c) c_int {
    const job = currentJob() orelse return 0;
    if (job.direct_transport) |*direct| return @intFromBool(beginDirectResponse(job, direct));
    return 1;
}

export fn frankenphp_zig_flush() callconv(.c) void {
    const job = currentJob() orelse return;
    const direct = if (job.direct_transport) |*direct| direct else return;
    if (job.canceled.load(.acquire) or job.failure != null or !statusAllowsBody(job.status)) return;
    const writer = if (direct.writer) |*writer| writer else return;
    writer.writer.flush() catch {
        job.failure = error.WriteFailed;
        return;
    };
    writer.flush() catch {
        job.failure = error.WriteFailed;
    };
}

export fn frankenphp_zig_write(bytes: [*]const u8, length: usize) callconv(.c) usize {
    const job = currentJob() orelse return 0;
    if (job.canceled.load(.acquire) or job.failure != null) return 0;
    if (job.direct_transport) |*direct| {
        if (!statusAllowsBody(job.status)) return length;
        const writer = if (direct.writer) |*writer| writer else return 0;
        writer.writer.writeAll(bytes[0..length]) catch {
            job.failure = error.WriteFailed;
            return 0;
        };
        return length;
    }
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
    var queue: JobQueue = .{};
    var runtime: PhpRuntime = .{
        .io = std.testing.io,
        .gpa = std.testing.allocator,
        .queue = &queue,
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
    queue.head = first;
    queue.tail = second;

    markWorkerFailed(&runtime);

    try std.testing.expect(first.complete.isSet());
    try std.testing.expect(second.complete.isSet());
    try std.testing.expect(first.failure.? == error.RuntimeStopped);
    try std.testing.expect(second.failure.? == error.RuntimeStopped);
    try std.testing.expect(queue.head == null);
    try std.testing.expect(queue.tail == null);
}
