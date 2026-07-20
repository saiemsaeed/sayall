const std = @import("std");
const Io = std.Io;

pub const OutputError = error{ TypeFailed, ClipboardFailed };

/// Delivers text to the user. "type" uses wtype, and "clipboard" only copies
/// the transcript. Direct typing falls back to the clipboard on failure.
pub fn deliver(io: Io, method: []const u8, text: []const u8) !void {
    if (std.mem.eql(u8, method, "clipboard")) {
        return copyToClipboard(io, text);
    }
    typeText(io, text) catch {
        try copyToClipboard(io, text);
    };
}

/// Match Handy's Wayland direct-input path: pass the complete transcript as a
/// protected argument rather than streaming characters through stdin.
fn typeText(io: Io, text: []const u8) !void {
    try run(io, &.{ "wtype", "--", text }, error.TypeFailed);
}

/// Copies text to the Wayland clipboard via `wl-copy`.
fn copyToClipboard(io: Io, text: []const u8) !void {
    try feedStdin(io, &.{"wl-copy"}, text, error.ClipboardFailed);
}

fn run(io: Io, argv: []const []const u8, fail: OutputError) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return fail;
    const term = child.wait(io) catch return fail;
    switch (term) {
        .exited => |code| if (code != 0) return fail,
        else => return fail,
    }
}

fn feedStdin(io: Io, argv: []const []const u8, text: []const u8, fail: OutputError) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return fail;

    const stdin = child.stdin orelse {
        _ = child.wait(io) catch {};
        return fail;
    };

    var wbuf: [4096]u8 = undefined;
    var writer = stdin.writer(io, &wbuf);
    writer.interface.writeAll(text) catch {
        stdin.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        return fail;
    };
    writer.interface.flush() catch {};
    stdin.close(io);
    child.stdin = null;

    const term = child.wait(io) catch return fail;
    switch (term) {
        .exited => |code| if (code != 0) return fail,
        else => return fail,
    }
}
