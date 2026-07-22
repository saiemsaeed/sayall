const std = @import("std");
const Io = std.Io;
const platform = @import("platform.zig");

pub const OutputError = error{ TypeFailed, ClipboardFailed, UnsupportedPlatform };

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
    try platform.typeText(io, text);
}

/// Copies text to the Wayland clipboard via `wl-copy`.
fn copyToClipboard(io: Io, text: []const u8) !void {
    try platform.copyToClipboard(io, text);
}
