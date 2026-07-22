const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_command_len = 64 * 1024;

/// Binds the unix socket, removing any stale socket file first.
pub fn listen(io: Io, path: []const u8) !Io.net.Server {
    Io.Dir.deleteFileAbsolute(io, path) catch {};
    const addr = try Io.net.UnixAddress.init(path);
    return addr.listen(io, .{});
}

/// Sends a one-line command to the daemon and returns the reply (trimmed).
/// Caller owns the returned slice.
pub fn sendCommand(gpa: Allocator, io: Io, path: []const u8, command: []const u8) ![]u8 {
    const addr = try Io.net.UnixAddress.init(path);
    var stream = try addr.connect(io);
    defer stream.close(io);

    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(command);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    const line = try reader.interface.takeDelimiter('\n') orelse return error.EmptyResponse;
    return gpa.dupe(u8, std.mem.trimEnd(u8, line, "\r"));
}

/// Reads a single newline-terminated command from a client stream.
/// Returns the command (without newline) pointing into `storage`, or null on EOF.
pub fn readCommand(stream: Io.net.Stream, io: Io, storage: []u8) !?[]const u8 {
    var reader = stream.reader(io, storage);
    const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.CommandTooLong,
        else => return err,
    };
    const raw = line orelse return null;
    return std.mem.trimEnd(u8, raw, "\r");
}

pub fn writeFrame(stream: Io.net.Stream, io: Io, frame: []const u8) !void {
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(frame);
    try writer.interface.flush();
}

/// Writes a one-line reply to a client stream.
pub fn writeReply(stream: Io.net.Stream, io: Io, reply: []const u8) !void {
    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(reply);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}
