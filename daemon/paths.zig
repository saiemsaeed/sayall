const std = @import("std");
const platform = @import("platform.zig");

const Allocator = std.mem.Allocator;

pub const Config = struct {
    pub fn file(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
        return platform.configFile(gpa, env);
    }

    pub fn keywords(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
        return platform.keywordsFile(gpa, env);
    }
};

pub const PersistentState = struct {
    pub fn metrics(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
        return platform.metricsFile(gpa, env);
    }
};

pub const Endpoint = struct {
    path: []const u8,
    parent: []const u8,
    parent_security: platform.ParentSecurity,

    pub fn validateParent(self: Endpoint, io: std.Io) !void {
        return switch (self.parent_security) {
            .private => platform.validatePrivateParent(io, self.parent),
            .shared_sticky_tmp => platform.validateSharedTmpParent(io, self.parent),
        };
    }

    pub fn validateSocket(self: Endpoint, io: std.Io) !void {
        try validateSocketPath(self.path);
        try platform.validatePrivateSocket(io, self.path);
    }

    pub fn validateStaleSocket(self: Endpoint, io: std.Io) !void {
        try validateSocketPath(self.path);
        try platform.validateSocketKind(io, self.path);
    }
};

pub const Runtime = struct {
    endpoint: Endpoint,
    /// Scratch ownership is intentionally independent of SAYALL_SOCKET.
    scratch_dir: []const u8,

    pub fn discover(gpa: Allocator, env: *const std.process.Environ.Map) !Runtime {
        const root = try platform.runtimeRoot(env);
        const scratch_dir = try gpa.dupe(u8, root.path);
        errdefer gpa.free(scratch_dir);

        if (env.get("SAYALL_SOCKET")) |override| {
            try validateSocketPath(override);
            const endpoint_path = try gpa.dupe(u8, override);
            errdefer gpa.free(endpoint_path);
            const parent = std.fs.path.dirname(endpoint_path) orelse return error.UnsafeEndpointPath;
            return .{
                .endpoint = .{
                    .path = endpoint_path,
                    .parent = parent,
                    .parent_security = .private,
                },
                .scratch_dir = scratch_dir,
            };
        }

        const endpoint_path = switch (root.parent_security) {
            .private => try std.fmt.allocPrint(gpa, "{s}/sayall.sock", .{root.path}),
            .shared_sticky_tmp => try std.fmt.allocPrint(gpa, "{s}/sayall-{d}.sock", .{
                root.path,
                try platform.effectiveUserId(),
            }),
        };
        errdefer gpa.free(endpoint_path);
        try validateSocketPath(endpoint_path);
        return .{
            .endpoint = .{
                .path = endpoint_path,
                .parent = root.path,
                .parent_security = root.parent_security,
            },
            .scratch_dir = scratch_dir,
        };
    }
};

pub fn validateSocketPath(path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return error.EndpointPathNotAbsolute;
    // Filesystem Unix addresses require a trailing NUL in sun_path.
    if (path.len == 0 or path.len >= std.Io.net.UnixAddress.max_len) return error.EndpointPathTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null or path[path.len - 1] == '/')
        return error.UnsafeEndpointPath;
    for (path) |byte| if (std.ascii.isControl(byte)) return error.UnsafeEndpointPath;
    const parent = std.fs.path.dirname(path) orelse return error.UnsafeEndpointPath;
    if (std.mem.eql(u8, parent, "/")) return error.UnsafeEndpointPath;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, ".."))
        return error.UnsafeEndpointPath;

    var segments = std.mem.splitScalar(u8, path, '/');
    var first = true;
    while (segments.next()) |segment| {
        if (first) {
            first = false;
            continue;
        }
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return error.UnsafeEndpointPath;
    }
}

