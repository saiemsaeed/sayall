const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const version = 1;
pub const max_frame_len = 64 * 1024;

pub const Params = struct {
    cleanup: bool = true,
};

pub const Request = struct {
    v: u16,
    type: []const u8,
    id: u64,
    method: []const u8,
    params: Params = .{},
};

pub fn parseRequest(gpa: Allocator, frame: []const u8) !std.json.Parsed(Request) {
    const parsed = try std.json.parseFromSlice(Request, gpa, frame, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    if (parsed.value.v != version) return error.UnsupportedVersion;
    if (!std.mem.eql(u8, parsed.value.type, "request")) return error.InvalidFrame;
    return parsed;
}

pub fn writeResponse(stream: Io.net.Stream, io: Io, id: u64, result: anytype) !void {
    return writeFrame(stream, io, .{
        .v = version,
        .type = "response",
        .id = id,
        .ok = true,
        .result = result,
    });
}

pub fn writeError(stream: Io.net.Stream, io: Io, id: u64, code: []const u8, message: []const u8) !void {
    return writeFrame(stream, io, .{
        .v = version,
        .type = "response",
        .id = id,
        .ok = false,
        .@"error" = .{ .code = code, .message = message },
    });
}

pub fn writeFrame(stream: Io.net.Stream, io: Io, value: anytype) !void {
    var frame: [max_frame_len]u8 = undefined;
    var json_writer = Io.Writer.fixed(&frame);
    try std.json.Stringify.value(value, .{}, &json_writer);
    try json_writer.writeByte('\n');

    var socket_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &socket_buffer);
    try writer.interface.writeAll(json_writer.buffered());
    try writer.interface.flush();
}

test "request parser validates protocol version" {
    const valid = try parseRequest(std.testing.allocator,
        \\{"v":1,"type":"request","id":4,"method":"get_state","params":{}}
    );
    defer valid.deinit();
    try std.testing.expectEqual(@as(u64, 4), valid.value.id);
    try std.testing.expectError(error.UnsupportedVersion, parseRequest(std.testing.allocator,
        \\{"v":2,"type":"request","id":4,"method":"get_state","params":{}}
    ));
}
