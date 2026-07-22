const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");

pub const max_frame_len = protocol.max_frame_len;
pub const history_capacity = 256;

const Slot = struct {
    seq: u64 = 0,
    data: ?[]u8 = null,
};

pub const Gap = struct {
    expected_seq: u64,
    oldest_available: u64,
    next_seq: u64,
};

pub const ReadResult = union(enum) {
    event: []const u8,
    empty,
    gap: Gap,
};

pub const EventBus = struct {
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    next_seq: u64 = 1,
    slots: [history_capacity]Slot = [_]Slot{.{}} ** history_capacity,

    pub fn init(gpa: Allocator) EventBus {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EventBus) void {
        for (&self.slots) |*slot| {
            if (slot.data) |data| self.gpa.free(data);
            slot.* = .{};
        }
    }

    pub fn cursor(self: *EventBus, io: Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.next_seq;
    }

    pub fn publish(self: *EventBus, io: Io, session_id: u64, event: protocol.EventData) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const seq = self.next_seq;
        self.next_seq += 1;
        const slot = &self.slots[seq % history_capacity];
        if (slot.data) |old| self.gpa.free(old);
        // Reserve the sequence before fallible encoding/allocation. A missing
        // slot is then an explicit gap instead of undetectable event loss.
        slot.* = .{ .seq = seq, .data = null };

        var frame: [max_frame_len]u8 = undefined;
        const encoded = try encodeEvent(&frame, seq, session_id, event);
        const owned = try self.gpa.dupe(u8, encoded);
        errdefer self.gpa.free(owned);

        slot.* = .{ .seq = seq, .data = owned };
    }

    /// Copies one frame without ever repairing a stale cursor implicitly.
    /// A gap is terminal for that subscription; the client must resubscribe.
    pub fn read(self: *EventBus, io: Io, cursor_value: *u64, out: []u8) ReadResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const oldest = if (self.next_seq > history_capacity) self.next_seq - history_capacity else 1;
        if (cursor_value.* < oldest) return .{ .gap = .{
            .expected_seq = cursor_value.*,
            .oldest_available = oldest,
            .next_seq = self.next_seq,
        } };
        if (cursor_value.* >= self.next_seq) return .empty;

        const slot = &self.slots[cursor_value.* % history_capacity];
        const data = slot.data orelse return .{ .gap = .{
            .expected_seq = cursor_value.*,
            .oldest_available = oldest,
            .next_seq = self.next_seq,
        } };
        if (slot.seq != cursor_value.* or data.len > out.len) return .{ .gap = .{
            .expected_seq = cursor_value.*,
            .oldest_available = oldest,
            .next_seq = self.next_seq,
        } };

        @memcpy(out[0..data.len], data);
        cursor_value.* += 1;
        return .{ .event = out[0..data.len] };
    }
};

fn encodeEvent(
    storage: []u8,
    seq: u64,
    session_id: u64,
    event: protocol.EventData,
) ![]const u8 {
    return switch (event) {
        inline else => |data, name| protocol.encodeFrame(storage, protocol.EventFrame(@TypeOf(data)){
            .seq = seq,
            .event = protocol.eventName(name),
            .session_id = session_id,
            .data = data,
        }),
    };
}

test "event ring returns strictly consecutive typed frames" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var cursor = bus.cursor(std.testing.io);
    try bus.publish(std.testing.io, 3, .{ .state_changed = .{
        .state = .recording,
        .stage = null,
        .session_id = 3,
        .elapsed_ms = 0,
        .cleanup = true,
    } });
    try bus.publish(std.testing.io, 3, .{ .audio_level = .{
        .rms = 0.18,
        .peak = 0.52,
        .clipping = false,
        .window_ms = 100,
    } });

    var out: [max_frame_len]u8 = undefined;
    var expected_seq: u64 = 1;
    while (expected_seq <= 2) : (expected_seq += 1) {
        const frame = switch (bus.read(std.testing.io, &cursor, &out)) {
            .event => |frame| frame,
            else => return error.MissingEvent,
        };
        const Envelope = struct { seq: u64, event: []const u8 };
        const parsed = try std.json.parseFromSlice(Envelope, std.testing.allocator, frame, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        try std.testing.expectEqual(expected_seq, parsed.value.seq);
    }
    try std.testing.expectEqual(@as(u64, 3), cursor);
    try std.testing.expect(bus.read(std.testing.io, &cursor, &out) == .empty);
}

test "event ring reports overflow gap without changing cursor" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var cursor = bus.cursor(std.testing.io);
    for (0..history_capacity + 1) |_| {
        try bus.publish(std.testing.io, 1, .{ .recording_limit_reached = .{} });
    }

    const original = cursor;
    var out: [max_frame_len]u8 = undefined;
    const gap = switch (bus.read(std.testing.io, &cursor, &out)) {
        .gap => |gap| gap,
        else => return error.MissingGap,
    };
    try std.testing.expectEqual(original, cursor);
    try std.testing.expectEqual(@as(u64, 1), gap.expected_seq);
    try std.testing.expectEqual(@as(u64, 2), gap.oldest_available);
    try std.testing.expectEqual(@as(u64, history_capacity + 2), gap.next_seq);
}

test "failed event publication leaves an explicit sequence gap" {
    var bus = EventBus.init(std.testing.allocator);
    defer bus.deinit();
    var message: [max_frame_len]u8 = undefined;
    @memset(&message, 'x');
    try std.testing.expectError(error.FrameTooLong, bus.publish(std.testing.io, 4, .{ .operation_error = .{
        .code = "oversized",
        .message = &message,
    } }));
    try std.testing.expectEqual(@as(u64, 2), bus.cursor(std.testing.io));

    try bus.publish(std.testing.io, 4, .{ .recording_limit_reached = .{} });
    var cursor: u64 = 1;
    var out: [max_frame_len]u8 = undefined;
    try std.testing.expect(bus.read(std.testing.io, &cursor, &out) == .gap);
    cursor = 2;
    const frame = switch (bus.read(std.testing.io, &cursor, &out)) {
        .event => |value| value,
        else => return error.MissingEvent,
    };
    const parsed = try std.json.parseFromSlice(
        protocol.EventFrame(protocol.RecordingLimitReached),
        std.testing.allocator,
        frame,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 2), parsed.value.seq);
}
