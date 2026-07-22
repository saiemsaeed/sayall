const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_shortcut = "CTRL+SLASH";
const state_version = 1;
const managed_begin = "# BEGIN SAYALL MANAGED SHORTCUT";
const managed_end = "# END SAYALL MANAGED SHORTCUT";

pub const State = struct {
    enabled: bool,
    shortcut: []const u8,
    persisted: bool,
    external: bool = false,
};

const StoredState = struct {
    version: u8 = state_version,
    enabled: bool = true,
    shortcut: []const u8 = default_shortcut,
};

pub const Activation = enum {
    reloaded,
    deferred,
};

pub const Conflict = struct {
    path: []const u8,
    line: usize,
    binding: []const u8,
    equivalent: bool,
};

pub const Unresolved = struct {
    path: []const u8,
    line: usize,
    expression: []const u8,
};

pub const Request = union(enum) {
    current,
    set: []const u8,
    reset,
    disable,
};

pub const RollbackFailure = enum {
    concurrent_modification,
    io_failure,
};

pub const ApplyResult = union(enum) {
    applied: struct {
        state: State,
        changed: bool,
        activation: Activation,
    },
    external: State,
    external_owned: State,
    conflict: Conflict,
    unresolved: Unresolved,
    unsupported: []const u8,
    unsafe_root: []const u8,
    concurrent_modification: []const u8,
    reload_failed: []const u8,
    rollback_failed: RollbackFailure,
};

const Paths = struct {
    state: []const u8,
    lock: []const u8,
    fragment: []const u8,
    hyprland: []const u8,
};

const Chord = struct {
    modifiers: []const u8,
    key: []const u8,
    display: []const u8,
};

pub fn loadState(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !State {
    const paths = try resolvePaths(gpa, env);
    var state = try loadStateAt(gpa, io, paths.state);
    if (!state.persisted) {
        _ = Io.Dir.cwd().statFile(io, paths.hyprland, .{}) catch |err| switch (err) {
            error.FileNotFound => return state,
            else => return err,
        };
        const chord = try parseChord(gpa, state.shortcut);
        switch (try findConflict(gpa, io, env, paths.hyprland, paths.fragment, chord)) {
            .unresolved => return error.UnresolvedHyprlandExpression,
            .conflict => |conflict| if (conflict) |found| {
                state.external = found.equivalent;
            },
        }
    }
    return state;
}

pub fn apply(
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    request: Request,
) !ApplyResult {
    const paths = try resolvePaths(gpa, env);
    const preflight_stat = Io.Dir.cwd().statFile(io, paths.hyprland, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .unsupported = paths.hyprland },
        else => return err,
    };
    if (preflight_stat.kind != .file) return .{ .unsafe_root = paths.hyprland };

    const lock = try acquireLock(io, paths.lock);
    defer lock.close(io);

    const current = try loadStateAt(gpa, io, paths.state);
    const root_stat = Io.Dir.cwd().statFile(io, paths.hyprland, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .unsupported = paths.hyprland },
        else => return err,
    };
    if (root_stat.kind != .file) return .{ .unsafe_root = paths.hyprland };

    const current_chord = try parseChord(gpa, current.shortcut);
    const current_scan = try findConflict(gpa, io, env, paths.hyprland, paths.fragment, current_chord);
    const protects_external = switch (request) {
        .set, .disable => true,
        else => false,
    };
    switch (current_scan) {
        .unresolved => |unresolved| return .{ .unresolved = unresolved },
        .conflict => |conflict| if (protects_external and
            !current.persisted and conflict != null and conflict.?.equivalent)
        {
            var external = current;
            external.external = true;
            return .{ .external_owned = external };
        },
    }

    const requested: State = switch (request) {
        .current => current,
        .set => |value| .{ .enabled = true, .shortcut = value, .persisted = true },
        .reset => .{ .enabled = true, .shortcut = default_shortcut, .persisted = false },
        .disable => .{ .enabled = false, .shortcut = current.shortcut, .persisted = true },
    };
    const normalized = try parseChord(gpa, requested.shortcut);
    const state: State = .{
        .enabled = requested.enabled,
        .shortcut = normalized.display,
        .persisted = true,
    };

    if (state.enabled) {
        switch (try findConflict(gpa, io, env, paths.hyprland, paths.fragment, normalized)) {
            .unresolved => |unresolved| return .{ .unresolved = unresolved },
            .conflict => |maybe_conflict| if (maybe_conflict) |conflict| {
                if (!requested.persisted and
                    std.mem.eql(u8, state.shortcut, default_shortcut) and conflict.equivalent)
                {
                    return .{ .external = state };
                }
                return .{ .conflict = conflict };
            },
        }
    }

    const state_json = try std.json.Stringify.valueAlloc(gpa, StoredState{
        .enabled = state.enabled,
        .shortcut = state.shortcut,
    }, .{ .whitespace = .indent_2 });
    const fragment = if (state.enabled)
        try std.fmt.allocPrint(gpa,
            \\# Generated by SayAll. Use `sayall shortcut` to change this file.
            \\bindd = {s}, {s}, Toggle SayAll dictation, exec, sayall toggle
            \\
        , .{ normalized.modifiers, normalized.key })
    else
        try std.fmt.allocPrint(gpa,
            \\# Generated by SayAll. The global shortcut is disabled.
            \\# Use `sayall shortcut reset` to restore {s}.
            \\
        , .{default_shortcut});

    const old_root = try readOptional(gpa, io, paths.hyprland, 4 * 1024 * 1024) orelse
        return .{ .concurrent_modification = paths.hyprland };
    const new_root = try ensureManagedSource(gpa, old_root, paths.fragment);
    const old_state = try readOptional(gpa, io, paths.state, 1024 * 1024);
    const old_fragment = try readOptional(gpa, io, paths.fragment, 1024 * 1024);
    const changed = !optionalEqual(old_state, state_json) or
        !optionalEqual(old_fragment, fragment) or
        !std.mem.eql(u8, old_root, new_root);

    var written: Written = .{};
    if (changed) writeChanges(
        gpa,
        io,
        paths,
        fragment,
        state_json,
        new_root,
        old_root,
        root_stat.permissions.toMode() & 0o777,
        &written,
    ) catch |err| {
        switch (rollback(gpa, io, paths, old_fragment, old_state, old_root, fragment, state_json, new_root, root_stat.permissions.toMode() & 0o777, written)) {
            .restored => {},
            .concurrent_modification => return .{ .rollback_failed = .concurrent_modification },
            .io_failure => return .{ .rollback_failed = .io_failure },
        }
        if (err == error.ConcurrentShortcutModification) return .{ .concurrent_modification = paths.hyprland };
        return err;
    };

    const activation = reload(io, gpa, env) catch |err| {
        if (changed) {
            switch (rollback(gpa, io, paths, old_fragment, old_state, old_root, fragment, state_json, new_root, root_stat.permissions.toMode() & 0o777, written)) {
                .restored => {},
                .concurrent_modification => return .{ .rollback_failed = .concurrent_modification },
                .io_failure => return .{ .rollback_failed = .io_failure },
            }
            _ = reload(io, gpa, env) catch {};
        }
        return .{ .reload_failed = @errorName(err) };
    };

    return .{ .applied = .{
        .state = state,
        .changed = changed,
        .activation = activation,
    } };
}