test "Linux path classes preserve XDG and HOME locations" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/tmp/home");

    const config_home = (try Config.file(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(config_home);
    try std.testing.expectEqualStrings("/tmp/home/.config/sayall/config.json", config_home);
    const keywords_home = (try Config.keywords(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(keywords_home);
    try std.testing.expectEqualStrings("/tmp/home/.config/sayall/keywords.json", keywords_home);
    const metrics_home = try PersistentState.metrics(std.testing.allocator, &env);
    defer std.testing.allocator.free(metrics_home);
    try std.testing.expectEqualStrings("/tmp/home/.local/state/sayall/metrics-v2.json", metrics_home);

    try env.put("XDG_CONFIG_HOME", "/tmp/xdg-config");
    try env.put("XDG_STATE_HOME", "/tmp/xdg-state");
    const config_xdg = (try Config.file(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(config_xdg);
    try std.testing.expectEqualStrings("/tmp/xdg-config/sayall/config.json", config_xdg);
    const keywords_xdg = (try Config.keywords(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(keywords_xdg);
    try std.testing.expectEqualStrings("/tmp/xdg-config/sayall/keywords.json", keywords_xdg);
    const metrics_xdg = try PersistentState.metrics(std.testing.allocator, &env);
    defer std.testing.allocator.free(metrics_xdg);
    try std.testing.expectEqualStrings("/tmp/xdg-state/sayall/metrics-v2.json", metrics_xdg);

    try env.put("XDG_CONFIG_HOME", "relative");
    const legacy_config_path = (try Config.file(std.testing.allocator, &env)).?;
    defer std.testing.allocator.free(legacy_config_path);
    try std.testing.expectEqualStrings("relative/sayall/config.json", legacy_config_path);
    try std.testing.expectError(error.InvalidConfigHome, Config.keywords(std.testing.allocator, &env));
    try env.put("XDG_STATE_HOME", "relative");
    try std.testing.expectError(error.InvalidStateHome, PersistentState.metrics(std.testing.allocator, &env));
}

test "runtime endpoint precedence and scratch ownership are independent" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", "/run/user/1000");

    const standard = try Runtime.discover(std.testing.allocator, &env);
    defer std.testing.allocator.free(standard.endpoint.path);
    defer std.testing.allocator.free(standard.scratch_dir);
    try std.testing.expectEqualStrings("/run/user/1000/sayall.sock", standard.endpoint.path);
    try std.testing.expectEqualStrings("/run/user/1000", standard.scratch_dir);

    try env.put("SAYALL_SOCKET", "/tmp/private-dev/sayall-test.sock");
    const overridden = try Runtime.discover(std.testing.allocator, &env);
    defer std.testing.allocator.free(overridden.endpoint.path);
    defer std.testing.allocator.free(overridden.scratch_dir);
    try std.testing.expectEqualStrings("/tmp/private-dev/sayall-test.sock", overridden.endpoint.path);
    try std.testing.expectEqualStrings("/run/user/1000", overridden.scratch_dir);
    try std.testing.expectEqual(platform.ParentSecurity.private, overridden.endpoint.parent_security);
}

test "runtime endpoint falls back to the euid-specific tmp socket" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const runtime = try Runtime.discover(std.testing.allocator, &env);
    defer std.testing.allocator.free(runtime.endpoint.path);
    defer std.testing.allocator.free(runtime.scratch_dir);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "/tmp/sayall-{d}.sock", .{try platform.effectiveUserId()});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, runtime.endpoint.path);
    try std.testing.expectEqualStrings("/tmp", runtime.scratch_dir);
}

test "socket override rejects relative unsafe and oversized paths" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try env.put("SAYALL_SOCKET", "relative.sock");
    try std.testing.expectError(error.EndpointPathNotAbsolute, Runtime.discover(std.testing.allocator, &env));
    try env.put("SAYALL_SOCKET", "/tmp/../unsafe.sock");
    try std.testing.expectError(error.UnsafeEndpointPath, Runtime.discover(std.testing.allocator, &env));
    try env.put("SAYALL_SOCKET", "/sayall.sock");
    try std.testing.expectError(error.UnsafeEndpointPath, Runtime.discover(std.testing.allocator, &env));
    try env.put("SAYALL_SOCKET", "/tmp/private/socket\n.sock");
    try std.testing.expectError(error.UnsafeEndpointPath, Runtime.discover(std.testing.allocator, &env));

    var oversized: [std.Io.net.UnixAddress.max_len + 1]u8 = @splat('a');
    oversized[0] = '/';
    try env.put("SAYALL_SOCKET", &oversized);
    try std.testing.expectError(error.EndpointPathTooLong, Runtime.discover(std.testing.allocator, &env));
}
