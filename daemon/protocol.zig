const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const fixtures = @import("protocol_fixtures");

pub const version: u16 = 1;
/// Maximum bytes in one NDJSON frame, including its trailing newline.
pub const max_frame_len = 64 * 1024;

pub const RequestParams = struct {
    cleanup: bool = true,
};

/// Method remains a string so an older v1 server can reject a newer additive
/// method with `unknown_method` instead of rejecting the whole JSON frame.
pub const Request = struct {
    v: u16,
    type: []const u8,
    id: u64,
    method: []const u8,
    params: RequestParams = .{},
};

pub const Error = struct {
    code: []const u8,
    message: []const u8,
};

pub fn Response(comptime Result: type) type {
    return struct {
        v: u16 = version,
        type: []const u8 = "response",
        id: u64,
        ok: bool = true,
        result: Result,
    };
}

pub const ErrorResponse = struct {
    v: u16 = version,
    type: []const u8 = "response",
    id: u64,
    ok: bool = false,
    @"error": Error,
};

pub const State = enum { idle, recording, stopping, processing };
pub const ProcessingStage = enum { validating, transcribing, cleaning, delivering };

pub const StateSnapshot = struct {
    state: State,
    stage: ?ProcessingStage,
    session_id: u64,
    elapsed_ms: i64,
    cleanup: bool,
};

pub const Capabilities = struct {
    protocol_version: u16 = version,
    platform: []const u8,
    live_levels: bool,
    text_injection: bool,
    clipboard_fallback: bool,
    stats: bool,
    streaming_stt: bool,
};

pub const SubscribeResult = struct {
    state: StateSnapshot,
    /// Sequence of the first event strictly after `state`'s barrier.
    next_seq: u64,
};

pub const StateChanged = StateSnapshot;
pub const AudioLevel = struct {
    rms: f64,
    peak: f64,
    clipping: bool,
    window_ms: u32,
};
pub const ProcessingStageChanged = struct {
    stage: ?ProcessingStage,
};
pub const RecordingLimitReached = struct {};
pub const OperationError = Error;
pub const OutputCompleted = struct {
    method: []const u8,
};
pub const SessionPhase = enum { pre_stt, stt, post_stt };
pub const SessionCompleted = struct {
    ok: bool,
    phase: SessionPhase,
    reason: ?[]const u8,
    stt_attempted: bool,
    latency_ms: u64,
};

pub const EventName = enum {
    state_changed,
    audio_level,
    processing_stage_changed,
    recording_limit_reached,
    operation_error,
    output_completed,
    session_completed,
};

pub fn eventName(name: EventName) []const u8 {
    return switch (name) {
        .state_changed => "state.changed",
        .audio_level => "audio.level",
        .processing_stage_changed => "processing.stage_changed",
        .recording_limit_reached => "recording.limit_reached",
        .operation_error => "operation.error",
        .output_completed => "output.completed",
        .session_completed => "session.completed",
    };
}

/// The tagged union keeps every event name coupled to its v1 payload schema.
pub const EventData = union(EventName) {
    state_changed: StateChanged,
    audio_level: AudioLevel,
    processing_stage_changed: ProcessingStageChanged,
    recording_limit_reached: RecordingLimitReached,
    operation_error: OperationError,
    output_completed: OutputCompleted,
    session_completed: SessionCompleted,
};

pub fn EventFrame(comptime Data: type) type {
    return struct {
        v: u16 = version,
        type: []const u8 = "event",
        seq: u64,
        event: []const u8,
        session_id: u64,
        data: Data,
    };
}

pub fn parseRequest(gpa: Allocator, frame: []const u8) !std.json.Parsed(Request) {
    try validateFrameLength(frame);
    const parsed = try std.json.parseFromSlice(Request, gpa, frame, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.v != version) return error.UnsupportedVersion;
    if (!std.mem.eql(u8, parsed.value.type, "request")) return error.InvalidFrame;
    return parsed;
}

pub fn validateFrameLength(frame_without_newline: []const u8) !void {
    if (frame_without_newline.len >= max_frame_len) return error.FrameTooLong;
}

/// Encodes exactly one bounded NDJSON frame into caller-owned storage.
pub fn encodeFrame(storage: []u8, value: anytype) ![]const u8 {
    if (storage.len < max_frame_len) return error.BufferTooSmall;
    var json_writer = Io.Writer.fixed(storage[0..max_frame_len]);
    std.json.Stringify.value(value, .{}, &json_writer) catch return error.FrameTooLong;
    json_writer.writeByte('\n') catch return error.FrameTooLong;
    return json_writer.buffered();
}

pub fn writeResponse(stream: Io.net.Stream, io: Io, id: u64, result: anytype) !void {
    return writeFrame(stream, io, Response(@TypeOf(result)){
        .id = id,
        .result = result,
    });
}

pub fn writeError(stream: Io.net.Stream, io: Io, id: u64, code: []const u8, message: []const u8) !void {
    return writeFrame(stream, io, ErrorResponse{
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    });
}

pub fn writeFrame(stream: Io.net.Stream, io: Io, value: anytype) !void {
    var frame: [max_frame_len]u8 = undefined;
    const encoded = try encodeFrame(&frame, value);

    var socket_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &socket_buffer);
    try writer.interface.writeAll(encoded);
    try writer.interface.flush();
}

fn parseGolden(comptime T: type, bytes: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, std.testing.allocator, bytes, .{ .ignore_unknown_fields = true });
}