pub fn parseShortcut(gpa: Allocator, value: []const u8) ![]const u8 {
    return (try parseChord(gpa, value)).display;
}

fn resolvePaths(gpa: Allocator, env: *const std.process.Environ.Map) !Paths {
    const config_home = if (env.get("XDG_CONFIG_HOME")) |path| path else if (env.get("HOME")) |home|
        try std.fmt.allocPrint(gpa, "{s}/.config", .{home})
    else
        return error.ConfigHomeUnavailable;
    if (config_home.len == 0 or config_home[0] != '/' or
        std.mem.findAny(u8, config_home, &.{ '\r', '\n', '#', '*', '$' }) != null)
        return error.InvalidConfigHome;
    return .{
        .state = try std.fmt.allocPrint(gpa, "{s}/sayall/shortcut.json", .{config_home}),
        .lock = try std.fmt.allocPrint(gpa, "{s}/sayall/shortcut.lock", .{config_home}),
        .fragment = try std.fmt.allocPrint(gpa, "{s}/hypr/sayall.conf", .{config_home}),
        .hyprland = try std.fmt.allocPrint(gpa, "{s}/hypr/hyprland.conf", .{config_home}),
    };
}

fn loadStateAt(gpa: Allocator, io: Io, path: []const u8) !State {
    const bytes = try readOptional(gpa, io, path, 1024 * 1024) orelse return .{
        .enabled = true,
        .shortcut = default_shortcut,
        .persisted = false,
    };
    const stored = try std.json.parseFromSliceLeaky(StoredState, gpa, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    if (stored.version != state_version) return error.UnsupportedShortcutStateVersion;
    const normalized = try parseChord(gpa, stored.shortcut);
    return .{
        .enabled = stored.enabled,
        .shortcut = normalized.display,
        .persisted = true,
    };
}

fn parseChord(gpa: Allocator, value: []const u8) !Chord {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, ',') != null) return error.InvalidShortcut;

    var parts = std.mem.splitScalar(u8, trimmed, '+');
    var ctrl = false;
    var alt = false;
    var shift = false;
    var super = false;
    var key: ?[]const u8 = null;
    while (parts.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) return error.InvalidShortcut;
        if (std.ascii.eqlIgnoreCase(part, "CTRL") or std.ascii.eqlIgnoreCase(part, "CONTROL")) {
            if (ctrl or key != null) return error.InvalidShortcut;
            ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "ALT")) {
            if (alt or key != null) return error.InvalidShortcut;
            alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "SHIFT")) {
            if (shift or key != null) return error.InvalidShortcut;
            shift = true;
        } else if (std.ascii.eqlIgnoreCase(part, "SUPER") or std.ascii.eqlIgnoreCase(part, "WIN") or std.ascii.eqlIgnoreCase(part, "MOD4")) {
            if (super or key != null) return error.InvalidShortcut;
            super = true;
        } else {
            if (key != null or !safeKey(part)) return error.InvalidShortcut;
            key = part;
        }
    }
    const raw_key = key orelse return error.InvalidShortcut;
    const upper_key = try std.ascii.allocUpperString(gpa, raw_key);

    var modifiers = std.ArrayList(u8).empty;
    if (super) try modifiers.appendSlice(gpa, "SUPER ");
    if (ctrl) try modifiers.appendSlice(gpa, "CTRL ");
    if (alt) try modifiers.appendSlice(gpa, "ALT ");
    if (shift) try modifiers.appendSlice(gpa, "SHIFT ");
    if (modifiers.items.len > 0) _ = modifiers.pop();

    var display = std.ArrayList(u8).empty;
    var mod_iter = std.mem.tokenizeScalar(u8, modifiers.items, ' ');
    while (mod_iter.next()) |modifier| {
        if (display.items.len > 0) try display.append(gpa, '+');
        try display.appendSlice(gpa, modifier);
    }
    if (display.items.len > 0) try display.append(gpa, '+');
    try display.appendSlice(gpa, upper_key);
    return .{
        .modifiers = try gpa.dupe(u8, modifiers.items),
        .key = upper_key,
        .display = try gpa.dupe(u8, display.items),
    };
}

