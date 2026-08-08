const std = @import("std");
const batch = @import("batch.zig");
const fixtures = @import("backend_contract_fixtures");

const WorkerReady = struct {
    version: u32,
    event: []const u8,
    streaming: bool,
};

const HostMethod = enum { status, toggle, reload };
const HostState = enum { idle, starting, recording, stopping, processing, delivering, success, @"error", cancelled };
const HostRequest = struct {
    version: u32,
    method: HostMethod,
};
const HostError = struct {
    code: []const u8,
    message: []const u8,
};
const HostResponse = struct {
    version: u32,
    ok: bool,
    state: HostState,
    @"error": ?HostError = null,
};

fn parse(comptime T: type, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, std.testing.allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

test "shared worker fixtures preserve canonical outcomes" {
    const ready = try parse(WorkerReady, fixtures.worker_ready_streaming);
    defer ready.deinit();
    try std.testing.expectEqual(@as(u32, 1), ready.value.version);
    try std.testing.expectEqualStrings("ready", ready.value.event);
    try std.testing.expect(ready.value.streaming);

    const success = try parse(batch.Result, fixtures.worker_result_success);
    defer success.deinit();
    try std.testing.expectEqual(.success, success.value.status);
    try std.testing.expectEqualStrings("Hello, world.", success.value.text.?);

    const warning = try parse(batch.Result, fixtures.worker_result_cleanup_warning);
    defer warning.deinit();
    try std.testing.expectEqual(batch.Warning.cleanup_failed, warning.value.warning.?);
    try std.testing.expectEqualStrings("raw transcript", warning.value.text.?);

    const no_speech = try parse(batch.Result, fixtures.worker_result_no_speech);
    defer no_speech.deinit();
    try std.testing.expectEqual(.no_speech, no_speech.value.status);

    const failed = try parse(batch.Result, fixtures.worker_result_error);
    defer failed.deinit();
    try std.testing.expectEqual(batch.ErrorCode.deepgram_rate_limited, failed.value.@"error".?);
}

test "shared host fixtures preserve status toggle reload and structured errors" {
    const status = try parse(HostRequest, fixtures.host_status_request);
    defer status.deinit();
    try std.testing.expectEqual(@as(u32, 2), status.value.version);
    try std.testing.expectEqual(HostMethod.status, status.value.method);

    const toggle = try parse(HostRequest, fixtures.host_toggle_request);
    defer toggle.deinit();
    try std.testing.expectEqual(HostMethod.toggle, toggle.value.method);

    const reload = try parse(HostRequest, fixtures.host_reload_request);
    defer reload.deinit();
    try std.testing.expectEqual(HostMethod.reload, reload.value.method);

    const idle = try parse(HostResponse, fixtures.host_status_response);
    defer idle.deinit();
    try std.testing.expect(idle.value.ok);
    try std.testing.expectEqual(HostState.idle, idle.value.state);
    try std.testing.expectEqual(@as(?HostError, null), idle.value.@"error");

    const busy = try parse(HostResponse, fixtures.host_busy_response);
    defer busy.deinit();
    try std.testing.expect(!busy.value.ok);
    try std.testing.expectEqual(HostState.processing, busy.value.state);
    try std.testing.expectEqualStrings("busy", busy.value.@"error".?.code);
    try std.testing.expectEqualStrings("SayAll is processing", busy.value.@"error".?.message);
}
