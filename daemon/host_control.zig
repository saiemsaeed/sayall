const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cli = @import("cli.zig");
const ipc = @import("ipc.zig");
const paths = @import("paths.zig");
const fixtures = @import("protocol_fixtures");

pub const version: u16 = 2;
/// The trailing newline is part of this bound.
pub const max_frame_len = 64 * 1024;
pub const Method = enum { status, toggle };
pub const State = enum { idle, starting, recording, stopping, processing, delivering, success, @"error", cancelled };
pub const Request = struct { version: u16, method: Method };
pub const Failure = struct { code: []const u8, message: []const u8 };
pub const Response = struct { version: u16, ok: bool, state: State, @"error": ?Failure = null };

pub fn parseRequest(gpa: Allocator, frame: []const u8) !std.json.Parsed(Request) {
    try validateFrame(frame);
    const parsed = try std.json.parseFromSlice(Request, gpa, frame, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.version != version) return error.UnsupportedVersion;
    return parsed;
}

pub fn parseResponse(gpa: Allocator, frame: []const u8) !std.json.Parsed(Response) {
    try validateFrame(frame);
    const parsed = try std.json.parseFromSlice(Response, gpa, frame, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.version != version) return error.UnsupportedVersion;
    if (parsed.value.ok == (parsed.value.@"error" != null)) return error.InvalidResponse;
    return parsed;
}

fn validateFrame(frame: []const u8) !void {
    // `frame` excludes the newline, so at most 65535 bytes are valid.
    if (frame.len >= max_frame_len) return error.FrameTooLong;
}

pub fn writeResponse(stream: Io.net.Stream, io: Io, response: Response) !void {
    var storage: [max_frame_len]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    std.json.Stringify.value(response, .{ .emit_null_optional_fields = false }, &writer) catch return error.FrameTooLong;
    writer.writeByte('\n') catch return error.FrameTooLong;
    try ipc.writeFrame(stream, io, writer.buffered());
}

/// Performs exactly one exchange. A toggle is never retried.
pub fn exchange(gpa: Allocator, io: Io, endpoint: paths.Endpoint, method: Method) !std.json.Parsed(Response) {
    var storage: [max_frame_len]u8 = undefined;
    var writer = Io.Writer.fixed(&storage);
    try std.json.Stringify.value(Request{ .version = version, .method = method }, .{}, &writer);
    const reply = try ipc.sendCommand(gpa, io, endpoint, writer.buffered());
    defer gpa.free(reply);
    return parseResponse(gpa, reply);
}

pub const Linux = struct {
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    exchangeFn: *const fn (*Linux, Method) cli.HostOutcome = productionExchange,

    pub fn adapter(self: *Linux) cli.HostControl {
        return .{ .context = self, .statusFn = status, .toggleFn = toggle };
    }
    fn status(ctx: *anyopaque) cli.HostOutcome {
        return send(ctx, .status);
    }
    fn toggle(ctx: *anyopaque) cli.HostOutcome {
        return send(ctx, .toggle);
    }
    fn send(ctx: *anyopaque, method: Method) cli.HostOutcome {
        if (builtin.os.tag != .linux) return .unavailable;
        const self: *Linux = @ptrCast(@alignCast(ctx));
        return sendWithExchange(self, method);
    }
    fn productionExchange(self: *Linux, method: Method) cli.HostOutcome {
        const runtime = paths.Runtime.discover(self.arena, self.env) catch |err| return .{ .transport_error = diagnostic(self.arena, err) };
        const parsed = exchange(self.arena, self.io, runtime.endpoint, method) catch |err| return mapExchangeError(self.arena, err);
        defer parsed.deinit();
        return mapResponsePublic(self.arena, parsed.value);
    }
};

fn sendWithExchange(linux: *Linux, method: Method) cli.HostOutcome {
    // Deliberately one call: status, toggle, and failures are never retried.
    return linux.exchangeFn(linux, method);
}

fn mapExchangeError(arena: Allocator, err: anyerror) cli.HostOutcome {
    return if (err == error.UnsupportedVersion)
        .{ .incompatible = "sayall: incompatible host control protocol\n" }
    else
        .{ .transport_error = diagnostic(arena, err) };
}

pub fn mapResponsePublic(arena: Allocator, response: Response) cli.HostOutcome {
    if (!response.ok) {
        const failure = response.@"error".?;
        const line = std.fmt.allocPrint(arena, "{s}: {s}\n", .{ failure.code, failure.message }) catch "sayall: out of memory\n";
        return if (std.mem.eql(u8, failure.code, "busy")) .{ .busy = line } else .{ .operation_error = line };
    }
    return switch (response.state) {
        .idle => .idle,
        .starting => .starting,
        .recording => .recording,
        .stopping => .stopping,
        .processing => .processing,
        .delivering => .delivering,
        .success => .success,
        .@"error" => .host_error,
        .cancelled => .cancelled,
    };
}

fn diagnostic(arena: Allocator, err: anyerror) []const u8 {
    return std.fmt.allocPrint(arena, "sayall: cannot reach daemon ({s}) — is 'sayall daemon' running?\n", .{@errorName(err)}) catch "sayall: cannot reach daemon\n";
}

