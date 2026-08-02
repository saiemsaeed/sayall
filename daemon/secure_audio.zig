const std = @import("std");
const builtin = @import("builtin");

pub const Opened = struct {
    file: std.Io.File,
    stat: std.Io.File.Stat,
    identity: Identity,
};

pub const Identity = struct { device: u64, inode: u64 };
pub const SizePolicy = enum { nonempty, growing };

/// Opens an app-owned session audio file without following its final symlink.
/// Only the immediate session directory is part of this private contract. An
/// ancestor symlink is currently permitted; importantly, the file itself is
/// opened relative to the descriptor of the parent that was validated.
pub fn open(io: std.Io, path: []const u8, max_size: u64, size_policy: SizePolicy) !Opened {
    if (!std.fs.path.isAbsolute(path)) return error.InvalidPath;
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const basename = std.fs.path.basename(path);
    if (basename.len == 0 or std.mem.eql(u8, basename, ".") or std.mem.eql(u8, basename, "..")) return error.InvalidPath;
    var parent = try std.Io.Dir.cwd().openDir(io, parent_path, .{ .follow_symlinks = false });
    defer parent.close(io);
    const parent_stat = try parent.stat(io);
    if (parent_stat.kind != .directory) return error.InvalidPath;
    _ = try validateOwnership(parent_stat, parent.handle);
    var file = try parent.openFile(io, basename, .{ .allow_directory = false, .follow_symlinks = false });
    errdefer file.close(io);
    const stat = try file.stat(io);
    const identity = try validateOwnership(stat, file.handle);
    if (stat.kind != .file or stat.size > max_size or (size_policy == .nonempty and stat.size == 0)) return error.InvalidAudio;
    return .{ .file = file, .stat = stat, .identity = identity };
}

fn validateOwnership(stat: std.Io.File.Stat, handle: std.Io.File.Handle) !Identity {
    const mode = stat.permissions.toMode();
    if (mode & 0o077 != 0) return error.InsecurePermissions;
    if (builtin.os.tag == .linux) {
        var raw: std.os.linux.Statx = undefined;
        const requested: std.os.linux.STATX = .{ .UID = true, .INO = true };
        if (std.os.linux.errno(std.os.linux.statx(handle, "", std.os.linux.AT.EMPTY_PATH, requested, &raw)) != .SUCCESS)
            return error.StatFailed;
        if (raw.uid != std.os.linux.geteuid()) return error.WrongOwner;
        return .{ .device = (@as(u64, raw.dev_major) << 32) | raw.dev_minor, .inode = raw.ino };
    }
    if (builtin.os.tag == .macos) {
        var raw: std.c.Stat = undefined;
        if (std.c.fstat(handle, &raw) != 0) return error.StatFailed;
        if (raw.uid != std.c.geteuid()) return error.WrongOwner;
        return .{ .device = @intCast(raw.dev), .inode = @intCast(raw.ino) };
    }
    return error.UnsupportedPlatform;
}

pub fn sameFile(a: Identity, b: Identity) bool {
    return a.device == b.device and a.inode == b.inode;
}

test "secure growing audio accepts empty file and preserves descriptor identity" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "audio.pcm", .data = "" });
    var created = try tmp.dir.openFile(std.testing.io, "audio.pcm", .{});
    try created.setPermissions(std.testing.io, .fromMode(0o600));
    created.close(std.testing.io);
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/audio.pcm", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(path);

    var opened = try open(std.testing.io, path, 1, .growing);
    defer opened.file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, 0), opened.stat.size);
    try std.testing.expectError(error.InvalidAudio, open(std.testing.io, path, 1, .nonempty));

    const again = try open(std.testing.io, path, 1, .growing);
    defer again.file.close(std.testing.io);
    try std.testing.expect(sameFile(opened.identity, again.identity));
}

test "secure audio rejects oversize and insecure final file mode" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "audio.pcm", .data = "12" });
    var created = try tmp.dir.openFile(std.testing.io, "audio.pcm", .{});
    try created.setPermissions(std.testing.io, .fromMode(0o600));
    created.close(std.testing.io);
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/audio.pcm", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.InvalidAudio, open(std.testing.io, path, 1, .growing));
    var insecure = try tmp.dir.openFile(std.testing.io, "audio.pcm", .{});
    try insecure.setPermissions(std.testing.io, .fromMode(0o644));
    insecure.close(std.testing.io);
    try std.testing.expectError(error.InsecurePermissions, open(std.testing.io, path, 3, .growing));
}