fn safeKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != ':' and c != '.') return false;
    }
    return true;
}

fn ensureManagedSource(gpa: Allocator, root: []const u8, fragment_path: []const u8) ![]const u8 {
    const begin_at = std.mem.indexOf(u8, root, managed_begin);
    const end_at = std.mem.indexOf(u8, root, managed_end);
    if ((begin_at == null) != (end_at == null)) return error.MalformedManagedShortcutBlock;
    const block = try std.fmt.allocPrint(gpa, "{s}\nsource = {s}\n{s}\n", .{
        managed_begin,
        fragment_path,
        managed_end,
    });
    if (begin_at) |start| {
        const end_start = end_at.?;
        if (end_start < start) return error.MalformedManagedShortcutBlock;
        const end = end_start + managed_end.len;
        var after = end;
        if (after < root.len and root[after] == '\r') after += 1;
        if (after < root.len and root[after] == '\n') after += 1;
        return std.mem.concat(gpa, u8, &.{ root[0..start], block, root[after..] });
    }
    const separator = if (root.len == 0) "" else if (root[root.len - 1] == '\n') "\n" else "\n\n";
    return std.mem.concat(gpa, u8, &.{ root, separator, block });
}

fn findConflict(
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    root: []const u8,
    managed_fragment: []const u8,
    target: Chord,
) anyerror!ScanResult {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    return scanFile(gpa, io, env, root, managed_fragment, target, &visited, 0, null);
}

const ScanResult = union(enum) {
    conflict: ?Conflict,
    unresolved: Unresolved,
};

