const std = @import("std");

pub const help =
    \\sayall — voice dictation
    \\
    \\usage:
    \\  sayall help           show this help
    \\  sayall version        print the installed version
    \\  sayall status         print recording state
    \\  sayall toggle         toggle recording
    \\  sayall reload         reload configuration
    \\  sayall config init    securely create the default configuration
    \\  sayall config validate [--json]
    \\  sayall transcribe <WAV> [--raw] [--json]
    \\  sayall doctor [--json]
    \\  sayall update
    \\
;

pub const Command = enum { help, version, status, toggle, reload, config_init, config_validate, config_validate_json, doctor, doctor_json, update };
pub const ParseError = error{InvalidArguments};

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len == 0) return error.InvalidArguments;
    if (args.len == 1) {
        const arg = args[0];
        if (std.mem.eql(u8, arg, "help") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .help;
        if (std.mem.eql(u8, arg, "version") or std.mem.eql(u8, arg, "--version")) return .version;
        if (std.mem.eql(u8, arg, "status")) return .status;
        if (std.mem.eql(u8, arg, "toggle")) return .toggle;
        if (std.mem.eql(u8, arg, "reload")) return .reload;
        if (std.mem.eql(u8, arg, "doctor")) return .doctor;
        if (std.mem.eql(u8, arg, "update")) return .update;
    }
    if (args.len == 2 and std.mem.eql(u8, args[0], "config") and std.mem.eql(u8, args[1], "init")) return .config_init;
    if (args.len == 2 and std.mem.eql(u8, args[0], "config") and std.mem.eql(u8, args[1], "validate")) return .config_validate;
    if (args.len == 3 and std.mem.eql(u8, args[0], "config") and std.mem.eql(u8, args[1], "validate") and std.mem.eql(u8, args[2], "--json")) return .config_validate_json;
    if (args.len == 2 and std.mem.eql(u8, args[0], "doctor") and std.mem.eql(u8, args[1], "--json")) return .doctor_json;
    return error.InvalidArguments;
}

pub const HostOutcome = union(enum) {
    idle,
    starting,
    recording,
    stopping,
    processing,
    delivering,
    success,
    host_error,
    cancelled,
    busy: []const u8,
    operation_error: []const u8,
    transport_error: []const u8,
    incompatible: []const u8,
    unavailable,
};
pub const HostControl = struct {
    context: *anyopaque,
    statusFn: *const fn (*anyopaque) HostOutcome,
    toggleFn: *const fn (*anyopaque) HostOutcome,
    reloadFn: *const fn (*anyopaque) HostOutcome,

    pub fn status(self: HostControl) HostOutcome {
        return self.statusFn(self.context);
    }
    pub fn toggle(self: HostControl) HostOutcome {
        return self.toggleFn(self.context);
    }
    pub fn reload(self: HostControl) HostOutcome {
        return self.reloadFn(self.context);
    }
};

pub fn updateAllowed(outcome: HostOutcome) bool {
    return outcome == .idle;
}

pub const Presentation = struct { exit_code: u8, stdout: []const u8 = "", stderr: []const u8 = "" };

pub const usage_presentation: Presentation = .{ .exit_code = 2, .stderr = help };
pub const invalid_presentation: Presentation = .{
    .exit_code = 2,
    .stderr = "sayall: invalid arguments\n" ++ help,
};

pub fn execute(command: Command, version: []const u8, host: HostControl) Presentation {
    return switch (command) {
        .help => .{ .exit_code = 0, .stdout = help },
        .version => .{ .exit_code = 0, .stdout = version },
        .status => present(host.status()),
        .toggle => present(host.toggle()),
        .reload => presentReload(host.reload()),
        .config_init, .config_validate, .config_validate_json, .doctor, .doctor_json, .update => unreachable,
    };
}

fn presentReload(result: HostOutcome) Presentation {
    return if (result == .idle)
        .{ .exit_code = 0, .stdout = "Configuration reloaded.\n" }
    else
        present(result);
}

