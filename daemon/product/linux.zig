const std = @import("std");
const contract = @import("contracts.zig");
const shortcut_impl = @import("linux_shortcut.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn restart(io: Io) !contract.RestartResult {
    var child = std.process.spawn(io, .{
        .argv = &.{ "systemctl", "--user", "restart", "sayall-hud.service" },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| return .{ .spawn_failed = err };
    const term = child.wait(io) catch |err| return .{ .wait_failed = err };
    return if (termSucceeded(term)) .restarted else .failed;
}

pub fn setup(
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    comptime presentShortcut: anytype,
) !contract.SetupResult {
    const shortcut_result = try shortcut_impl.apply(arena, io, env, .current);
    const shortcut_ok = try presentShortcut(arena, io, shortcut_result);
    return .{
        .shortcut_ok = shortcut_ok,
        .services_ok = setupServices(arena, io),
    };
}

pub fn prepareUpdate(arena: Allocator, io: Io) !contract.UpdatePreparation {
    const package = try installedPackage(arena, io) orelse return .package_missing;
    if (!try commandExists(arena, io, "yay")) return .yay_missing;
    return .{ .ready = package };
}

pub fn finishUpdate(arena: Allocator, io: Io, env: *const std.process.Environ.Map, plan: contract.UpdatePlan) !contract.UpdateResult {
    if (!runInherited(io, &.{ "yay", "-S", "--needed", plan.update_target })) return .package_failed;
    if (!setupServices(arena, io)) return .services_failed;
    return .{ .shortcut = try shortcut_impl.apply(arena, io, env, .current) };
}

pub fn shortcut(
    arena: Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    request: contract.ShortcutRequest,
) !contract.ShortcutResult {
    return switch (request) {
        .show => .{ .state = try shortcut_impl.loadState(arena, io, env) },
        .reset => .{ .applied = try shortcut_impl.apply(arena, io, env, .reset) },
        .disable => .{ .applied = try shortcut_impl.apply(arena, io, env, .disable) },
        .set => |requested| blk: {
            const normalized = shortcut_impl.parseShortcut(arena, requested) catch break :blk .{ .invalid = requested };
            break :blk .{ .applied = try shortcut_impl.apply(arena, io, env, .{ .set = normalized }) };
        },
    };
}

const Session = enum { wayland, x11, unavailable };

fn session(env: *const std.process.Environ.Map) Session {
    const wayland = env.get("WAYLAND_DISPLAY") != null;
    const x11 = env.get("DISPLAY") != null;
    if (env.get("XDG_SESSION_TYPE")) |kind| {
        if (std.ascii.eqlIgnoreCase(kind, "wayland") and wayland) return .wayland;
        if (std.ascii.eqlIgnoreCase(kind, "x11") and x11) return .x11;
    }
    if (wayland) return .wayland;
    if (x11) return .x11;
    return .unavailable;
}

pub fn environmentDiagnostic(env: *const std.process.Environ.Map) !contract.Diagnostic {
    return switch (session(env)) {
        .wayland => .{ .status = .ok, .label = "Wayland", .detail = env.get("WAYLAND_DISPLAY").? },
        .x11 => .{ .status = .ok, .label = "X11", .detail = env.get("DISPLAY").? },
        .unavailable => .{ .status = .fail, .label = "Display", .detail = "neither WAYLAND_DISPLAY nor DISPLAY is set" },
    };
}

pub fn diagnostics(arena: Allocator, io: Io, env: *const std.process.Environ.Map, notifications_enabled: ?bool, output_method: ?[]const u8) !contract.Diagnostics {
    const selected = session(env);
    const required_commands = [_][]const u8{
        "pw-record",
        if (selected == .x11) "xdotool" else "wtype",
        if (selected == .x11) "xsel" else "wl-copy",
        "sayall-hud",
    };
    var commands: [required_commands.len]contract.Diagnostic = undefined;
    for (required_commands, 0..) |command, index| {
        const type_command = std.mem.eql(u8, command, "wtype") or std.mem.eql(u8, command, "xdotool");
        const required = !type_command or output_method == null or
            !std.mem.eql(u8, output_method.?, "clipboard");
        commands[index] = if (!required)
            .{ .status = .ok, .label = "Command", .detail = "typing tool not required for clipboard output" }
        else if (try commandExists(arena, io, command))
            .{ .status = .ok, .label = "Command", .detail = command }
        else
            .{ .status = .fail, .label = "Missing command", .detail = command };
    }

    const notification: ?contract.Diagnostic = if (notifications_enabled == true)
        if (try commandExists(arena, io, "notify-send"))
            .{ .status = .ok, .label = "Command", .detail = "notify-send" }
        else
            .{ .status = .warn, .label = "Missing command", .detail = "notify-send (notifications will fail)" }
    else
        null;

    const services = [1]contract.Diagnostic{
        if (try commandSucceeds(arena, io, &.{ "systemctl", "--user", "is-active", "--quiet", "sayall-hud.service" }))
            .{ .status = .ok, .label = "Host service", .detail = "sayall-hud.service is active" }
        else
            .{ .status = .fail, .label = "Host service", .detail = "start with: systemctl --user enable --now sayall-hud.service" },
    };

    return .{
        .commands = commands,
        .notification = notification,
        .services = services,
    };
}

fn setupServices(arena: Allocator, io: Io) bool {
    if (!runInherited(io, &.{ "systemctl", "--user", "daemon-reload" })) return false;
    if (!runInherited(io, &.{ "systemctl", "--user", "enable", "sayall-hud.service" })) return false;
    _ = runInherited(io, &.{ "systemctl", "--user", "stop", "sayall.service" });
    if (!legacyOwnerInactive(arena, io)) return false;
    _ = runInherited(io, &.{ "systemctl", "--user", "disable", "sayall.service" });
    return runInherited(io, &.{ "systemctl", "--user", "restart", "sayall-hud.service" });
}

fn legacyOwnerInactive(arena: Allocator, io: Io) bool {
    const result = std.process.run(arena, io, .{
        .argv = &.{ "systemctl", "--user", "is-active", "sayall.service" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    const state = std.mem.trim(u8, result.stdout, " \t\r\n");
    return !termSucceeded(result.term) and
        (std.mem.eql(u8, state, "inactive") or
            std.mem.eql(u8, state, "failed") or
            std.mem.eql(u8, state, "unknown"));
}

fn runInherited(io: Io, argv: []const []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return termSucceeded(term);
}

fn installedPackage(arena: Allocator, io: Io) !?contract.UpdatePlan {
    for (aur_package_candidates) |package| {
        if (try commandSucceeds(arena, io, &.{ "pacman", "-Qq", package })) return packageIdentity(package).?;
    }
    return null;
}

fn packageIdentity(installed: []const u8) ?contract.UpdatePlan {
    if (std.mem.eql(u8, installed, "sayall-src")) return .{
        .installed = installed,
        .update_target = "sayall",
        .legacy_migration = true,
    };
    for (aur_package_candidates[0..3]) |current| {
        if (std.mem.eql(u8, installed, current)) return .{
            .installed = installed,
            .update_target = installed,
            .legacy_migration = false,
        };
    }
    return null;
}

const aur_package_candidates = [_][]const u8{
    "sayall",
    "sayall-bin",
    "sayall-git",
    "sayall-src",
};

fn commandExists(arena: Allocator, io: Io, command: []const u8) !bool {
    return commandSucceeds(arena, io, &.{ "sh", "-c", "command -v -- \"$1\" >/dev/null 2>&1", "sayall-doctor", command });
}

fn commandSucceeds(arena: Allocator, io: Io, argv: []const []const u8) !bool {
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return false;
    return termSucceeded(result.term);
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "package identities preserve current variants and legacy migration" {
    const expected = [_]struct {
        name: []const u8,
        target: []const u8,
        migration: bool,
    }{
        .{ .name = "sayall", .target = "sayall", .migration = false },
        .{ .name = "sayall-bin", .target = "sayall-bin", .migration = false },
        .{ .name = "sayall-git", .target = "sayall-git", .migration = false },
        .{ .name = "sayall-src", .target = "sayall", .migration = true },
    };
    for (expected) |item| {
        const identity = packageIdentity(item.name).?;
        try std.testing.expectEqualStrings(item.name, identity.installed);
        try std.testing.expectEqualStrings(item.target, identity.update_target);
        try std.testing.expectEqual(item.migration, identity.legacy_migration);
    }
    try std.testing.expect(packageIdentity("other") == null);
}

test "session selection matches native host precedence" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(Session.unavailable, session(&env));
    try env.put("DISPLAY", ":0");
    try std.testing.expectEqual(Session.x11, session(&env));
    try env.put("WAYLAND_DISPLAY", "wayland-1");
    try std.testing.expectEqual(Session.wayland, session(&env));
    try env.put("XDG_SESSION_TYPE", "x11");
    try std.testing.expectEqual(Session.x11, session(&env));
    try env.put("XDG_SESSION_TYPE", "wayland");
    try std.testing.expectEqual(Session.wayland, session(&env));
}