fn scanFile(
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    path: []const u8,
    managed_fragment: []const u8,
    target: Chord,
    visited: *std.StringHashMapUnmanaged(void),
    depth: usize,
    existing: ?Conflict,
) anyerror!ScanResult {
    if (depth > 32 or std.mem.eql(u8, path, managed_fragment) or visited.contains(path)) return .{ .conflict = existing };
    try visited.put(gpa, path, {});
    const bytes = try readOptional(gpa, io, path, 4 * 1024 * 1024) orelse return .{ .conflict = existing };
    var current = existing;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const without_comment = raw_line[0 .. std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len];
        const line = std.mem.trim(u8, without_comment, " \t\r");
        if (line.len == 0) continue;
        if (parseSource(line)) |source| {
            if (std.mem.indexOfScalar(u8, source, '$') != null) return .{ .unresolved = .{
                .path = try gpa.dupe(u8, path),
                .line = line_number,
                .expression = try gpa.dupe(u8, line),
            } };
            if (try expandSource(gpa, env, std.fs.path.dirname(path), source)) |source_path| {
                const nested = if (std.mem.indexOfScalar(u8, source_path, '*') != null)
                    try scanGlob(gpa, io, env, source_path, managed_fragment, target, visited, depth + 1, current)
                else
                    try scanFile(gpa, io, env, source_path, managed_fragment, target, visited, depth + 1, current);
                switch (nested) {
                    .unresolved => return nested,
                    .conflict => |conflict| current = conflict,
                }
            }
            continue;
        }
        const parsed = parseBinding(line) orelse continue;
        if (std.mem.indexOfScalar(u8, parsed.modifiers, '$') != null or
            std.mem.indexOfScalar(u8, parsed.key, '$') != null)
        {
            return .{ .unresolved = .{
                .path = try gpa.dupe(u8, path),
                .line = line_number,
                .expression = try gpa.dupe(u8, line),
            } };
        }
        const modifiers = canonicalModifiers(gpa, parsed.modifiers) catch continue;
        const raw_key = std.mem.trim(u8, parsed.key, " \t");
        if (!safeKey(raw_key)) continue;
        const key = try std.ascii.allocUpperString(gpa, raw_key);
        if (!std.mem.eql(u8, modifiers, target.modifiers) or !std.mem.eql(u8, key, target.key)) continue;
        if (parsed.unbind) {
            current = null;
        } else {
            current = .{
                .path = try gpa.dupe(u8, path),
                .line = line_number,
                .binding = try gpa.dupe(u8, line),
                .equivalent = parsed.equivalent,
            };
        }
    }
    return .{ .conflict = current };
}

fn scanGlob(
    gpa: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    pattern_path: []const u8,
    managed_fragment: []const u8,
    target: Chord,
    visited: *std.StringHashMapUnmanaged(void),
    depth: usize,
    existing: ?Conflict,
) anyerror!ScanResult {
    const directory_path = std.fs.path.dirname(pattern_path) orelse return .{ .conflict = existing };
    if (std.mem.indexOfScalar(u8, directory_path, '*') != null) return .{ .conflict = existing };
    const pattern = std.fs.path.basename(pattern_path);
    var directory = (if (std.fs.path.isAbsolute(directory_path))
        Io.Dir.openDirAbsolute(io, directory_path, .{ .iterate = true })
    else
        Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true })) catch |err| switch (err) {
        error.FileNotFound => return .{ .conflict = existing },
        else => return err,
    };
    defer directory.close(io);
    var current = existing;
    var iterator = directory.iterateAssumeFirstIteration();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!wildcardMatches(pattern, entry.name)) continue;
        const path = try std.fs.path.join(gpa, &.{ directory_path, entry.name });
        switch (try scanFile(gpa, io, env, path, managed_fragment, target, visited, depth, current)) {
            .unresolved => |unresolved| return .{ .unresolved = unresolved },
            .conflict => |conflict| current = conflict,
        }
    }
    return .{ .conflict = current };
}

fn wildcardMatches(pattern: []const u8, value: []const u8) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star: ?usize = null;
    var retry_value: usize = 0;
    while (value_index < value.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == value[value_index]) {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star = pattern_index;
            pattern_index += 1;
            retry_value = value_index;
        } else if (star) |star_index| {
            pattern_index = star_index + 1;
            retry_value += 1;
            value_index = retry_value;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn parseSource(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "source")) return null;
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (std.mem.trim(u8, line[0..equals], " \t").len != "source".len) return null;
    const value = std.mem.trim(u8, line[equals + 1 ..], " \t");
    return if (value.len == 0) null else value;
}

fn expandSource(gpa: Allocator, env: *const std.process.Environ.Map, parent: ?[]const u8, source: []const u8) !?[]const u8 {
    if (source[0] == '~') {
        const home = env.get("HOME") orelse return null;
        if (source.len == 1) return try gpa.dupe(u8, home);
        if (source[1] != '/') return null;
        return try std.fmt.allocPrint(gpa, "{s}/{s}", .{ home, source[2..] });
    }
    if (std.fs.path.isAbsolute(source)) return try gpa.dupe(u8, source);
    const base = parent orelse return null;
    return try std.fs.path.join(gpa, &.{ base, source });
}

const ParsedBinding = struct {
    unbind: bool,
    modifiers: []const u8,
    key: []const u8,
    equivalent: bool,
};

fn parseBinding(line: []const u8) ?ParsedBinding {
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    const name = std.mem.trim(u8, line[0..equals], " \t");
    const is_unbind = std.mem.eql(u8, name, "unbind");
    if (!is_unbind) {
        if (!std.mem.startsWith(u8, name, "bind") or name.len > 16) return null;
        for (name[4..]) |c| if (!std.ascii.isAlphabetic(c)) return null;
    }
    var fields = std.mem.splitScalar(u8, line[equals + 1 ..], ',');
    const modifiers = fields.next() orelse return null;
    const key = fields.next() orelse return null;
    var equivalent = false;
    while (fields.next()) |field| {
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, field, " \t"), "exec")) continue;
        const command = fields.next() orelse break;
        equivalent = isSayallToggle(command);
        break;
    }
    return .{
        .unbind = is_unbind,
        .modifiers = modifiers,
        .key = key,
        .equivalent = equivalent,
    };
}