fn present(result: HostOutcome) Presentation {
    return switch (result) {
        .idle => .{ .exit_code = 0, .stdout = "idle\n" },
        .starting => .{ .exit_code = 0, .stdout = "starting\n" },
        .recording => .{ .exit_code = 0, .stdout = "recording\n" },
        .stopping => .{ .exit_code = 0, .stdout = "stopping\n" },
        .processing => .{ .exit_code = 0, .stdout = "processing\n" },
        .delivering => .{ .exit_code = 0, .stdout = "delivering\n" },
        .success => .{ .exit_code = 0, .stdout = "success\n" },
        .host_error => .{ .exit_code = 0, .stdout = "error\n" },
        .cancelled => .{ .exit_code = 0, .stdout = "cancelled\n" },
        .busy, .operation_error => |reply| .{ .exit_code = 1, .stdout = reply },
        .transport_error => |diagnostic| .{ .exit_code = 1, .stderr = diagnostic },
        .incompatible => |reply| .{ .exit_code = 1, .stderr = reply },
        .unavailable => .{ .exit_code = 1, .stderr = "sayall: host control is unavailable on this platform\n" },
    };
}

const Fake = struct {
    result: HostOutcome,
    status_calls: usize = 0,
    toggle_calls: usize = 0,
    reload_calls: usize = 0,
    fn status(ctx: *anyopaque) HostOutcome {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.status_calls += 1;
        return self.result;
    }
    fn toggle(ctx: *anyopaque) HostOutcome {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.toggle_calls += 1;
        return self.result;
    }
    fn reload(ctx: *anyopaque) HostOutcome {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.reload_calls += 1;
        return self.result;
    }
    fn adapter(self: *Fake) HostControl {
        return .{ .context = self, .statusFn = status, .toggleFn = toggle, .reloadFn = reload };
    }
};

test "canonical grammar accepts only exact commands" {
    try std.testing.expectEqual(Command.help, try parse(&.{"-h"}));
    try std.testing.expectEqual(Command.help, try parse(&.{"--help"}));
    try std.testing.expectEqual(Command.version, try parse(&.{"--version"}));
    try std.testing.expectEqual(Command.reload, try parse(&.{"reload"}));
    try std.testing.expectEqual(Command.config_init, try parse(&.{ "config", "init" }));
    try std.testing.expectEqual(Command.config_validate, try parse(&.{ "config", "validate" }));
    try std.testing.expectEqual(Command.config_validate_json, try parse(&.{ "config", "validate", "--json" }));
    try std.testing.expectEqual(Command.doctor, try parse(&.{"doctor"}));
    try std.testing.expectEqual(Command.doctor_json, try parse(&.{ "doctor", "--json" }));
    try std.testing.expectEqual(Command.update, try parse(&.{"update"}));
    for ([_][]const []const u8{ &.{}, &.{ "status", "extra" }, &.{"start"}, &.{"stop"}, &.{"config"}, &.{ "config", "init", "extra" }, &.{ "config", "validate", "--raw" }, &.{ "doctor", "--raw" }, &.{ "update", "extra" } }) |args|
        try std.testing.expectError(error.InvalidArguments, parse(args));
}

test "help contains only the canonical public surface" {
    for ([_][]const u8{ " daemon", " service", " setup", " restart", " stop", " start" }) |hidden|
        try std.testing.expect(std.mem.indexOf(u8, help, hidden) == null);
    try std.testing.expect(std.mem.indexOf(u8, help, " transcribe") != null);
}

test "canonical usage and invalid presentations are stable" {
    try std.testing.expectEqual(@as(u8, 2), usage_presentation.exit_code);
    try std.testing.expectEqualStrings("", usage_presentation.stdout);
    try std.testing.expectEqualStrings(help, usage_presentation.stderr);

    try std.testing.expectEqual(@as(u8, 2), invalid_presentation.exit_code);
    try std.testing.expectEqualStrings("", invalid_presentation.stdout);
    try std.testing.expectEqualStrings("sayall: invalid arguments\n" ++ help, invalid_presentation.stderr);
}

