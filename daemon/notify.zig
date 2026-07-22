const std = @import("std");
const Io = std.Io;

/// Best-effort desktop notification. Never fails the caller.
pub fn send(io: Io, title: []const u8, body: []const u8) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "notify-send", "--app-name=SayAll", title, body },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    // Wait to avoid zombie processes; notify-send exits quickly.
    _ = child.wait(io) catch {};
}