fn isSayallToggle(command: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, command, " \t");
    const executable = tokens.next() orelse return false;
    const action = tokens.next() orelse return false;
    if (tokens.next() != null or !std.mem.eql(u8, action, "toggle")) return false;
    return std.mem.eql(u8, std.fs.path.basename(executable), "sayall");
}

fn canonicalModifiers(gpa: Allocator, value: []const u8) ![]const u8 {
    const normalized = try std.mem.replaceOwned(u8, gpa, value, "+", " ");
    var tokens = std.mem.tokenizeAny(u8, normalized, " \t");
    var ctrl = false;
    var alt = false;
    var shift = false;
    var super = false;
    while (tokens.next()) |token| {
        if (std.ascii.eqlIgnoreCase(token, "CTRL") or std.ascii.eqlIgnoreCase(token, "CONTROL")) ctrl = true else if (std.ascii.eqlIgnoreCase(token, "ALT")) alt = true else if (std.ascii.eqlIgnoreCase(token, "SHIFT")) shift = true else if (std.ascii.eqlIgnoreCase(token, "SUPER") or std.ascii.eqlIgnoreCase(token, "MOD4") or std.ascii.eqlIgnoreCase(token, "WIN")) super = true else return error.InvalidModifier;
    }
    var result = std.ArrayList(u8).empty;
    if (super) try result.appendSlice(gpa, "SUPER ");
    if (ctrl) try result.appendSlice(gpa, "CTRL ");
    if (alt) try result.appendSlice(gpa, "ALT ");
    if (shift) try result.appendSlice(gpa, "SHIFT ");
    if (result.items.len > 0) _ = result.pop();
    return result.toOwnedSlice(gpa);
}

