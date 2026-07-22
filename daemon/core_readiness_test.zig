//! Compile-only readiness coverage for the portable core boundary.
//!
//! The build graph compiles this test root for Darwin and Windows but never
//! runs or installs the resulting foreign test artifact. It intentionally
//! stops below `main.zig`: a runnable native CLI and Windows argv adaptation
//! are outside the 0.1.4 support contract.
const std = @import("std");
const builtin = @import("builtin");

const config = @import("config.zig");
const daemon = @import("daemon.zig");
const events = @import("events.zig");
const metrics = @import("metrics.zig");
const platform = @import("platform.zig");
const product = @import("product.zig");
const product_contracts = @import("product/contracts.zig");
const protocol = @import("protocol.zig");
const recorder = @import("recorder.zig");

const explicit_runtime = switch (builtin.os.tag) {
    .macos => @import("platform/darwin.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("core readiness checks are defined only for macOS and Windows"),
};
const unsupported_product = @import("product/unsupported.zig");

comptime {
    // Reference portable orchestration and its representative contracts, not
    // just the recorder helpers, so API drift is diagnosed on both targets.
    std.testing.refAllDecls(config);
    std.testing.refAllDecls(daemon);
    std.testing.refAllDecls(events);
    std.testing.refAllDecls(metrics);
    std.testing.refAllDecls(product_contracts);
    std.testing.refAllDecls(protocol);
    std.testing.refAllDecls(recorder);

    // Force semantic analysis of the compile-time selected facade and the
    // explicit unsupported runtime/product implementations together.
    std.testing.refAllDecls(platform);
    std.testing.refAllDecls(explicit_runtime);
    std.testing.refAllDecls(product);
    std.testing.refAllDecls(unsupported_product);
}

fn presentShortcut(
    _: std.mem.Allocator,
    _: std.Io,
    _: product_contracts.ShortcutApplyResult,
) !bool {
    return true;
}

test "portable daemon orchestration and contracts compile for the readiness target" {
    const run: *const fn (
        std.mem.Allocator,
        std.Io,
        *config.Config,
        @import("paths.zig").Runtime,
        []const u8,
    ) anyerror!void = &daemon.run;
    std.mem.doNotOptimizeAway(run);

    const state: protocol.State = .idle;
    const request: product_contracts.ShortcutRequest = .show;
    const result: product_contracts.ShortcutApplyResult = .{ .unsupported = "readiness-only" };
    std.mem.doNotOptimizeAway(&state);
    std.mem.doNotOptimizeAway(&request);
    std.mem.doNotOptimizeAway(&result);
}

test "selected runtime and product operations remain explicitly unsupported" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var runtime_recorder: explicit_runtime.Recorder = .{};
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime_recorder.start(std.testing.allocator, std.testing.io, "/tmp", ""),
    );
    try std.testing.expectError(error.UnsupportedPlatform, runtime_recorder.stop(std.testing.io));
    try std.testing.expectError(
        error.UnsupportedPlatform,
        runtime_recorder.cancel(std.testing.allocator, std.testing.io),
    );
    try std.testing.expectError(error.UnsupportedPlatform, explicit_runtime.typeText(std.testing.io, "text"));
    try std.testing.expectError(error.UnsupportedPlatform, explicit_runtime.runtimeRoot(&env));

    try std.testing.expectEqual(platform.Implementation.unsupported, platform.capabilities.runtime_integration);
    try std.testing.expectError(error.UnsupportedPlatform, platform.copyToClipboard(std.testing.io, "text"));
    try std.testing.expectError(error.UnsupportedPlatform, platform.metricsFile(std.testing.allocator, &env));

    try std.testing.expectError(error.UnsupportedPlatform, unsupported_product.restart(std.testing.io));
    try std.testing.expectError(
        error.UnsupportedPlatform,
        unsupported_product.setup(std.testing.allocator, std.testing.io, &env, presentShortcut),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        unsupported_product.shortcut(std.testing.allocator, std.testing.io, &env, .show),
    );
    try std.testing.expectError(
        error.UnsupportedPlatform,
        unsupported_product.diagnostics(std.testing.allocator, std.testing.io, null),
    );
}