test "request parser validates frames and preserves additive fields" {
    const valid = try parseRequest(std.testing.allocator,
        \\{"v":1,"type":"request","id":4,"method":"get_state","params":{"future":true},"trace":"ignored"}
    );
    defer valid.deinit();
    try std.testing.expectEqual(@as(u64, 4), valid.value.id);
    try std.testing.expect(valid.value.params.cleanup);

    try std.testing.expectError(error.UnsupportedVersion, parseRequest(std.testing.allocator,
        \\{"v":2,"type":"request","id":4,"method":"get_state","params":{}}
    ));
    try std.testing.expectError(error.InvalidFrame, parseRequest(std.testing.allocator,
        \\{"v":1,"type":"event","id":4,"method":"get_state","params":{}}
    ));
    try std.testing.expectError(error.UnexpectedEndOfInput, parseRequest(std.testing.allocator, "{"));
}

test "request and generated frame limits include the NDJSON newline" {
    var overlong: [max_frame_len]u8 = undefined;
    @memset(&overlong, ' ');
    try std.testing.expectError(error.FrameTooLong, parseRequest(std.testing.allocator, &overlong));

    var storage: [max_frame_len]u8 = undefined;
    const huge = [_]u8{'x'} ** max_frame_len;
    try std.testing.expectError(error.FrameTooLong, encodeFrame(&storage, .{ .value = &huge }));

    const encoded = try encodeFrame(&storage, ErrorResponse{
        .id = 9,
        .@"error" = .{ .code = "invalid_request", .message = "bad JSON" },
    });
    try std.testing.expect(encoded.len <= max_frame_len);
    try std.testing.expectEqual(@as(u8, '\n'), encoded[encoded.len - 1]);
}

test "shared golden request and envelopes remain v1 compatible" {
    const request = try parseRequest(std.testing.allocator, fixtures.request_additive);
    defer request.deinit();
    try std.testing.expectEqualStrings("toggle", request.value.method);
    try std.testing.expect(!request.value.params.cleanup);

    const capabilities = try parseGolden(Response(Capabilities), fixtures.response_capabilities_additive);
    defer capabilities.deinit();
    try std.testing.expect(capabilities.value.result.streaming_stt);

    const state = try parseGolden(Response(StateSnapshot), fixtures.response_state_additive);
    defer state.deinit();
    try std.testing.expectEqual(State.processing, state.value.result.state);
    try std.testing.expectEqual(ProcessingStage.transcribing, state.value.result.stage.?);

    const subscription = try parseGolden(Response(SubscribeResult), fixtures.response_subscribe_additive);
    defer subscription.deinit();
    try std.testing.expectEqual(@as(u64, 19), subscription.value.result.next_seq);

    const response_error = try parseGolden(ErrorResponse, fixtures.response_error_additive);
    defer response_error.deinit();
    try std.testing.expectEqualStrings("invalid_state", response_error.value.@"error".code);

    const AnyEvent = struct {
        v: u16,
        type: []const u8,
        seq: u64,
        event: []const u8,
        session_id: u64,
        data: std.json.Value,
    };
    const unknown = try parseGolden(AnyEvent, fixtures.event_unknown_additive);
    defer unknown.deinit();
    try std.testing.expectEqualStrings("future.progress", unknown.value.event);

    var lines = std.mem.tokenizeScalar(u8, fixtures.events_known, '\n');
    var expected_seq: u64 = 19;
    while (lines.next()) |line| : (expected_seq += 1) {
        const envelope = try parseGolden(AnyEvent, line);
        defer envelope.deinit();
        try std.testing.expectEqual(expected_seq, envelope.value.seq);
        if (std.mem.eql(u8, envelope.value.event, eventName(.state_changed))) {
            const parsed = try parseGolden(EventFrame(StateChanged), line);
            defer parsed.deinit();
            try std.testing.expectEqual(State.recording, parsed.value.data.state);
        } else if (std.mem.eql(u8, envelope.value.event, eventName(.audio_level))) {
            const parsed = try parseGolden(EventFrame(AudioLevel), line);
            defer parsed.deinit();
            try std.testing.expectEqual(@as(u32, 100), parsed.value.data.window_ms);
        } else if (std.mem.eql(u8, envelope.value.event, eventName(.processing_stage_changed))) {
            const parsed = try parseGolden(EventFrame(ProcessingStageChanged), line);
            defer parsed.deinit();
            try std.testing.expectEqual(ProcessingStage.validating, parsed.value.data.stage.?);
        } else if (std.mem.eql(u8, envelope.value.event, eventName(.recording_limit_reached))) {
            const parsed = try parseGolden(EventFrame(RecordingLimitReached), line);
            defer parsed.deinit();
        } else if (std.mem.eql(u8, envelope.value.event, eventName(.operation_error))) {
            const parsed = try parseGolden(EventFrame(OperationError), line);
            defer parsed.deinit();
            try std.testing.expectEqualStrings("transcription_failed", parsed.value.data.code);
        } else if (std.mem.eql(u8, envelope.value.event, eventName(.output_completed))) {
            const parsed = try parseGolden(EventFrame(OutputCompleted), line);
            defer parsed.deinit();
            try std.testing.expectEqualStrings("type", parsed.value.data.method);
        } else if (std.mem.eql(u8, envelope.value.event, eventName(.session_completed))) {
            const parsed = try parseGolden(EventFrame(SessionCompleted), line);
            defer parsed.deinit();
            try std.testing.expectEqual(SessionPhase.post_stt, parsed.value.data.phase);
        } else return error.MissingKnownEventSchema;
    }
    try std.testing.expectEqual(@as(u64, 26), expected_seq);
}