pub const Unavailable = struct {
    pub fn adapter(self: *Unavailable) cli.HostControl {
        return .{ .context = self, .statusFn = call, .toggleFn = call };
    }
    fn call(_: *anyopaque) cli.HostOutcome {
        return .unavailable;
    }
};

test "v2 codec fixtures additions closed values semantics and frame bound" {
    const request = try parseRequest(std.testing.allocator, fixtures.host_status_request);
    defer request.deinit();
    try std.testing.expectEqual(Method.status, request.value.method);
    const toggle = try parseRequest(std.testing.allocator, fixtures.host_toggle_request);
    defer toggle.deinit();
    try std.testing.expectEqual(Method.toggle, toggle.value.method);
    const idle = try parseResponse(std.testing.allocator, fixtures.host_status_response);
    defer idle.deinit();
    try std.testing.expect(idle.value.ok);
    const busy = try parseResponse(std.testing.allocator, fixtures.host_busy_response);
    defer busy.deinit();
    try std.testing.expectEqualStrings("busy", busy.value.@"error".?.code);
    const additive = try parseResponse(std.testing.allocator, "{\"version\":2,\"ok\":true,\"state\":\"cancelled\",\"future\":true}");
    defer additive.deinit();
    try std.testing.expectEqual(State.cancelled, additive.value.state);
    try std.testing.expectError(error.UnsupportedVersion, parseRequest(std.testing.allocator, "{\"version\":3,\"method\":\"toggle\"}"));
    try std.testing.expectError(error.MissingField, parseRequest(std.testing.allocator, "{\"method\":\"toggle\"}"));
    try std.testing.expectError(error.InvalidEnumTag, parseRequest(std.testing.allocator, "{\"version\":2,\"method\":\"remove\"}"));
    try std.testing.expectError(error.InvalidEnumTag, parseResponse(std.testing.allocator, "{\"version\":2,\"ok\":true,\"state\":\"future\"}"));
    try std.testing.expectError(error.UnsupportedVersion, parseResponse(std.testing.allocator, "{\"version\":3,\"ok\":true,\"state\":\"idle\"}"));
    try std.testing.expectError(error.InvalidResponse, parseResponse(std.testing.allocator, "{\"version\":2,\"ok\":false,\"state\":\"idle\"}"));
    try std.testing.expectError(error.InvalidResponse, parseResponse(std.testing.allocator, "{\"version\":2,\"ok\":true,\"state\":\"idle\",\"error\":{\"code\":\"x\",\"message\":\"y\"}}"));
    var too_long: [max_frame_len]u8 = undefined;
    try std.testing.expectError(error.FrameTooLong, parseRequest(std.testing.allocator, &too_long));
}

test "structured response strings are owned independently of input" {
    var frame = try std.testing.allocator.dupe(u8, "{\"version\":2,\"ok\":false,\"state\":\"processing\",\"error\":{\"code\":\"busy\",\"message\":\"SayAll is processing\"}}");
    const parsed = try parseResponse(std.testing.allocator, frame);
    defer parsed.deinit();
    std.testing.allocator.free(frame);
    frame = undefined;
    try std.testing.expectEqualStrings("busy", parsed.value.@"error".?.code);
    try std.testing.expectEqualStrings("SayAll is processing", parsed.value.@"error".?.message);
}

test "adapter maps every closed state and structured failures" {
    inline for (std.meta.tags(State)) |state| {
        const mapped = mapResponsePublic(std.testing.allocator, .{ .version = 2, .ok = true, .state = state });
        try std.testing.expect(std.mem.eql(u8, @tagName(state), switch (mapped) {
            .host_error => "error",
            else => @tagName(mapped),
        }));
    }
    const busy = mapResponsePublic(std.testing.allocator, .{ .version = 2, .ok = false, .state = .processing, .@"error" = .{ .code = "busy", .message = "SayAll is processing" } });
    defer std.testing.allocator.free(busy.busy);
    try std.testing.expectEqualStrings("busy: SayAll is processing\n", busy.busy);
    const denied = mapResponsePublic(std.testing.allocator, .{ .version = 2, .ok = false, .state = .idle, .@"error" = .{ .code = "denied", .message = "No access" } });
    defer std.testing.allocator.free(denied.operation_error);
    try std.testing.expectEqualStrings("denied: No access\n", denied.operation_error);

    const incompatible = mapExchangeError(std.testing.allocator, error.UnsupportedVersion);
    try std.testing.expectEqualStrings("sayall: incompatible host control protocol\n", incompatible.incompatible);
}

test "linux transport invokes exchange exactly once without retry" {
    const Fake = struct {
        var calls: usize = 0;
        var outcome: cli.HostOutcome = .idle;
        fn call(_: *Linux, _: Method) cli.HostOutcome {
            calls += 1;
            return outcome;
        }
    };
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var linux: Linux = .{ .arena = std.testing.allocator, .io = std.testing.io, .env = &env, .exchangeFn = Fake.call };
    inline for (.{ Method.status, Method.toggle }) |method| {
        Fake.calls = 0;
        Fake.outcome = .idle;
        _ = sendWithExchange(&linux, method);
        try std.testing.expectEqual(@as(usize, 1), Fake.calls);
    }
    Fake.calls = 0;
    Fake.outcome = .{ .transport_error = "failed" };
    _ = sendWithExchange(&linux, .toggle);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls);
}
