const std = @import("std");
const builtin = @import("builtin");
const types = @import("platform/types.zig");

const Allocator = std.mem.Allocator;

pub const Implementation = enum { implemented, unsupported };
pub const RuntimeDependency = enum {
    none,
    required_unverified,
    not_applicable,
};
pub const OsPermission = enum {
    none,
    required_unverified,
    not_applicable,
};

pub const Capability = struct {
    implementation: Implementation,
    runtime_dependency: RuntimeDependency,
    os_permission: OsPermission,

    pub fn isImplemented(self: Capability) bool {
        return self.implementation == .implemented;
    }
};

pub const Capabilities = struct {
    name: []const u8,
    runtime_integration: Implementation,
    live_levels: Capability,
    text_injection: Capability,
    clipboard_fallback: Capability,
    stats: Capability,
    streaming_stt: Capability,
};

const unsupported_capability: Capability = .{
    .implementation = .unsupported,
    .runtime_dependency = .not_applicable,
    .os_permission = .not_applicable,
};

pub fn descriptorFor(comptime os: std.Target.Os.Tag) Capabilities {
    return switch (os) {
        .linux => .{
            .name = "linux",
            .runtime_integration = .implemented,
            .live_levels = .{
                .implementation = .implemented,
                .runtime_dependency = .required_unverified,
                .os_permission = .required_unverified,
            },
            .text_injection = .{
                .implementation = .implemented,
                .runtime_dependency = .required_unverified,
                .os_permission = .none,
            },
            .clipboard_fallback = .{
                .implementation = .implemented,
                .runtime_dependency = .required_unverified,
                .os_permission = .none,
            },
            .stats = .{
                .implementation = .implemented,
                .runtime_dependency = .none,
                .os_permission = .none,
            },
            .streaming_stt = .{
                .implementation = .implemented,
                .runtime_dependency = .required_unverified,
                .os_permission = .none,
            },
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => unsupported("darwin"),
        .windows => unsupported("windows"),
        else => unsupported(@tagName(os)),
    };
}

fn unsupported(name: []const u8) Capabilities {
    return .{
        .name = name,
        .runtime_integration = .unsupported,
        .live_levels = unsupported_capability,
        .text_injection = unsupported_capability,
        .clipboard_fallback = unsupported_capability,
        .stats = unsupported_capability,
        .streaming_stt = unsupported_capability,
    };
}

pub const capabilities = descriptorFor(builtin.os.tag);
pub const RuntimeRoot = types.RuntimeRoot;
pub const ParentSecurity = types.ParentSecurity;
pub const Recording = types.Recording;

fn implementationFor(comptime os: std.Target.Os.Tag) type {
    return switch (os) {
        .linux => @import("platform/linux.zig"),
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => @import("platform/darwin.zig"),
        .windows => @import("platform/windows.zig"),
        else => @import("platform/unsupported.zig"),
    };
}

const implementation = implementationFor(builtin.os.tag);

/// The selected recorder is a concrete compile-time type; there is no runtime
/// dispatch, registry, or injected platform object.
pub const Recorder = implementation.Recorder;

pub fn typeText(io: std.Io, text: []const u8) anyerror!void {
    return implementation.typeText(io, text);
}

pub fn copyToClipboard(io: std.Io, text: []const u8) anyerror!void {
    return implementation.copyToClipboard(io, text);
}

pub fn sendNotification(io: std.Io, title: []const u8, body: []const u8) anyerror!void {
    return implementation.sendNotification(io, title, body);
}

pub fn configFile(gpa: Allocator, env: *const std.process.Environ.Map) anyerror!?[]u8 {
    return implementation.configFile(gpa, env);
}

pub fn keywordsFile(gpa: Allocator, env: *const std.process.Environ.Map) anyerror!?[]u8 {
    return implementation.keywordsFile(gpa, env);
}

pub fn metricsFile(gpa: Allocator, env: *const std.process.Environ.Map) anyerror![]u8 {
    return implementation.metricsFile(gpa, env);
}

pub fn runtimeRoot(env: *const std.process.Environ.Map) anyerror!RuntimeRoot {
    return implementation.runtimeRoot(env);
}

pub fn effectiveUserId() anyerror!u32 {
    return implementation.effectiveUserId();
}

pub fn validatePrivateParent(io: std.Io, path: []const u8) anyerror!void {
    return implementation.validatePrivateParent(io, path);
}

pub fn validateSharedTmpParent(io: std.Io, path: []const u8) anyerror!void {
    return implementation.validateSharedTmpParent(io, path);
}

pub fn validatePrivateSocket(io: std.Io, path: []const u8) anyerror!void {
    return implementation.validatePrivateSocket(io, path);
}

pub fn validateSocketKind(io: std.Io, path: []const u8) anyerror!void {
    return implementation.validateSocketKind(io, path);
}

pub fn makeSocketPrivate(path: []const u8) anyerror!void {
    return implementation.makeSocketPrivate(path);
}

test "capability descriptors keep implementation separate from readiness and permission" {
    const linux = descriptorFor(.linux);
    try std.testing.expect(linux.live_levels.isImplemented());
    try std.testing.expectEqual(RuntimeDependency.required_unverified, linux.live_levels.runtime_dependency);
    try std.testing.expectEqual(OsPermission.required_unverified, linux.live_levels.os_permission);
    try std.testing.expect(linux.stats.isImplemented());
    try std.testing.expectEqual(RuntimeDependency.none, linux.stats.runtime_dependency);
    try std.testing.expectEqual(OsPermission.none, linux.stats.os_permission);

    inline for (.{ descriptorFor(.macos), descriptorFor(.windows) }) |unsupported_descriptor| {
        try std.testing.expectEqual(Implementation.unsupported, unsupported_descriptor.runtime_integration);
        try std.testing.expect(!unsupported_descriptor.live_levels.isImplemented());
        try std.testing.expectEqual(RuntimeDependency.not_applicable, unsupported_descriptor.live_levels.runtime_dependency);
        try std.testing.expectEqual(OsPermission.not_applicable, unsupported_descriptor.live_levels.os_permission);
    }
}
