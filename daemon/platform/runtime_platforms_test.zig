const std = @import("std");
const darwin = @import("darwin.zig");
const windows = @import("windows.zig");

fn expectUnsupported(comptime runtime: type, comptime config_supported: bool) !void {
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
    try std.testing.expectError(error.UnsupportedPlatform, runtime.pasteClipboard(std.testing.io));
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime.sendNotification(std.testing.io, "title", "body"),
    );
    if (config_supported) {
        try env.put("HOME", "/tmp/home");
        const path = (try runtime.configFile(std.testing.allocator, &env)).?;
        defer std.testing.allocator.free(path);
        try std.testing.expectEqualStrings("/tmp/home/.config/sayall/config.json", path);
        const keywords_path = (try runtime.keywordsFile(std.testing.allocator, &env)).?;
        defer std.testing.allocator.free(keywords_path);
        try std.testing.expectEqualStrings("/tmp/home/.config/sayall/keywords.json", keywords_path);
    } else {
        try std.testing.expectError(error.UnsupportedPlatform, runtime.configFile(std.testing.allocator, &env));
        try std.testing.expectError(error.UnsupportedPlatform, runtime.keywordsFile(std.testing.allocator, &env));
    }
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
    try expectUnsupported(darwin, true);
}

test "Windows runtime operations fail explicitly" {
    try expectUnsupported(windows, false);
}
