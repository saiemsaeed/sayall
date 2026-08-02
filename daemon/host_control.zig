const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const ipc = @import("ipc.zig");
const paths = @import("paths.zig");

pub const Linux = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,

    pub fn adapter(self: *Linux) cli.HostControl {
        return .{ .context = self, .statusFn = status, .toggleFn = toggle };
    }
    fn status(ctx: *anyopaque) cli.HostOutcome {
        return send(ctx, "status");
    }
    fn toggle(ctx: *anyopaque) cli.HostOutcome {
        return send(ctx, "toggle");
    }
    fn send(ctx: *anyopaque, command: []const u8) cli.HostOutcome {
        if (builtin.os.tag != .linux) return .unavailable;
        const self: *Linux = @ptrCast(@alignCast(ctx));
        const runtime = paths.Runtime.discover(self.arena, self.env) catch |err| return .{ .transport_error = diagnostic(self.arena, err) };
        const reply = ipc.sendCommand(self.arena, self.io, runtime.endpoint, command) catch |err| return .{ .transport_error = diagnostic(self.arena, err) };
        return mapReply(self.arena, reply);
    }
};

fn mapReply(arena: std.mem.Allocator, reply: []const u8) cli.HostOutcome {
    if (std.mem.eql(u8, reply, "idle")) return .idle;
    if (std.mem.eql(u8, reply, "recording")) return .recording;
    if (std.mem.eql(u8, reply, "stopping")) return .stopping;
    if (std.mem.eql(u8, reply, "processing")) return .processing;
    const line = std.fmt.allocPrint(arena, "{s}\n", .{reply}) catch "sayall: out of memory\n";
    if (std.mem.startsWith(u8, reply, "busy")) return .{ .busy = line };
    if (std.mem.startsWith(u8, reply, "error:")) return .{ .operation_error = line };
    return .{ .incompatible = line };
}

fn diagnostic(arena: std.mem.Allocator, err: anyerror) []const u8 {
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

test "every deployed plaintext reply maps without losing text" {
    const allocator = std.testing.allocator;
    try std.testing.expect(mapReply(allocator, "idle") == .idle);
    try std.testing.expect(mapReply(allocator, "recording") == .recording);
    try std.testing.expect(mapReply(allocator, "stopping") == .stopping);
    try std.testing.expect(mapReply(allocator, "processing") == .processing);
    for ([_][]const u8{ "busy: still processing previous clip", "busy: daemon is not idle", "busy: no active recording", "busy: processing cannot be cancelled" }) |reply| {
        const mapped = mapReply(allocator, reply);
        defer allocator.free(mapped.busy);
        const expected = try std.fmt.allocPrint(allocator, "{s}\n", .{reply});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, mapped.busy);
    }
    const failed = mapReply(allocator, "error: could not stop recording");
    defer allocator.free(failed.operation_error);
    try std.testing.expectEqualStrings("error: could not stop recording\n", failed.operation_error);
}
