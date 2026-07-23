const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Recorder = struct {
    pub fn start(_: *Recorder, _: Allocator, _: Io, _: []const u8, _: []const u8) ![]const u8 {
        return error.UnsupportedPlatform;
    }

    pub fn stop(_: *Recorder, _: Io) !types.Recording {
        return error.UnsupportedPlatform;
    }

    pub fn cancel(_: *Recorder, _: Allocator, _: Io) !void {
        return error.UnsupportedPlatform;
    }
};

pub fn typeText(_: Io, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn copyToClipboard(_: Io, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn pasteClipboard(_: Io) !void {
    return error.UnsupportedPlatform;
}

pub fn sendNotification(_: Io, _: []const u8, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn configFile(_: Allocator, _: *const std.process.Environ.Map) !?[]u8 {
    return error.UnsupportedPlatform;
}

pub fn keywordsFile(_: Allocator, _: *const std.process.Environ.Map) !?[]u8 {
    return error.UnsupportedPlatform;
}

pub fn metricsFile(_: Allocator, _: *const std.process.Environ.Map) ![]u8 {
    return error.UnsupportedPlatform;
}

pub fn runtimeRoot(_: *const std.process.Environ.Map) !types.RuntimeRoot {
    return error.UnsupportedPlatform;
}

pub fn effectiveUserId() !u32 {
    return error.UnsupportedPlatform;
}

pub fn validatePrivateParent(_: Io, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn validateSharedTmpParent(_: Io, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn validatePrivateSocket(_: Io, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn validateSocketKind(_: Io, _: []const u8) !void {
    return error.UnsupportedPlatform;
}

pub fn makeSocketPrivate(_: []const u8) !void {
    return error.UnsupportedPlatform;
}