test "malformed canonical arguments use the canonical invalid presentation" {
    for ([_][]const []const u8{
        &.{"unknown"},
        &.{"config"},
        &.{ "status", "extra" },
        &.{ "config", "init", "extra" },
        &.{ "help", "extra" },
        &.{ "version", "extra" },
    }) |args| {
        try std.testing.expectError(error.InvalidArguments, parse(args));
        try std.testing.expectEqual(@as(u8, 2), invalid_presentation.exit_code);
        try std.testing.expectEqualStrings(help, invalid_presentation.stderr["sayall: invalid arguments\n".len..]);
    }
}

test "typed adapters have identical presentation and one operation" {
    const cases = [_]HostOutcome{ .idle, .recording, .stopping, .processing, .{ .busy = "busy: processing\n" }, .{ .operation_error = "error: failed\n" }, .{ .transport_error = "socket: refused\n" }, .{ .incompatible = "bad reply\n" }, .unavailable };
    for (cases) |value| {
        var linux = Fake{ .result = value };
        var darwin = Fake{ .result = value };
        const a = execute(.toggle, "unused", linux.adapter());
        const b = execute(.toggle, "unused", darwin.adapter());
        try std.testing.expectEqual(a.exit_code, b.exit_code);
        try std.testing.expectEqualStrings(a.stdout, b.stdout);
        try std.testing.expectEqualStrings(a.stderr, b.stderr);
        try std.testing.expectEqual(@as(usize, 1), linux.toggle_calls);
        try std.testing.expectEqual(@as(usize, 0), linux.status_calls);
    }
    var status_fake = Fake{ .result = .idle };
    _ = execute(.status, "unused", status_fake.adapter());
    try std.testing.expectEqual(@as(usize, 1), status_fake.status_calls);
    try std.testing.expectEqual(@as(usize, 0), status_fake.toggle_calls);

    var reload_fake = Fake{ .result = .idle };
    const reloaded = execute(.reload, "unused", reload_fake.adapter());
    try std.testing.expectEqualStrings("Configuration reloaded.\n", reloaded.stdout);
    try std.testing.expectEqual(@as(usize, 1), reload_fake.reload_calls);
}

test "updates require an idle native host" {
    try std.testing.expect(updateAllowed(.idle));
    try std.testing.expect(!updateAllowed(.recording));
    try std.testing.expect(!updateAllowed(.processing));
    try std.testing.expect(!updateAllowed(.unavailable));
}

test "deployed host outcomes preserve stdout stderr and exit contracts" {
    const cases = [_]struct { outcome: HostOutcome, code: u8, out: []const u8, err: []const u8 }{
        .{ .outcome = .idle, .code = 0, .out = "idle\n", .err = "" },
        .{ .outcome = .recording, .code = 0, .out = "recording\n", .err = "" },
        .{ .outcome = .stopping, .code = 0, .out = "stopping\n", .err = "" },
        .{ .outcome = .processing, .code = 0, .out = "processing\n", .err = "" },
        .{ .outcome = .{ .busy = "busy: daemon is not idle\n" }, .code = 1, .out = "busy: daemon is not idle\n", .err = "" },
        .{ .outcome = .{ .operation_error = "error: could not stop recording\n" }, .code = 1, .out = "error: could not stop recording\n", .err = "" },
        .{ .outcome = .{ .transport_error = "sayall: cannot reach daemon (ConnectionRefused)\n" }, .code = 1, .out = "", .err = "sayall: cannot reach daemon (ConnectionRefused)\n" },
    };
    for (cases) |case| {
        const actual = present(case.outcome);
        try std.testing.expectEqual(case.code, actual.exit_code);
        try std.testing.expectEqualStrings(case.out, actual.stdout);
        try std.testing.expectEqualStrings(case.err, actual.stderr);
    }
}
