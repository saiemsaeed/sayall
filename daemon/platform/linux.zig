const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Recorder = struct {
    child: ?std.process.Child = null,
    path: ?[]u8 = null,

    /// Spawns pw-record writing 16 kHz mono s16 raw PCM to `dir_path`.
    /// `source` may be empty (default source), or a PipeWire node name/serial.
    pub fn start(self: *Recorder, gpa: Allocator, io: Io, dir_path: []const u8, source: []const u8) ![]const u8 {
        std.debug.assert(self.child == null);
        var nonce: u64 = undefined;
        try std.Io.randomSecure(io, std.mem.asBytes(&nonce));
        const path = try std.fmt.allocPrint(gpa, "{s}/sayall-rec-{d}-{x}.pcm", .{
            dir_path, std.os.linux.getpid(), nonce,
        });
        errdefer gpa.free(path);

        var argv_buf: [11][]const u8 = undefined;
        var argv_len: usize = 0;
        const base_args = [_][]const u8{
            "pw-record",
            "--raw",
            "--format",
            "s16",
            "--rate",
            "16000",
            "--channels",
            "1",
        };
        for (base_args) |arg| {
            argv_buf[argv_len] = arg;
            argv_len += 1;
        }
        if (source.len > 0) {
            argv_buf[argv_len] = "--target";
            argv_buf[argv_len + 1] = source;
            argv_len += 2;
        }
        argv_buf[argv_len] = path;
        argv_len += 1;

        const argv = try gpa.dupe([]const u8, argv_buf[0..argv_len]);
        defer gpa.free(argv);

        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        self.child = child;
        self.path = path;
        return path;
    }

    /// Sends SIGINT, waits for pw-record to exit, and returns the recording.
    pub fn stop(self: *Recorder, io: Io) !types.Recording {
        const child = if (self.child) |*child| child else return error.NotRecording;
        const path = self.path orelse return error.NotRecording;

        if (child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.INT) catch {};
        }
        _ = child.wait(io) catch {
            child.kill(io);
        };

        self.child = null;
        self.path = null;
        return .{ .path = path };
    }

    /// Aborts an in-progress recording and deletes its scratch file.
    pub fn cancel(self: *Recorder, gpa: Allocator, io: Io) !void {
        const recording = self.stop(io) catch return;
        Io.Dir.deleteFileAbsolute(io, recording.path) catch {};
        gpa.free(recording.path);
    }
};

pub fn typeText(io: Io, text: []const u8) !void {
    try run(io, &.{ "wtype", "--", text }, error.TypeFailed);
}

pub fn copyToClipboard(io: Io, text: []const u8) !void {
    try feedStdin(io, &.{"wl-copy"}, text, error.ClipboardFailed);
}

/// Linux notifications remain best-effort so notification availability never
/// changes the speech pipeline result.
pub fn sendNotification(io: Io, title: []const u8, body: []const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "notify-send", "--app-name=SayAll", title, body },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn run(io: Io, argv: []const []const u8, fail: anyerror) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return fail;
    const term = child.wait(io) catch return fail;
    switch (term) {
        .exited => |code| if (code != 0) return fail,
        else => return fail,
    }
}

fn feedStdin(io: Io, argv: []const []const u8, text: []const u8, fail: anyerror) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return fail;

    const stdin = child.stdin orelse {
        _ = child.wait(io) catch {};
        return fail;
    };

    var write_buffer: [4096]u8 = undefined;
    var writer = stdin.writer(io, &write_buffer);
    writer.interface.writeAll(text) catch {
        stdin.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        return fail;
    };
    writer.interface.flush() catch {};
    stdin.close(io);
    child.stdin = null;

    const term = child.wait(io) catch return fail;
    switch (term) {
        .exited => |code| if (code != 0) return fail,
        else => return fail,
    }
}

pub fn configFile(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| {
        return try std.fmt.allocPrint(gpa, "{s}/sayall/config.json", .{dir});
    }
    if (env.get("HOME")) |home| {
        return try std.fmt.allocPrint(gpa, "{s}/.config/sayall/config.json", .{home});
    }
    return null;
}

pub fn keywordsFile(gpa: Allocator, env: *const std.process.Environ.Map) !?[]u8 {
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

pub fn metricsFile(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
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

pub fn runtimeRoot(env: *const std.process.Environ.Map) !types.RuntimeRoot {
    if (env.get("XDG_RUNTIME_DIR")) |dir| {
        try validateAbsoluteRoot(dir, error.InvalidRuntimeDir);
        return .{ .path = dir, .parent_security = .private };
    }
    return .{ .path = "/tmp", .parent_security = .shared_sticky_tmp };
}

pub fn effectiveUserId() !u32 {
    return @intCast(std.os.linux.geteuid());
}

pub fn validatePrivateParent(io: Io, path: []const u8) !void {
    const value = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (value.kind != .directory) return error.EndpointParentNotDirectory;
    if (value.permissions.toMode() & 0o077 != 0) return error.EndpointParentNotPrivate;
}

pub fn validateSharedTmpParent(io: Io, path: []const u8) !void {
    if (!std.mem.eql(u8, path, "/tmp")) return error.InvalidSharedRuntimeDir;
    const value = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    const mode = value.permissions.toMode();
    if (value.kind != .directory) return error.EndpointParentNotDirectory;
    if (mode & 0o1000 == 0 or mode & 0o002 == 0) return error.SharedRuntimeDirNotSticky;
}

pub fn validatePrivateSocket(io: Io, path: []const u8) !void {
    const value = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (value.kind != .unix_domain_socket) return error.EndpointNotSocket;
    if (value.permissions.toMode() & 0o077 != 0) return error.EndpointNotPrivate;
}

pub fn validateSocketKind(io: Io, path: []const u8) !void {
    const value = try Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
    if (value.kind != .unix_domain_socket) return error.EndpointNotSocket;
}

pub fn makeSocketPrivate(path: []const u8) !void {
    var path_buffer: [Io.net.UnixAddress.max_len + 1]u8 = undefined;
    const path_z = try nullTerminate(path, &path_buffer);
    if (std.c.chmod(path_z.ptr, 0o600) != 0) return error.EndpointPermissionDenied;
}

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

fn nullTerminate(path: []const u8, buffer: []u8) ![:0]const u8 {
    if (path.len >= buffer.len) return error.NameTooLong;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}
