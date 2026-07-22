const std = @import("std");
const darwin = @import("darwin.zig");
const windows = @import("windows.zig");

fn expectUnsupported(comptime runtime: type) !void {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var recorder: runtime.Recorder = .{};
    try std.testing.expectError(
        error.UnsupportedPlatform,
        recorder.start(std.testing.allocator, std.testing.io, "/tmp", ""),
    );
    try std.testing.expectError(error.UnsupportedPlatform, recorder.stop(std.testing.io));
    try std.testing.expectError(
        error.UnsupportedPlatform,
        recorder.cancel(std.testing.allocator, std.testing.io),
    );
    try std.testing.expectError(error.UnsupportedPlatform, runtime.typeText(std.testing.io, "text"));
    try std.testing.expectError(error.UnsupportedPlatform, runtime.copyToClipboard(std.testing.io, "text"));
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime.sendNotification(std.testing.io, "title", "body"),
    );
    try std.testing.expectError(error.UnsupportedPlatform, runtime.configFile(std.testing.allocator, &env));
    try std.testing.expectError(error.UnsupportedPlatform, runtime.keywordsFile(std.testing.allocator, &env));
    try std.testing.expectError(error.UnsupportedPlatform, runtime.metricsFile(std.testing.allocator, &env));
    try std.testing.expectError(error.UnsupportedPlatform, runtime.runtimeRoot(&env));
    try std.testing.expectError(error.UnsupportedPlatform, runtime.effectiveUserId());
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime.validatePrivateParent(std.testing.io, "/tmp"),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime.validateSharedTmpParent(std.testing.io, "/tmp"),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime.validatePrivateSocket(std.testing.io, "/tmp/sayall.sock"),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime.validateSocketKind(std.testing.io, "/tmp/sayall.sock"),
    );
    try std.testing.expectError(error.UnsupportedPlatform, runtime.makeSocketPrivate("/tmp/sayall.sock"));
}

test "Darwin runtime operations fail explicitly" {
    try expectUnsupported(darwin);
}

test "Windows runtime operations fail explicitly" {
    try expectUnsupported(windows);
}
