const std = @import("std");
const contract = @import("contracts.zig");
const shortcut_impl = @import("linux_shortcut.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn restart(io: Io) !contract.RestartResult {
    var child = std.process.spawn(io, .{
        .argv = &.{ "systemctl", "--user", "restart", "sayall.service" },
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
        .services_ok = setupServices(io),
    };
}

pub fn prepareUpdate(arena: Allocator, io: Io) !contract.UpdatePreparation {
    const package = try installedPackage(arena, io) orelse return .package_missing;
    if (!try commandExists(arena, io, "yay")) return .yay_missing;
    return .{ .ready = package };
}

pub fn finishUpdate(arena: Allocator, io: Io, env: *const std.process.Environ.Map, plan: contract.UpdatePlan) !contract.UpdateResult {
    if (!runInherited(io, &.{ "yay", "-S", "--needed", plan.update_target })) return .package_failed;
    if (!setupServices(io)) return .services_failed;
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

pub fn environmentDiagnostic(env: *const std.process.Environ.Map) !contract.Diagnostic {
    return if (env.get("WAYLAND_DISPLAY")) |display|
        .{ .status = .ok, .label = "Wayland", .detail = display }
    else
        .{ .status = .fail, .label = "Wayland", .detail = "WAYLAND_DISPLAY is not set" };
}

pub fn diagnostics(arena: Allocator, io: Io, notifications_enabled: ?bool) !contract.Diagnostics {
    const required_commands = [_][]const u8{ "pw-record", "wtype", "wl-copy", "sayall-hud" };
    var commands: [required_commands.len]contract.Diagnostic = undefined;
    for (required_commands, 0..) |command, index| {
        commands[index] = if (try commandExists(arena, io, command))
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

    const services = [2]contract.Diagnostic{
        if (try commandSucceeds(arena, io, &.{ "systemctl", "--user", "is-active", "--quiet", "sayall.service" }))
            .{ .status = .ok, .label = "Service", .detail = "sayall.service is active" }
        else
            .{ .status = .fail, .label = "Service", .detail = "start with: systemctl --user enable --now sayall sayall-hud" },
        if (try commandSucceeds(arena, io, &.{ "systemctl", "--user", "is-active", "--quiet", "sayall-hud.service" }))
            .{ .status = .ok, .label = "HUD service", .detail = "sayall-hud.service is active" }
        else
            .{ .status = .fail, .label = "HUD service", .detail = "start with: systemctl --user enable --now sayall-hud" },
    };

    return .{
        .commands = commands,
        .notification = notification,
        .services = services,
    };
}

fn setupServices(io: Io) bool {
    if (!runInherited(io, &.{ "systemctl", "--user", "daemon-reload" })) return false;
    if (!runInherited(io, &.{ "systemctl", "--user", "enable", "sayall.service", "sayall-hud.service" })) return false;
    return runInherited(io, &.{ "systemctl", "--user", "restart", "sayall.service", "sayall-hud.service" });
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
