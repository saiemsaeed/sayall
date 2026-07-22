const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");

pub const max_command_len = protocol.max_frame_len;

/// Binds the unix socket, removing any stale socket file first.
pub fn listen(io: Io, endpoint: paths.Endpoint) !Io.net.Server {
    try endpoint.validateParent(io);
    endpoint.validateSocket(io) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    Io.Dir.deleteFileAbsolute(io, endpoint.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const addr = try Io.net.UnixAddress.init(endpoint.path);
    var server = try addr.listen(io, .{});
    errdefer server.deinit(io);
    errdefer Io.Dir.deleteFileAbsolute(io, endpoint.path) catch {};
    try platform.makeSocketPrivate(endpoint.path);
    try endpoint.validateSocket(io);
    return server;
}

/// Sends a one-line command to the daemon and returns the reply (trimmed).
/// Caller owns the returned slice.
pub fn sendCommand(gpa: Allocator, io: Io, endpoint: paths.Endpoint, command: []const u8) ![]u8 {
    try validateCommandLength(command);
    try endpoint.validateParent(io);
    try endpoint.validateSocket(io);
    const addr = try Io.net.UnixAddress.init(endpoint.path);
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

test "listen creates a private socket and rejects a non-socket endpoint" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, @enumFromInt(0o700));
    const relative_base = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_base);
    const parent = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, std.testing.allocator);
    defer std.testing.allocator.free(parent);
    const socket_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sayall.sock", .{parent});
    defer std.testing.allocator.free(socket_path);
    const endpoint: paths.Endpoint = .{
        .path = socket_path,
        .parent = parent,
        .parent_security = .private,
    };

    {
        var server = try listen(std.testing.io, endpoint);
        defer server.deinit(std.testing.io);
        defer Io.Dir.deleteFileAbsolute(std.testing.io, socket_path) catch {};
        try endpoint.validateSocket(std.testing.io);
        const socket_stat = try Io.Dir.cwd().statFile(std.testing.io, socket_path, .{});
        try std.testing.expectEqual(@as(u32, 0o600), socket_stat.permissions.toMode() & 0o777);
    }
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = socket_path, .data = "not a socket" });
    try std.testing.expectError(error.EndpointNotSocket, listen(std.testing.io, endpoint));
    try tmp.dir.setPermissions(std.testing.io, @enumFromInt(0o755));
    try std.testing.expectError(error.EndpointParentNotPrivate, listen(std.testing.io, endpoint));
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
    const command = std.mem.trimEnd(u8, raw, "\r");
    try validateCommandLength(command);
    return command;
}

/// The newline is part of the bounded NDJSON/plaintext wire frame.
pub fn validateCommandLength(command: []const u8) !void {
    if (command.len >= max_command_len) return error.CommandTooLong;
}

pub fn writeFrame(stream: Io.net.Stream, io: Io, frame: []const u8) !void {
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(frame);
    try writer.interface.flush();
}

/// Writes a one-line reply to a client stream.
pub fn writeReply(stream: Io.net.Stream, io: Io, reply: []const u8) !void {
    try validateCommandLength(reply);
    var wbuf: [256]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(reply);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

test "command limit reserves one byte for newline" {
    var exact: [max_command_len - 1]u8 = undefined;
    try validateCommandLength(&exact);
    var overlong: [max_command_len]u8 = undefined;
    try std.testing.expectError(error.CommandTooLong, validateCommandLength(&overlong));
}