fn reload(io: Io, gpa: Allocator, env: *const std.process.Environ.Map) !Activation {
    if (env.get("HYPRLAND_INSTANCE_SIGNATURE") == null) return .deferred;
    const reload_result = std.process.run(gpa, io, .{
        .argv = &.{ "hyprctl", "reload" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.HyprlandReloadUnavailable;
    if (!termSucceeded(reload_result.term)) return error.HyprlandReloadFailed;
    const errors_result = std.process.run(gpa, io, .{
        .argv = &.{ "hyprctl", "configerrors" },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.HyprlandValidationUnavailable;
    if (!termSucceeded(errors_result.term)) return error.HyprlandValidationFailed;
    const config_errors = std.mem.trim(u8, errors_result.stdout, " \t\r\n");
    if (config_errors.len != 0 and !containsNoErrors(config_errors)) return error.HyprlandConfigErrors;
    return .reloaded;
}

fn containsNoErrors(output: []const u8) bool {
    var index: usize = 0;
    while (index + "no errors".len <= output.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(output[index .. index + "no errors".len], "no errors")) return true;
    }
    return false;
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn ensureParent(io: Io, path: []const u8, mode: u32) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidShortcutPath;
    const dir = try Io.Dir.cwd().createDirPathOpen(io, parent, .{
        .open_options = .{ .iterate = true },
        .permissions = @enumFromInt(mode),
    });
    defer dir.close(io);
}

fn acquireLock(io: Io, path: []const u8) !Io.File {
    try ensureParent(io, path, 0o700);
    return Io.Dir.createFileAbsolute(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .permissions = @enumFromInt(0o600),
    });
}

const Written = struct {
    fragment: bool = false,
    state: bool = false,
    root: bool = false,
};

fn writeChanges(
    gpa: Allocator,
    io: Io,
    paths: Paths,
    fragment: []const u8,
    state_json: []const u8,
    root: []const u8,
    old_root: []const u8,
    root_mode: u32,
    written: *Written,
) !void {
    try ensureParent(io, paths.state, 0o700);
    try ensureParent(io, paths.fragment, 0o700);
    // Write the sourced file before adding its source directive.
    try atomicWrite(gpa, io, paths.fragment, fragment, 0o600);
    written.fragment = true;
    try atomicWrite(gpa, io, paths.state, state_json, 0o600);
    written.state = true;
    try replaceRootIfUnchanged(gpa, io, paths.hyprland, old_root, root, root_mode);
    written.root = true;
}

fn replaceRootIfUnchanged(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    expected: []const u8,
    replacement: []const u8,
    mode: u32,
) !void {
    const stat = Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch
        return error.ConcurrentShortcutModification;
    if (stat.kind != .file) return error.ConcurrentShortcutModification;
    const current = try readOptional(gpa, io, path, 4 * 1024 * 1024);
    if (!optionalEqual(current, expected)) return error.ConcurrentShortcutModification;
    try atomicWrite(gpa, io, path, replacement, mode);
}

fn atomicWrite(gpa: Allocator, io: Io, path: []const u8, data: []const u8, mode: u32) !void {
    var nonce: u64 = undefined;
    try std.Io.randomSecure(io, std.mem.asBytes(&nonce));
    const temp = try std.fmt.allocPrint(gpa, "{s}.tmp-{x}", .{ path, nonce });
    errdefer Io.Dir.deleteFileAbsolute(io, temp) catch {};
    const file = try Io.Dir.createFileAbsolute(io, temp, .{ .permissions = @enumFromInt(mode) });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
    try file.sync(io);
    try Io.Dir.rename(.cwd(), temp, .cwd(), path, io);
}

fn restore(gpa: Allocator, io: Io, path: []const u8, previous: ?[]const u8, mode: u32) !void {
    if (previous) |contents| {
        try atomicWrite(gpa, io, path, contents, mode);
    } else {
        Io.Dir.deleteFileAbsolute(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn restoreIfCurrentMatches(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    expected_written: []const u8,
    previous: ?[]const u8,
    mode: u32,
) !void {
    const current = try readOptional(gpa, io, path, 4 * 1024 * 1024);
    if (!optionalEqual(current, expected_written)) return error.ConcurrentShortcutModification;
    try restore(gpa, io, path, previous, mode);
}

const RollbackStatus = enum {
    restored,
    concurrent_modification,
    io_failure,
};

fn rollback(
    gpa: Allocator,
    io: Io,
    paths: Paths,
    old_fragment: ?[]const u8,
    old_state: ?[]const u8,
    old_root: ?[]const u8,
    fragment: []const u8,
    state_json: []const u8,
    root: []const u8,
    root_mode: u32,
    written: Written,
) RollbackStatus {
    var status: RollbackStatus = .restored;
    if (written.root) restoreIfCurrentMatches(gpa, io, paths.hyprland, root, old_root, root_mode) catch |err| {
        status = mergeRollbackFailure(status, err);
    };
    if (written.state) restoreIfCurrentMatches(gpa, io, paths.state, state_json, old_state, 0o600) catch |err| {
        status = mergeRollbackFailure(status, err);
    };
    if (written.fragment) restoreIfCurrentMatches(gpa, io, paths.fragment, fragment, old_fragment, 0o600) catch |err| {
        status = mergeRollbackFailure(status, err);
    };
    return status;
}

fn mergeRollbackFailure(current: RollbackStatus, err: anyerror) RollbackStatus {
    if (err == error.ConcurrentShortcutModification) return .concurrent_modification;
    return if (current == .concurrent_modification) current else .io_failure;
}

fn readOptional(gpa: Allocator, io: Io, path: []const u8, limit: usize) !?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn optionalEqual(existing: ?[]const u8, desired: []const u8) bool {
    return if (existing) |bytes| std.mem.eql(u8, bytes, desired) else false;
}

test "shortcut parser normalizes modifier order and aliases" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    try std.testing.expectEqualStrings("SUPER+CTRL+SHIFT+SLASH", try parseShortcut(gpa, "win+shift+control+slash"));
    try std.testing.expectEqualStrings("F9", try parseShortcut(gpa, "f9"));
    try std.testing.expectError(error.InvalidShortcut, parseShortcut(gpa, "CTRL++K"));
    try std.testing.expectError(error.InvalidShortcut, parseShortcut(gpa, "CTRL+K+ALT"));
    try std.testing.expect(isSayallToggle("/usr/bin/sayall toggle"));
    try std.testing.expect(!isSayallToggle("sayall toggle --raw"));
    try std.testing.expect(containsNoErrors("no errors"));
    try std.testing.expect(containsNoErrors("Hyprland: No Errors detected"));
    try std.testing.expect(!containsNoErrors("error at line 4"));
    try std.testing.expect(wildcardMatches("*.conf", "bindings.conf"));
    try std.testing.expect(!wildcardMatches("*.conf", "bindings.txt"));
}

test "managed source block is idempotent" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const initial = "source = ~/.config/hypr/bindings.conf\n";
    const once = try ensureManagedSource(gpa, initial, "/tmp/config/hypr/sayall.conf");
    const twice = try ensureManagedSource(gpa, once, "/tmp/config/hypr/sayall.conf");
    try std.testing.expectEqualStrings(once, twice);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, once, managed_begin));
    const with_following_setting = try std.mem.concat(gpa, u8, &.{ once, "bind = SUPER, H, exec, example\n" });
    const replaced = try ensureManagedSource(gpa, with_following_setting, "/tmp/config/hypr/sayall.conf");
    try std.testing.expect(std.mem.indexOf(u8, replaced, managed_end ++ "\nbind = SUPER") != null);
}

test "shortcut transaction lock is exclusive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const relative_base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, gpa);
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/sayall/shortcut.lock", .{base});

    const first = try acquireLock(std.testing.io, lock_path);
    defer first.close(std.testing.io);
    const second = try Io.Dir.openFileAbsolute(std.testing.io, lock_path, .{ .mode = .read_write });
    defer second.close(std.testing.io);
    try std.testing.expect(!try second.tryLock(std.testing.io, .exclusive));
}

test "symlinked root is rejected before lock directory creation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const relative_base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, gpa);
    const config_home = try std.fmt.allocPrint(gpa, "{s}/config", .{base});
    const root = try std.fmt.allocPrint(gpa, "{s}/hypr/hyprland.conf", .{config_home});
    const target = try std.fmt.allocPrint(gpa, "{s}/target.conf", .{base});
    const lock_dir = try std.fmt.allocPrint(gpa, "{s}/sayall", .{config_home});
    const lock_path = try std.fmt.allocPrint(gpa, "{s}/shortcut.lock", .{lock_dir});
    try ensureParent(std.testing.io, root, 0o700);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = target, .data = "# target remains unchanged\n" });
    try Io.Dir.symLinkAbsolute(std.testing.io, target, root, .{});

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", config_home);
    try env.put("HOME", base);

    const result = try apply(gpa, std.testing.io, &env, .reset);
    try std.testing.expect(result == .unsafe_root);
    const root_after = try Io.Dir.cwd().statFile(std.testing.io, root, .{ .follow_symlinks = false });
    try std.testing.expect(root_after.kind == .sym_link);
    try std.testing.expect((try readOptional(gpa, std.testing.io, lock_path, 1024)) == null);
    try std.testing.expectError(
        error.FileNotFound,
        Io.Dir.cwd().statFile(std.testing.io, lock_dir, .{ .follow_symlinks = false }),
    );
    try std.testing.expectEqualStrings(
        "# target remains unchanged\n",
        (try readOptional(gpa, std.testing.io, target, 1024)).?,
    );
}

