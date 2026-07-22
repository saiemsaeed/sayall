const std = @import("std");
const platform = @import("platform.zig");

/// Dispatches notification mechanics to the compile-time runtime backend.
pub fn send(io: std.Io, title: []const u8, body: []const u8) !void {
    return platform.sendNotification(io, title, body);
}
