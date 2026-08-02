const std = @import("std");
const cli = @import("cli.zig");
const cli_config_validate = @import("cli_config_validate.zig");
const cli_doctor = @import("cli_doctor.zig");
const cli_transcribe = @import("cli_transcribe.zig");
const config = @import("config.zig");
const host = @import("host_control.zig");
const darwin_host = @import("darwin_host_control.zig");
const build_options = @import("build_options");
extern fn sayall_darwin_effective_home() ?[*:0]u8;
extern fn sayall_darwin_free(?*anyopaque) void;

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("sayall: frontend failure ({s})\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const argv = init.minimal.args.vector;
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "transcribe")) {
        try ensureConfigHome(init.environ_map);
        var values: [3][]const u8 = undefined;
        if (argv.len < 3 or argv.len > 5) return writePresentation(init.io, cli.invalid_presentation);
        for (argv[2..], 0..) |arg, i| values[i] = std.mem.span(arg);
        const options = cli_transcribe.parse(values[0 .. argv.len - 2]) catch
            return writePresentation(init.io, cli.invalid_presentation);
        return cli_transcribe.run(init.gpa, init.arena.allocator(), init.io, init.environ_map, options);
    }
    var args: [3][]const u8 = undefined;
    if (argv.len < 2) return writePresentation(init.io, cli.usage_presentation);
    if (argv.len > 4) return writePresentation(init.io, cli.invalid_presentation);
    for (argv[1..], 0..) |arg, i| args[i] = std.mem.span(arg);
    const command = cli.parse(args[0 .. argv.len - 1]) catch return writePresentation(init.io, cli.invalid_presentation);
    if (command == .config_init or command == .config_validate or command == .config_validate_json or command == .doctor or command == .doctor_json) {
        try ensureConfigHome(init.environ_map);
    }
    if (command == .config_validate or command == .config_validate_json) {
        return cli_config_validate.run(init.arena.allocator(), init.io, init.environ_map, command == .config_validate_json);
    }
    if (command == .config_init) {
        const path = config.initDefault(init.arena.allocator(), init.io, init.environ_map) catch |err| {
            const message = try std.fmt.allocPrint(init.arena.allocator(), "sayall: cannot initialize configuration ({s})\n", .{@errorName(err)});
            try write(init.io, .stderr(), message);
            return 1;
        };
        const message = try std.fmt.allocPrint(init.arena.allocator(), "Created {s}\n", .{path});
        try write(init.io, .stdout(), message);
        return 0;
    }
    _ = host;
    var darwin = darwin_host.Darwin{ .arena = init.arena.allocator() };
    if (command == .doctor or command == .doctor_json) {
        return cli_doctor.run(init.arena.allocator(), init.io, init.environ_map, darwin.adapter(), build_options.version, command == .doctor_json, &.{});
    }
    if (command == .update) return update(init, darwin.adapter());
    const version = try std.fmt.allocPrint(init.arena.allocator(), "sayall {s}\n", .{build_options.version});
    const result = cli.execute(command, version, darwin.adapter());
    try write(init.io, .stdout(), result.stdout);
    try write(init.io, .stderr(), result.stderr);
    return result.exit_code;
}

fn update(init: std.process.Init, control: cli.HostControl) !u8 {
    if (!cli.updateAllowed(control.status())) {
        try write(init.io, .stderr(), "sayall: cannot update unless the macOS host is reachable and idle\n");
        return 1;
    }
    const brew: ?[]const u8 = if (isExecutable(init.io, "/opt/homebrew/bin/brew")) "/opt/homebrew/bin/brew" else if (isExecutable(init.io, "/usr/local/bin/brew")) "/usr/local/bin/brew" else null;
    if (brew) |path| {
        const owned = try std.process.run(init.arena.allocator(), init.io, .{ .argv = &.{ path, "list", "--cask", "sayall" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) });
        if (termSucceeded(owned.term)) {
            var child = try std.process.spawn(init.io, .{ .argv = &.{ path, "upgrade", "--cask", "sayall" }, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit });
            return if (termSucceeded(try child.wait(init.io))) 0 else 1;
        }
    }
    try write(init.io, .stderr(), "sayall: this installation has no supported automatic updater; download and install the latest signed DMG manually\n");
    return 1;
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file and stat.permissions.toMode() & 0o111 != 0;
}

fn ensureConfigHome(env: *const std.process.Environ.Map) !void {
    if (env.get("XDG_CONFIG_HOME") != null) return;
    const home = sayall_darwin_effective_home() orelse return error.ConfigHomeUnavailable;
    defer sayall_darwin_free(home);
    try @constCast(env).put("HOME", std.mem.span(home));
}

fn write(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    if (bytes.len != 0) try file.writeStreamingAll(io, bytes);
}

fn writePresentation(io: std.Io, presentation: cli.Presentation) !u8 {
    try write(io, .stdout(), presentation.stdout);
    try write(io, .stderr(), presentation.stderr);
    return presentation.exit_code;
}
