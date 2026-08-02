//! Darwin runtime boundary. Native capture, input, clipboard, notification,
//! path, and IPC integrations are intentionally not implemented yet.
const unsupported = @import("unsupported.zig");
const std = @import("std");

pub const Recorder = unsupported.Recorder;
pub const typeText = unsupported.typeText;
pub const copyToClipboard = unsupported.copyToClipboard;
pub const pasteClipboard = unsupported.pasteClipboard;
pub const sendNotification = unsupported.sendNotification;
pub fn configFile(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) return error.InvalidConfigHome;
        return try std.fmt.allocPrint(gpa, "{s}/sayall/config.json", .{dir});
    }
    if (env.get("HOME")) |home| {
        if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.InvalidConfigHome;
        return try std.fmt.allocPrint(gpa, "{s}/.config/sayall/config.json", .{home});
    }
    return null;
}
pub const keywordsFile = unsupported.keywordsFile;
pub const metricsFile = unsupported.metricsFile;
pub const runtimeRoot = unsupported.runtimeRoot;
pub const effectiveUserId = unsupported.effectiveUserId;
pub const validatePrivateParent = unsupported.validatePrivateParent;
pub const validateSharedTmpParent = unsupported.validateSharedTmpParent;
pub const validatePrivateSocket = unsupported.validatePrivateSocket;
pub const validateSocketKind = unsupported.validateSocketKind;
pub const makeSocketPrivate = unsupported.makeSocketPrivate;