test "root replacement and rollback reject concurrent content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hyprland.conf", .{tmp.sub_path});

    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root, .data = "# concurrent edit\n" });
    try std.testing.expectError(
        error.ConcurrentShortcutModification,
        replaceRootIfUnchanged(gpa, std.testing.io, root, "# snapshot\n", "# replacement\n", 0o600),
    );
    try std.testing.expectEqualStrings(
        "# concurrent edit\n",
        (try readOptional(gpa, std.testing.io, root, 1024)).?,
    );

    try std.testing.expectError(
        error.ConcurrentShortcutModification,
        restoreIfCurrentMatches(gpa, std.testing.io, root, "# transaction write\n", "# original\n", 0o600),
    );
    try std.testing.expectEqualStrings(
        "# concurrent edit\n",
        (try readOptional(gpa, std.testing.io, root, 1024)).?,
    );
}

test "conflict scanning follows sources and honors unbind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const root = try std.fmt.allocPrint(gpa, "{s}/hyprland.conf", .{base});
    const bindings = try std.fmt.allocPrint(gpa, "{s}/bindings.conf", .{base});
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root, .data = "source = bindings.conf\n" });
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bindings, .data = "bindd = CTRL, SLASH, Existing action, exec, something\n" });
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const chord = try parseChord(gpa, default_shortcut);
    const first_scan = try findConflict(gpa, std.testing.io, &env, root, "/not-managed", chord);
    try std.testing.expect(first_scan == .conflict);
    const conflict = first_scan.conflict.?;
    try std.testing.expectEqualStrings(bindings, conflict.path);
    try std.testing.expectEqual(@as(usize, 1), conflict.line);

    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root, .data = "source = *.conf\n" });
    const glob_scan = try findConflict(gpa, std.testing.io, &env, root, "/not-managed", chord);
    try std.testing.expect(glob_scan == .conflict and glob_scan.conflict != null);

    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bindings, .data = "bind = CTRL, SLASH, exec, something\nunbind = CTRL, SLASH\n" });
    const unbound_scan = try findConflict(gpa, std.testing.io, &env, root, "/not-managed", chord);
    try std.testing.expect(unbound_scan == .conflict and unbound_scan.conflict == null);
}

