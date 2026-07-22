const std = @import("std");
const Io = std.Io;

pub const max_frame_len = 2048;
const capacity = 256;

const Slot = struct {
    seq: u64 = 0,
    len: usize = 0,
    data: [max_frame_len]u8 = undefined,
};

pub const EventBus = struct {
    mutex: Io.Mutex = .init,
    next_seq: u64 = 1,
    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

    pub fn cursor(self: *EventBus, io: Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.next_seq;
    }

    pub fn publish(
        self: *EventBus,
        io: Io,
        event_name: []const u8,
        session_id: u64,
        data: anytype,
    ) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const seq = self.next_seq;
        var frame: [max_frame_len]u8 = undefined;
        var writer = Io.Writer.fixed(&frame);
        std.json.Stringify.value(.{
            .v = 1,
            .type = "event",
            .seq = seq,
            .event = event_name,
            .session_id = session_id,
            .data = data,
        }, .{}, &writer) catch return;
        writer.writeByte('\n') catch return;

        const written = writer.buffered();
        const slot = &self.slots[seq % capacity];
        slot.seq = seq;
        slot.len = written.len;
        @memcpy(slot.data[0..written.len], written);
        self.next_seq += 1;
    }

    /// Copies the next available frame and advances `cursor`.
    pub fn read(self: *EventBus, io: Io, cursor_value: *u64, out: []u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const oldest = if (self.next_seq > capacity) self.next_seq - capacity else 1;
        if (cursor_value.* < oldest) cursor_value.* = oldest;
        if (cursor_value.* >= self.next_seq) return null;

        const slot = &self.slots[cursor_value.* % capacity];
        if (slot.seq != cursor_value.* or slot.len > out.len) {
            cursor_value.* = self.next_seq;
            return null;
        }
        @memcpy(out[0..slot.len], slot.data[0..slot.len]);
        cursor_value.* += 1;
        return out[0..slot.len];
    }
};

test "event ring returns published frames" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var bus: EventBus = .{};
    var cursor = bus.cursor(io);
    bus.publish(io, "state.changed", 3, .{ .state = "recording" });
    var out: [max_frame_len]u8 = undefined;
    const frame = bus.read(io, &cursor, &out) orelse return error.MissingEvent;
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"state.changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"recording\"") != null);
}
