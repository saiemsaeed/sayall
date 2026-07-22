const std = @import("std");
const builtin = @import("builtin");

pub const contracts = @import("product/contracts.zig");

pub fn integrationFor(comptime os: std.Target.Os.Tag) type {
    return switch (os) {
        .linux => @import("product/linux.zig"),
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos, .windows => @import("product/unsupported.zig"),
        else => @import("product/unsupported.zig"),
    };
}

pub const Integration = integrationFor(builtin.os.tag);

fn testShortcutPresenter(_: std.mem.Allocator, _: std.Io, _: contracts.ShortcutApplyResult) !bool {
    return true;
}

test "Darwin and Windows product integrations are explicitly unsupported" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    inline for (.{ integrationFor(.macos), integrationFor(.windows) }) |unsupported| {
        try std.testing.expectError(error.UnsupportedPlatform, unsupported.restart(std.testing.io));
        try std.testing.expectError(error.UnsupportedPlatform, unsupported.setup(std.testing.allocator, std.testing.io, &env, testShortcutPresenter));
        try std.testing.expectError(error.UnsupportedPlatform, unsupported.prepareUpdate(std.testing.allocator, std.testing.io));
        try std.testing.expectError(error.UnsupportedPlatform, unsupported.shortcut(std.testing.allocator, std.testing.io, &env, .show));
        try std.testing.expectError(error.UnsupportedPlatform, unsupported.environmentDiagnostic(&env));
        try std.testing.expectError(error.UnsupportedPlatform, unsupported.diagnostics(std.testing.allocator, std.testing.io, null));
    }
}