test "apply is idempotent and preserves custom and disabled state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const relative_base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, gpa);
    const config_home = try std.fmt.allocPrint(gpa, "{s}/config", .{base});
    const hypr_dir = try std.fmt.allocPrint(gpa, "{s}/hypr", .{config_home});
    const root = try std.fmt.allocPrint(gpa, "{s}/hyprland.conf", .{hypr_dir});
    const fragment = try std.fmt.allocPrint(gpa, "{s}/sayall.conf", .{hypr_dir});
    try ensureParent(std.testing.io, root, 0o700);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root, .data = "# test config\n" });

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", config_home);
    try env.put("HOME", base);

    const first = try apply(gpa, std.testing.io, &env, .current);
    try std.testing.expect(first == .applied);
    try std.testing.expect(first.applied.changed);
    try std.testing.expectEqual(Activation.deferred, first.applied.activation);
    try std.testing.expectEqualStrings(default_shortcut, first.applied.state.shortcut);
    const default_fragment = (try readOptional(gpa, std.testing.io, fragment, 1024)).?;
    try std.testing.expect(std.mem.indexOf(u8, default_fragment, "bindd = CTRL, SLASH") != null);

    const custom = try apply(gpa, std.testing.io, &env, .{ .set = "super+alt+k" });
    try std.testing.expect(custom == .applied);
    try std.testing.expectEqualStrings("SUPER+ALT+K", custom.applied.state.shortcut);

    const setup_again = try apply(gpa, std.testing.io, &env, .current);
    try std.testing.expect(setup_again == .applied);
    try std.testing.expect(!setup_again.applied.changed);
    try std.testing.expectEqualStrings("SUPER+ALT+K", setup_again.applied.state.shortcut);

    const disabled = try apply(gpa, std.testing.io, &env, .disable);
    try std.testing.expect(disabled == .applied);
    const disabled_again = try apply(gpa, std.testing.io, &env, .current);
    try std.testing.expect(disabled_again == .applied);
    try std.testing.expect(!disabled_again.applied.changed);
    try std.testing.expect(!disabled_again.applied.state.enabled);
    const disabled_fragment = (try readOptional(gpa, std.testing.io, fragment, 1024)).?;
    try std.testing.expect(std.mem.indexOf(u8, disabled_fragment, "bindd") == null);

    const root_contents = (try readOptional(gpa, std.testing.io, root, 1024 * 1024)).?;
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, root_contents, managed_begin));
}

test "apply reports conflicts without changing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const relative_base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, gpa);
    const config_home = try std.fmt.allocPrint(gpa, "{s}/config", .{base});
    const root = try std.fmt.allocPrint(gpa, "{s}/hypr/hyprland.conf", .{config_home});
    const original = "bindd = CTRL, SLASH, Existing shortcut, exec, other-command\n";
    try ensureParent(std.testing.io, root, 0o700);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root, .data = original });

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", config_home);
    try env.put("HOME", base);

    const result = try apply(gpa, std.testing.io, &env, .current);
    try std.testing.expect(result == .conflict);
    try std.testing.expectEqual(@as(usize, 1), result.conflict.line);
    const after = (try readOptional(gpa, std.testing.io, root, 1024)).?;
    try std.testing.expectEqualStrings(original, after);
    const state_path = try std.fmt.allocPrint(gpa, "{s}/sayall/shortcut.json", .{config_home});
    try std.testing.expect((try readOptional(gpa, std.testing.io, state_path, 1024)) == null);
}

test "setup accepts an equivalent manual default binding without taking ownership" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    const relative_base = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    const base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, gpa);
    const config_home = try std.fmt.allocPrint(gpa, "{s}/config", .{base});
    const root = try std.fmt.allocPrint(gpa, "{s}/hypr/hyprland.conf", .{config_home});
    const bindings = try std.fmt.allocPrint(gpa, "{s}/hypr/bindings.conf", .{config_home});
    const root_original = "source = bindings.conf\n";
    const binding_original = "bind = CTRL, SLASH, exec, sayall toggle\n";
    try ensureParent(std.testing.io, root, 0o700);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = root, .data = root_original });
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = bindings, .data = binding_original });

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", config_home);
    try env.put("HOME", base);

    const result = try apply(gpa, std.testing.io, &env, .current);
    try std.testing.expect(result == .external);
    try std.testing.expectEqualStrings(default_shortcut, result.external.shortcut);
    const viewed = try loadState(gpa, std.testing.io, &env);
    try std.testing.expect(viewed.external);
    try std.testing.expectEqualStrings(root_original, (try readOptional(gpa, std.testing.io, root, 1024)).?);
    try std.testing.expectEqualStrings(binding_original, (try readOptional(gpa, std.testing.io, bindings, 1024)).?);
    const state_path = try std.fmt.allocPrint(gpa, "{s}/sayall/shortcut.json", .{config_home});
    const fragment_path = try std.fmt.allocPrint(gpa, "{s}/hypr/sayall.conf", .{config_home});
    try std.testing.expect((try readOptional(gpa, std.testing.io, state_path, 1024)) == null);
    try std.testing.expect((try readOptional(gpa, std.testing.io, fragment_path, 1024)) == null);
}
