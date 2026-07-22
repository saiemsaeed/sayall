const std = @import("std");
const contract = @import("contracts.zig");

pub fn restart(_: std.Io) !contract.RestartResult {
    return error.UnsupportedPlatform;
}

pub fn setup(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, comptime _: anytype) !contract.SetupResult {
    return error.UnsupportedPlatform;
}

pub fn prepareUpdate(_: std.mem.Allocator, _: std.Io) !contract.UpdatePreparation {
    return error.UnsupportedPlatform;
}

pub fn finishUpdate(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, _: contract.UpdatePlan) !contract.UpdateResult {
    return error.UnsupportedPlatform;
}

pub fn shortcut(_: std.mem.Allocator, _: std.Io, _: *const std.process.Environ.Map, _: contract.ShortcutRequest) !contract.ShortcutResult {
    return error.UnsupportedPlatform;
}

pub fn environmentDiagnostic(_: *const std.process.Environ.Map) !contract.Diagnostic {
    return error.UnsupportedPlatform;
}

pub fn diagnostics(_: std.mem.Allocator, _: std.Io, _: ?bool) !contract.Diagnostics {
    return error.UnsupportedPlatform;
}
