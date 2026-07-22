const std = @import("std");
const builtin = @import("builtin");

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

pub const RuntimeRoot = struct {
    path: []const u8,
    parent_security: ParentSecurity,
};

pub const ParentSecurity = enum {
    private,
    shared_sticky_tmp,
};

const implementation = switch (builtin.os.tag) {
    .linux => Linux,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => Darwin,
    .windows => Windows,
    else => Unsupported,
};

pub fn configFile(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    return implementation.configFile(gpa, env);
}

pub fn keywordsFile(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    return implementation.keywordsFile(gpa, env);
}

pub fn metricsFile(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    return implementation.metricsFile(gpa, env);
}

pub fn runtimeRoot(env: *const std.process.Environ.Map) !RuntimeRoot {
    return implementation.runtimeRoot(env);
}

pub fn effectiveUserId() !u32 {
    return implementation.effectiveUserId();
}

pub fn validatePrivateParent(io: std.Io, path: []const u8) !void {
    return implementation.validatePrivateParent(io, path);
}

pub fn validateSharedTmpParent(io: std.Io, path: []const u8) !void {
    return implementation.validateSharedTmpParent(io, path);
}

pub fn validatePrivateSocket(io: std.Io, path: []const u8) !void {
    return implementation.validatePrivateSocket(io, path);
}

pub fn validateSocketKind(io: std.Io, path: []const u8) !void {
    return implementation.validateSocketKind(io, path);
}

pub fn makeSocketPrivate(path: []const u8) !void {
    return implementation.makeSocketPrivate(path);
}

const Linux = struct {
    fn configFile(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
        if (env.get("XDG_CONFIG_HOME")) |dir| {
            return try std.fmt.allocPrint(gpa, "{s}/sayall/config.json", .{dir});
        }
        if (env.get("HOME")) |home| {
            return try std.fmt.allocPrint(gpa, "{s}/.config/sayall/config.json", .{home});
        }
        return null;
    }

    fn keywordsFile(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
        if (env.get("XDG_CONFIG_HOME")) |dir| {
            if (dir.len == 0 or dir[0] != '/') return error.InvalidConfigHome;
            return try std.fmt.allocPrint(gpa, "{s}/sayall/keywords.json", .{dir});
        }
        if (env.get("HOME")) |home| {
            if (home.len == 0 or home[0] != '/') return error.InvalidConfigHome;
            return try std.fmt.allocPrint(gpa, "{s}/.config/sayall/keywords.json", .{home});
        }
        return null;
    }

    fn metricsFile(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
        if (env.get("XDG_STATE_HOME")) |dir| {
            if (dir.len == 0 or dir[0] != '/') return error.InvalidStateHome;
            return std.fmt.allocPrint(gpa, "{s}/sayall/metrics-v2.json", .{dir});
        }
        if (env.get("HOME")) |home| {
            if (home.len == 0 or home[0] != '/') return error.InvalidStateHome;
            return std.fmt.allocPrint(gpa, "{s}/.local/state/sayall/metrics-v2.json", .{home});
        }
        return error.StateHomeUnavailable;
    }

    fn runtimeRoot(env: *const std.process.Environ.Map) !RuntimeRoot {
        if (env.get("XDG_RUNTIME_DIR")) |dir| {
            try validateAbsoluteRoot(dir, error.InvalidRuntimeDir);
            return .{ .path = dir, .parent_security = .private };
        }
        return .{ .path = "/tmp", .parent_security = .shared_sticky_tmp };
    }

    fn effectiveUserId() !u32 {
        return @intCast(std.os.linux.geteuid());
    }

    fn validatePrivateParent(io: std.Io, path: []const u8) !void {
        const value = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (value.kind != .directory) return error.EndpointParentNotDirectory;
        if (value.permissions.toMode() & 0o077 != 0) return error.EndpointParentNotPrivate;
    }

    fn validateSharedTmpParent(io: std.Io, path: []const u8) !void {
        if (!std.mem.eql(u8, path, "/tmp")) return error.InvalidSharedRuntimeDir;
        const value = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        const mode = value.permissions.toMode();
        if (value.kind != .directory) return error.EndpointParentNotDirectory;
        if (mode & 0o1000 == 0 or mode & 0o002 == 0)
            return error.SharedRuntimeDirNotSticky;
    }

    fn validatePrivateSocket(io: std.Io, path: []const u8) !void {
        const value = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (value.kind != .unix_domain_socket) return error.EndpointNotSocket;
        if (value.permissions.toMode() & 0o077 != 0) return error.EndpointNotPrivate;
    }

    fn validateSocketKind(io: std.Io, path: []const u8) !void {
        const value = try std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
        if (value.kind != .unix_domain_socket) return error.EndpointNotSocket;
    }

    fn makeSocketPrivate(path: []const u8) !void {
        var path_buffer: [std.Io.net.UnixAddress.max_len + 1]u8 = undefined;
        const path_z = try nullTerminate(path, &path_buffer);
        if (std.c.chmod(path_z.ptr, 0o600) != 0) return error.EndpointPermissionDenied;
    }

    fn nullTerminate(path: []const u8, buffer: []u8) ![:0]const u8 {
        if (path.len >= buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        return buffer[0..path.len :0];
    }
};

fn validateAbsoluteRoot(path: []const u8, invalid: anyerror) !void {
    if (!std.fs.path.isAbsolute(path) or path.len <= 1 or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null or hasUnsafeSegment(path))
        return invalid;
    for (path) |byte| if (std.ascii.isControl(byte)) return invalid;
}

fn hasUnsafeSegment(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (first) {
            first = false;
            continue;
        }
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return true;
    }
    return false;
}

const Darwin = unsupportedPaths("darwin");
const Windows = unsupportedPaths("windows");
const Unsupported = unsupportedPaths("unsupported");

fn unsupportedPaths(comptime name: []const u8) type {
    _ = name;
    return struct {
        fn configFile(_: Allocator, _: *const std.process.Environ.Map) !?[]u8 {
            return error.UnsupportedPlatform;
        }
        fn keywordsFile(_: Allocator, _: *const std.process.Environ.Map) !?[]u8 {
            return error.UnsupportedPlatform;
        }
        fn metricsFile(_: Allocator, _: *const std.process.Environ.Map) ![]u8 {
            return error.UnsupportedPlatform;
        }
        fn runtimeRoot(_: *const std.process.Environ.Map) !RuntimeRoot {
            return error.UnsupportedPlatform;
        }
        fn effectiveUserId() !u32 {
            return error.UnsupportedPlatform;
        }
        fn validatePrivateParent(_: std.Io, _: []const u8) !void {
            return error.UnsupportedPlatform;
        }
        fn validateSharedTmpParent(_: std.Io, _: []const u8) !void {
            return error.UnsupportedPlatform;
        }
        fn validatePrivateSocket(_: std.Io, _: []const u8) !void {
            return error.UnsupportedPlatform;
        }
        fn validateSocketKind(_: std.Io, _: []const u8) !void {
            return error.UnsupportedPlatform;
        }
        fn makeSocketPrivate(_: []const u8) !void {
            return error.UnsupportedPlatform;
        }
    };
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
