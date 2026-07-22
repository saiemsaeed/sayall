const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const max_count: usize = 100;
pub const max_keyword_bytes: usize = 256;
pub const max_total_bytes: usize = 4096;

pub const ValidationError = error{
    EmptyKeyword,
    KeywordTooLong,
    InvalidUtf8,
    ControlCharacter,
    DuplicateKeyword,
    TooManyKeywords,
    KeywordsTooLarge,
};

const FileContents = struct {
    version: u16 = 1,
    keywords: []const []const u8 = &.{},
};

pub const Store = struct {
    path: []const u8,

    pub fn init(path_value: []const u8) Store {
        return .{ .path = path_value };
    }

    pub fn load(self: Store, gpa: Allocator, io: Io) !?[]const []const u8 {
        return self.loadFile(gpa, io);
    }

    /// Loads the authoritative keyword file. If it does not exist, validated
    /// legacy stt.keyterms are atomically imported before being returned.
    pub fn loadOrMigrate(self: Store, gpa: Allocator, io: Io, legacy: []const []const u8) ![]const []const u8 {
        if (try self.loadFile(gpa, io)) |stored| return stored;
        const normalized = try normalizeLegacy(gpa, legacy);
        if (normalized.len == 0) return normalized;

        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);

        // Another process may have completed the migration while we waited.
        if (try self.loadFile(gpa, io)) |stored| return stored;
        try self.atomicWrite(gpa, io, normalized);
        return normalized;
    }

    pub fn add(self: Store, gpa: Allocator, io: Io, legacy: []const []const u8, additions: []const []const u8) ![]const []const u8 {
        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);

        const current = try self.loadFile(gpa, io) orelse legacy;
        const updated = try gpa.alloc([]const u8, current.len + additions.len);
        @memcpy(updated[0..current.len], current);
        @memcpy(updated[current.len..], additions);
        try validate(updated);
        try self.atomicWrite(gpa, io, updated);
        return updated;
    }

    pub fn rename(self: Store, gpa: Allocator, io: Io, legacy: []const []const u8, old: []const u8, replacement: []const u8) ![]const []const u8 {
        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);

        const current = try self.loadFile(gpa, io) orelse legacy;
        const index = exactIndex(current, old) orelse return error.KeywordNotFound;
        if (std.mem.eql(u8, old, replacement)) return error.DuplicateKeyword;
        const updated = try gpa.dupe([]const u8, current);
        updated[index] = replacement;
        try validate(updated);
        try self.atomicWrite(gpa, io, updated);
        return updated;
    }

    pub fn delete(self: Store, gpa: Allocator, io: Io, legacy: []const []const u8, keyword: []const u8) ![]const []const u8 {
        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);

        const current = try self.loadFile(gpa, io) orelse legacy;
        const index = exactIndex(current, keyword) orelse return error.KeywordNotFound;
        const updated = try gpa.alloc([]const u8, current.len - 1);
        @memcpy(updated[0..index], current[0..index]);
        @memcpy(updated[index..], current[index + 1 ..]);
        try validate(updated);
        try self.atomicWrite(gpa, io, updated);
        return updated;
    }

    pub fn clear(self: Store, gpa: Allocator, io: Io) !void {
        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);
        try self.atomicWrite(gpa, io, &.{});
    }

    fn ensureDirectory(self: Store, io: Io) !void {
        const parent = std.fs.path.dirname(self.path) orelse return error.InvalidKeywordPath;
        const dir = try Io.Dir.cwd().createDirPathOpen(io, parent, .{
            .open_options = .{ .iterate = true },
            .permissions = @enumFromInt(0o700),
        });
        defer dir.close(io);
        try dir.setPermissions(io, @enumFromInt(0o700));
    }

    fn lock(self: Store, io: Io) !Io.File {
        const lock_path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}.lock", .{self.path});
        defer std.heap.smp_allocator.free(lock_path);
        const file = try Io.Dir.createFileAbsolute(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
        errdefer file.close(io);
        try file.setPermissions(io, @enumFromInt(0o600));
        return file;
    }

    fn loadFile(self: Store, gpa: Allocator, io: Io) !?[]const []const u8 {
        const bytes = Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        const contents = try std.json.parseFromSliceLeaky(FileContents, gpa, bytes, .{
            .allocate = .alloc_always,
        });
        if (contents.version != 1) return error.UnsupportedKeywordFileVersion;
        try validate(contents.keywords);
        return contents.keywords;
    }

    fn atomicWrite(self: Store, gpa: Allocator, io: Io, values: []const []const u8) !void {
        try validate(values);
        const json = try std.json.Stringify.valueAlloc(gpa, FileContents{ .keywords = values }, .{ .whitespace = .indent_2 });
        defer gpa.free(json);

        var nonce: u64 = undefined;
        try std.Io.randomSecure(io, std.mem.asBytes(&nonce));
        const temp_path = try std.fmt.allocPrint(gpa, "{s}.tmp-{x}", .{ self.path, nonce });
        defer gpa.free(temp_path);
        errdefer Io.Dir.deleteFileAbsolute(io, temp_path) catch {};

        const file = try Io.Dir.createFileAbsolute(io, temp_path, .{ .permissions = @enumFromInt(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, json);
        try file.sync(io);
        try Io.Dir.rename(.cwd(), temp_path, .cwd(), self.path, io);
    }
};

pub fn validate(values: []const []const u8) ValidationError!void {
    if (values.len > max_count) return error.TooManyKeywords;

    var total: usize = 0;
    for (values, 0..) |value, index| {
        if (value.len == 0) return error.EmptyKeyword;
        if (value.len > max_keyword_bytes) return error.KeywordTooLong;
        var view = std.unicode.Utf8View.init(value) catch return error.InvalidUtf8;
        var iterator = view.iterator();
        while (iterator.nextCodepoint()) |codepoint| {
            if (codepoint <= 0x1f or (codepoint >= 0x7f and codepoint <= 0x9f))
                return error.ControlCharacter;
        }
        total += value.len;
        if (total > max_total_bytes) return error.KeywordsTooLarge;
        for (values[0..index]) |previous| {
            if (std.mem.eql(u8, previous, value)) return error.DuplicateKeyword;
        }
    }
}

/// Legacy stt.keyterms allowed exact repeats. Preserve the first occurrence
/// of each byte-exact value so upgrading cannot turn a previously valid config
/// into a startup failure or repeat provider parameters.
pub fn normalizeLegacy(gpa: Allocator, values: []const []const u8) ![]const []const u8 {
    var normalized: std.ArrayList([]const u8) = .empty;
    defer normalized.deinit(gpa);
    for (values) |value| {
        if (exactIndex(normalized.items, value) != null) continue;
        try normalized.append(gpa, value);
    }
    try validate(normalized.items);
    return normalized.toOwnedSlice(gpa);
}

fn exactIndex(values: []const []const u8, wanted: []const u8) ?usize {
    for (values, 0..) |value, index| {
        if (std.mem.eql(u8, value, wanted)) return index;
    }
    return null;
}

test "validation preserves exact Unicode and rejects invalid values" {
    try validate(&.{ " SayAll ", "München", "模型上下文协议" });
    try std.testing.expectError(error.EmptyKeyword, validate(&.{""}));
    try std.testing.expectError(error.ControlCharacter, validate(&.{"line\nbreak"}));
    try std.testing.expectError(error.ControlCharacter, validate(&.{"C1\xc2\x85control"}));
    try std.testing.expectError(error.InvalidUtf8, validate(&.{"bad\xff"}));
    try std.testing.expectError(error.DuplicateKeyword, validate(&.{ "Same", "Same" }));
    try validate(&.{ "Same", "same", " Same" });

    var too_long: [max_keyword_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.KeywordTooLong, validate(&.{&too_long}));

    var too_many: [max_count + 1][]const u8 = @splat("duplicate does not matter");
    try std.testing.expectError(error.TooManyKeywords, validate(&too_many));

    var large_storage: [17][max_keyword_bytes]u8 = undefined;
    var large_values: [17][]const u8 = undefined;
    for (&large_storage, 0..) |*value, index| {
        @memset(value, 'a');
        value[0] = @intCast('a' + index);
        large_values[index] = value;
    }
    try std.testing.expectError(error.KeywordsTooLarge, validate(&large_values));
}

test "legacy normalization keeps first occurrence order and spelling" {
    const normalized = try normalizeLegacy(std.testing.allocator, &.{
        "SayAll",
        "München",
        "SayAll",
        "sayall",
        "München",
        " spaced ",
    });
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqual(@as(usize, 4), normalized.len);
    try std.testing.expectEqualStrings("SayAll", normalized[0]);
    try std.testing.expectEqualStrings("München", normalized[1]);
    try std.testing.expectEqualStrings("sayall", normalized[2]);
    try std.testing.expectEqualStrings(" spaced ", normalized[3]);
}

test "store migrates legacy values and CRUD preserves bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/config/sayall/keywords.json", .{tmp.sub_path});
    defer std.testing.allocator.free(store_path);
    const store = Store.init(store_path);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const migrated = try store.loadOrMigrate(arena, std.testing.io, &.{ "SayAll", " spaced phrase ", "SayAll", "München", " spaced phrase " });
    try std.testing.expectEqual(@as(usize, 3), migrated.len);
    try std.testing.expectEqualStrings(" spaced phrase ", migrated[1]);
    try std.testing.expectEqualStrings("München", migrated[2]);

    const added = try store.add(arena, std.testing.io, &.{}, &.{"模型上下文协议"});
    try std.testing.expectEqual(@as(usize, 4), added.len);
    try std.testing.expectError(error.DuplicateKeyword, store.add(arena, std.testing.io, &.{}, &.{"SayAll"}));

    const renamed = try store.rename(arena, std.testing.io, &.{}, "SayAll", "sayALL");
    try std.testing.expectEqualStrings("sayALL", renamed[0]);
    try std.testing.expectError(error.DuplicateKeyword, store.rename(arena, std.testing.io, &.{}, "sayALL", "München"));
    try std.testing.expectError(error.KeywordNotFound, store.rename(arena, std.testing.io, &.{}, "missing", "new"));

    const remaining = try store.delete(arena, std.testing.io, &.{}, " spaced phrase ");
    try std.testing.expectEqual(@as(usize, 3), remaining.len);
    try std.testing.expectError(error.KeywordNotFound, store.delete(arena, std.testing.io, &.{}, "spaced phrase"));

    const stat = try Io.Dir.cwd().statFile(std.testing.io, store_path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), stat.permissions.toMode() & 0o777);
    const parent = std.fs.path.dirname(store_path).?;
    const parent_stat = try Io.Dir.cwd().statFile(std.testing.io, parent, .{});
    try std.testing.expectEqual(@as(u32, 0o700), parent_stat.permissions.toMode() & 0o777);

    try store.clear(arena, std.testing.io);
    const cleared = try store.loadOrMigrate(arena, std.testing.io, &.{"legacy must not return"});
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
}

test "store file overrides legacy values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/sayall/keywords.json", .{tmp.sub_path});
    defer std.testing.allocator.free(store_path);
    const store = Store.init(store_path);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = try store.add(arena, std.testing.io, &.{}, &.{"authoritative"});
    const loaded = try store.loadOrMigrate(arena, std.testing.io, &.{ "invalid legacy", "invalid legacy" });
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("authoritative", loaded[0]);
}
