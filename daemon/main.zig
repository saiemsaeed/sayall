const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const cli = @import("cli.zig");
const cli_config_validate = @import("cli_config_validate.zig");
const cli_doctor = @import("cli_doctor.zig");
const cli_transcribe = @import("cli_transcribe.zig");
const host_control = @import("host_control.zig");
const config = @import("config.zig");
const keywords = @import("keywords.zig");
const ipc = @import("ipc.zig");
const metrics = @import("metrics.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const events = @import("events.zig");
const recorder = @import("recorder.zig");
const protocol = @import("protocol.zig");
const product_module = @import("product.zig");
const product = product_module.Integration;
const product_contract = product_module.contracts;
const deepgram = @import("stt/deepgram.zig");
const deepgram_stream = @import("stt/deepgram_stream.zig");
const groq = @import("llm/groq.zig");

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("sayall: fatal: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const env = init.environ_map;

    const argv = init.minimal.args.vector;
    if (argv.len < 2) {
        return writePresentation(io, cli.usage_presentation);
    }

    const cmd = std.mem.span(argv[1]);

    const canonical_candidate = std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or
        std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "version") or
        std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "status") or std.mem.eql(u8, cmd, "reload") or std.mem.eql(u8, cmd, "doctor") or std.mem.eql(u8, cmd, "update") or
        (std.mem.eql(u8, cmd, "toggle") and !(argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "--raw"))) or
        std.mem.eql(u8, cmd, "config");
    if (canonical_candidate) {
        var args: [3][]const u8 = undefined;
        if (argv.len - 1 > args.len) return writePresentation(io, cli.invalid_presentation);
        for (argv[1..], 0..) |arg, index| args[index] = std.mem.span(arg);
        const command = cli.parse(args[0 .. argv.len - 1]) catch return writePresentation(io, cli.invalid_presentation);
        if (command == .config_init) {
            const path = config.initDefault(arena, io, env) catch |err| {
                std.debug.print("sayall: cannot initialize configuration ({s})\n", .{@errorName(err)});
                return if (err == error.PathAlreadyExists) 1 else 1;
            };
            try printLine(io, try std.fmt.allocPrint(arena, "Created {s}", .{path}));
            return 0;
        }
        if (command == .config_validate or command == .config_validate_json) {
            return cli_config_validate.run(arena, io, env, command == .config_validate_json);
        }
        if (command == .doctor or command == .doctor_json) {
            var doctor_host: host_control.Linux = .{ .arena = arena, .io = io, .env = env };
            var platform_items: [8]product_contract.Diagnostic = undefined;
            var platform_len: usize = 0;
            platform_items[platform_len] = product.environmentDiagnostic(env) catch |err| .{ .status = .fail, .label = "Environment", .detail = @errorName(err) };
            platform_len += 1;
            const loaded = if (cli_doctor.configPathSafe(arena, io, env)) config.loadReadOnly(arena, io, env) catch null else null;
            const platform_diagnostics = product.diagnostics(arena, io, env, if (loaded) |cfg| cfg.notifications else null, if (loaded) |cfg| cfg.output.method else null) catch |err| {
                platform_items[platform_len] = .{ .status = .fail, .label = "Platform diagnostics", .detail = @errorName(err) };
                platform_len += 1;
                return cli_doctor.run(arena, io, env, doctor_host.adapter(), build_options.version, command == .doctor_json, platform_items[0..platform_len]);
            };
            for (platform_diagnostics.commands) |item| {
                platform_items[platform_len] = item;
                platform_len += 1;
            }
            if (platform_diagnostics.notification) |item| {
                platform_items[platform_len] = item;
                platform_len += 1;
            }
            for (platform_diagnostics.services) |item| {
                platform_items[platform_len] = item;
                platform_len += 1;
            }
            return cli_doctor.run(arena, io, env, doctor_host.adapter(), build_options.version, command == .doctor_json, platform_items[0..platform_len]);
        }
        // Linux update remains in the product-specific implementation below.
        if (command == .update) {
            // Continue after the canonical parser has established exact grammar.
        } else {
            var linux_host: host_control.Linux = .{ .arena = arena, .io = io, .env = env };
            const version = "sayall " ++ build_options.version ++ "\n";
            const result = cli.execute(command, version, linux_host.adapter());
            try writeOutput(io, .stdout(), result.stdout);
            try writeOutput(io, .stderr(), result.stderr);
            return result.exit_code;
        }
    }

    if (std.mem.eql(u8, cmd, "restart")) {
        if (argv.len != 2) return invalidArguments("restart");
        switch (product.restart(io) catch |err| return productError("restart", err)) {
            .restarted => {},
            .spawn_failed => |err| {
                std.debug.print("sayall: could not run systemctl ({s})\n", .{@errorName(err)});
                return 1;
            },
            .wait_failed => |err| {
                std.debug.print("sayall: could not restart service ({s})\n", .{@errorName(err)});
                return 1;
            },
            .failed => return 1,
        }
        try printLine(io, "SayAll restarted; configuration reloaded.");
        return 0;
    }

    if (std.mem.eql(u8, cmd, "setup")) {
        if (argv.len != 2) return invalidArguments("setup");
        const result = product.setup(arena, io, env, reportShortcutResult) catch |err| return productError("setup", err);
        if (!result.services_ok) {
            std.debug.print("sayall: could not configure the systemd user host service\n", .{});
            return 1;
        }
        if (!waitForLinuxHost(arena, io, env)) {
            std.debug.print("sayall: the systemd user host service started but did not become ready\n", .{});
            return 1;
        }
        if (!result.shortcut_ok) {
            std.debug.print("sayall: the host service was enabled and restarted, but shortcut setup is incomplete; resolve the error above and retry 'sayall setup'.\n", .{});
            return 1;
        }
        try printLine(io, "SayAll host service enabled and restarted.");
        return 0;
    }

    if (std.mem.eql(u8, cmd, "update")) {
        if (argv.len != 2) return invalidArguments("update");
        var update_host: host_control.Linux = .{ .arena = arena, .io = io, .env = env };
        if (!cli.updateAllowed(update_host.adapter().status())) {
            std.debug.print("sayall: cannot update unless the native host is reachable and idle\n", .{});
            return 1;
        }
        const preparation = product.prepareUpdate(arena, io) catch |err| return productError("update", err);
        const package = switch (preparation) {
            .package_missing => {
                std.debug.print("sayall: update requires an installed AUR package (sayall, sayall-bin, or sayall-git; legacy sayall-src is also recognized)\n", .{});
                return 1;
            },
            .yay_missing => {
                std.debug.print("sayall: update requires the 'yay' AUR helper\n", .{});
                return 1;
            },
            .ready => |plan| plan,
        };
        if (package.legacy_migration) {
            try printLine(io, try std.fmt.allocPrint(arena, "Migrating legacy {s} installation to {s} with yay...", .{ package.installed, package.update_target }));
        } else {
            try printLine(io, try std.fmt.allocPrint(arena, "Checking/updating {s} with yay...", .{package.installed}));
        }
        switch (product.finishUpdate(arena, io, env, package) catch |err| return productError("update", err)) {
            .package_failed => {
                std.debug.print("sayall: package update failed; the host service was not restarted\n", .{});
                return 1;
            },
            .services_failed => {
                std.debug.print("sayall: yay completed successfully, but the systemd user host service could not be restarted\n", .{});
                return 1;
            },
            .shortcut => |result| if (!try reportShortcutResult(arena, io, result)) {
                std.debug.print("sayall: package updated and the host service restarted, but the saved shortcut could not be applied\n", .{});
                return 1;
            },
        }
        try printLine(io, "yay completed successfully; SayAll host service enabled and restarted.");
        return 0;
    }

    if (std.mem.eql(u8, cmd, "shortcut")) {
        return shortcutCommand(arena, io, env, argv);
    }

    if (std.mem.eql(u8, cmd, "doctor")) {
        if (argv.len != 2) return invalidArguments("doctor");
        return doctor(arena, io, env);
    }

    if (std.mem.eql(u8, cmd, "keyword") or std.mem.eql(u8, cmd, "keywords")) {
        return keywordCommand(arena, io, env, argv[2..]);
    }

    if (std.mem.eql(u8, cmd, "transcribe")) {
        var values: [3][]const u8 = undefined;
        if (argv.len < 3 or argv.len > 5) return invalidArguments("transcribe");
        for (argv[2..], 0..) |arg, i| values[i] = std.mem.span(arg);
        const options = cli_transcribe.parse(values[0 .. argv.len - 2]) catch return invalidArguments("transcribe");
        return cli_transcribe.run(gpa, arena, io, env, options);
    }

    if (std.mem.eql(u8, cmd, "stats")) {
        if (argv.len > 3) return invalidArguments("stats");
        const as_json = argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "--json");
        if (argv.len == 3 and !as_json) return invalidArguments("stats");
        const cfg = try config.load(arena, io, env);
        const metrics_path = try paths.PersistentState.metrics(arena, env);
        const store = metrics.Store.init(metrics_path, cfg.metrics.history_max_entries);
        const summary = try store.summary(gpa, io);
        if (as_json) {
            const json = try std.json.Stringify.valueAlloc(arena, summary, .{});
            try printLine(io, json);
        } else {
            try printStats(io, summary);
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "mic-test")) {
        if (argv.len > 3) return invalidArguments("mic-test");
        const requested_source: ?[]const u8 = if (argv.len == 3) std.mem.span(argv[2]) else null;
        const cfg = try config.load(arena, io, env);
        const source = requested_source orelse cfg.recording.source;
        const runtime = try paths.Runtime.discover(arena, env);
        var mic_recorder: platform.Recorder = .{};
        try printLine(io, try std.fmt.allocPrint(arena, "Source: {s}", .{
            if (source.len == 0) "OS default" else source,
        }));
        try printLine(io, "Speak normally for 3 seconds...");
        _ = try mic_recorder.start(gpa, io, runtime.scratch_dir, source);
        std.Io.sleep(io, .fromSeconds(3), .awake) catch {};
        const recording = try mic_recorder.stop(io);
        defer {
            Io.Dir.deleteFileAbsolute(io, recording.path) catch {};
            gpa.free(recording.path);
        }
        const wav = try Io.Dir.cwd().readFileAlloc(io, recording.path, arena, .limited(32 * 1024 * 1024));
        const levels = try recorder.analyzePcmS16(wav);
        const verdict = if (levels.peak == 0)
            "SILENCE: no signal from the selected source"
        else if (levels.peak < 500)
            "VERY QUIET: raise microphone gain"
        else
            "OK: microphone signal detected";
        try printLine(io, try std.fmt.allocPrint(arena, "peak={d}/32768, rms={d:.1} - {s}", .{
            levels.peak, levels.rms, verdict,
        }));
        return 0;
    }

    return writePresentation(io, cli.invalid_presentation);
}

fn waitForLinuxHost(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) bool {
    var host: host_control.Linux = .{ .arena = arena, .io = io, .env = env };
    for (0..40) |attempt| {
        if (hostReady(host.adapter().status())) return true;
        if (attempt < 39) std.Io.sleep(io, .fromMilliseconds(50), .awake) catch return false;
    }
    return false;
}

fn hostReady(outcome: cli.HostOutcome) bool {
    return switch (outcome) {
        .idle, .starting, .recording, .stopping, .processing, .delivering, .success, .host_error, .cancelled, .busy, .operation_error => true,
        .transport_error, .incompatible, .unavailable => false,
    };
}

fn flag(value: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, value, long) or std.mem.eql(u8, value, short);
}

fn keywordCommand(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, raw_args: []const [*:0]const u8) !u8 {
    const keywords_path = try paths.Config.keywords(arena, env) orelse {
        std.debug.print("sayall: keyword storage requires XDG_CONFIG_HOME or HOME\n", .{});
        return 1;
    };
    const store = keywords.Store.init(keywords_path);
    if (raw_args.len == 0) return invalidArguments("keywords");
    const action = std.mem.span(raw_args[0]);

    if (std.mem.eql(u8, action, "list")) {
        if (raw_args.len != 1) return invalidArguments("keywords list");
        const legacy = loadKeywordFallback(arena, io, env, store) catch |err| return keywordError(err, null);
        const values = store.loadOrMigrate(arena, io, legacy) catch |err| return keywordError(err, null);
        return printKeywords(io, values, "No keywords configured.");
    }

    if (std.mem.eql(u8, action, "search")) {
        if (raw_args.len != 2) return invalidArguments("keywords search");
        const query = std.mem.span(raw_args[1]);
        if (query.len == 0) {
            std.debug.print("sayall: search text must not be empty\n", .{});
            return 2;
        }
        const legacy = loadKeywordFallback(arena, io, env, store) catch |err| return keywordError(err, null);
        const values = store.loadOrMigrate(arena, io, legacy) catch |err| return keywordError(err, null);
        var matches: std.ArrayList([]const u8) = .empty;
        for (values) |value| {
            if (containsAsciiIgnoreCase(value, query)) try matches.append(arena, value);
        }
        return printKeywords(io, matches.items, "No matching keywords.");
    }

    if (std.mem.eql(u8, action, "add")) {
        if (raw_args.len < 2) return invalidArguments("keywords add");
        const legacy = loadKeywordFallback(arena, io, env, store) catch |err| return keywordError(err, null);
        const additions = try arena.alloc([]const u8, raw_args.len - 1);
        for (raw_args[1..], 0..) |arg, index| additions[index] = std.mem.span(arg);
        const updated = store.add(arena, io, legacy, additions) catch |err| return keywordError(err, null);
        try printLine(io, try std.fmt.allocPrint(arena, "Added {d} keyword(s); {d} configured.", .{ additions.len, updated.len }));
        try keywordReloadInstruction(io);
        return 0;
    }

    if (std.mem.eql(u8, action, "update") or std.mem.eql(u8, action, "rename")) {
        if (raw_args.len != 3) return invalidArguments("keywords update");
        const legacy = loadKeywordFallback(arena, io, env, store) catch |err| return keywordError(err, null);
        const old = std.mem.span(raw_args[1]);
        const replacement = std.mem.span(raw_args[2]);
        _ = store.rename(arena, io, legacy, old, replacement) catch |err|
            return keywordError(err, if (err == error.DuplicateKeyword) replacement else old);
        try printLine(io, "Keyword updated.");
        try keywordReloadInstruction(io);
        return 0;
    }

    if (std.mem.eql(u8, action, "delete")) {
        if (raw_args.len != 2) return invalidArguments("keywords delete");
        const legacy = loadKeywordFallback(arena, io, env, store) catch |err| return keywordError(err, null);
        const value = std.mem.span(raw_args[1]);
        const updated = store.delete(arena, io, legacy, value) catch |err| return keywordError(err, value);
        try printLine(io, try std.fmt.allocPrint(arena, "Keyword deleted; {d} configured.", .{updated.len}));
        try keywordReloadInstruction(io);
        return 0;
    }

    if (std.mem.eql(u8, action, "clear")) {
        if (raw_args.len != 2 or !std.mem.eql(u8, std.mem.span(raw_args[1]), "--confirm")) {
            std.debug.print("sayall: refusing to clear keywords without: sayall keywords clear --confirm\n", .{});
            return 2;
        }
        store.clear(arena, io) catch |err| return keywordError(err, null);
        try printLine(io, "All keywords cleared.");
        try keywordReloadInstruction(io);
        return 0;
    }

    return invalidArguments("keywords");
}

fn loadKeywordFallback(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, store: keywords.Store) ![]const []const u8 {
    // Once keywords.json exists it is the only source of truth, so an
    // unrelated or subsequently broken config.json cannot affect keyword CRUD.
    if (try store.load(arena, io) != null) return &.{};
    return config.loadLegacyKeyterms(arena, io, env);
}

fn printKeywords(io: Io, values: []const []const u8, empty_message: []const u8) !u8 {
    if (values.len == 0) {
        try printLine(io, empty_message);
        return 0;
    }
    for (values) |value| try printLine(io, value);
    return 0;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var offset: usize = 0;
    while (offset + needle.len <= haystack.len) : (offset += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[offset .. offset + needle.len], needle)) return true;
    }
    return false;
}

fn keywordError(err: anyerror, value: ?[]const u8) u8 {
    const message: []const u8 = switch (err) {
        error.EmptyKeyword => "keywords must not be empty",
        error.KeywordTooLong => "each keyword must be at most 256 bytes",
        error.InvalidUtf8 => "keywords must be valid UTF-8",
        error.ControlCharacter => "keywords must not contain control characters",
        error.DuplicateKeyword => "that exact keyword is already configured",
        error.TooManyKeywords => "at most 100 keywords may be configured",
        error.KeywordsTooLarge => "keywords must not exceed 4096 bytes in total",
        error.KeywordNotFound => "keyword not found (matching is exact)",
        error.UnsupportedKeywordFileVersion => "unsupported keywords file version",
        else => @errorName(err),
    };
    if (value) |keyword| {
        std.debug.print("sayall: {s}: {s}\n", .{ message, keyword });
    } else {
        std.debug.print("sayall: {s}\n", .{message});
    }
    return 1;
}

fn keywordReloadInstruction(io: Io) !void {
    try printLine(io, "Run 'sayall reload' to apply keyword changes to the running application.");
}

fn invalidArguments(command: []const u8) u8 {
    std.debug.print("sayall: invalid arguments for '{s}'\n", .{command});
    usage();
    return 2;
}

fn productError(command: []const u8, err: anyerror) anyerror!u8 {
    if (err != error.UnsupportedPlatform) return err;
    std.debug.print("sayall: '{s}' is unsupported on this platform\n", .{command});
    return 1;
}

fn printLine(io: Io, text: []const u8) !void {
    const stdout: Io.File = .stdout();
    var buf: [256]u8 = undefined;
    var w = stdout.writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

fn writeOutput(io: Io, file: Io.File, text: []const u8) !void {
    if (text.len == 0) return;
    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn writePresentation(io: Io, presentation: cli.Presentation) !u8 {
    try writeOutput(io, .stdout(), presentation.stdout);
    try writeOutput(io, .stderr(), presentation.stderr);
    return presentation.exit_code;
}

fn shortcutCommand(
    arena: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    argv: []const [*:0]const u8,
) !u8 {
    if (argv.len == 2 or (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "show"))) {
        const result = product.shortcut(arena, io, env, .show) catch |err| {
            if (err == error.UnsupportedPlatform) return productError("shortcut", err);
            std.debug.print("sayall: cannot read shortcut state ({s})\n", .{@errorName(err)});
            return 1;
        };
        const state = result.state;
        if (state.external) {
            try printLine(io, try std.fmt.allocPrint(arena, "SayAll shortcut: {s} (existing external binding)", .{state.shortcut}));
        } else if (state.enabled) {
            try printLine(io, try std.fmt.allocPrint(arena, "SayAll shortcut: {s}{s}", .{
                state.shortcut,
                if (state.persisted) "" else " (default; run 'sayall setup' to activate)",
            }));
        } else {
            try printLine(io, try std.fmt.allocPrint(arena, "SayAll shortcut: disabled (saved shortcut: {s})", .{state.shortcut}));
        }
        return 0;
    }

    if (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "disable")) {
        return presentShortcutCommand(arena, io, product.shortcut(arena, io, env, .disable) catch |err| return productError("shortcut", err));
    }

    if (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "reset")) {
        return presentShortcutCommand(arena, io, product.shortcut(arena, io, env, .reset) catch |err| return productError("shortcut", err));
    }

    if ((argv.len == 4 or argv.len == 5) and std.mem.eql(u8, std.mem.span(argv[2]), "set")) {
        const requested = if (argv.len == 4)
            std.mem.span(argv[3])
        else
            try std.fmt.allocPrint(arena, "{s}+{s}", .{ std.mem.span(argv[3]), std.mem.span(argv[4]) });
        return presentShortcutCommand(arena, io, product.shortcut(arena, io, env, .{ .set = requested }) catch |err| return productError("shortcut", err));
    }

    return invalidArguments("shortcut");
}

fn presentShortcutCommand(arena: std.mem.Allocator, io: Io, result: product_contract.ShortcutResult) !u8 {
    return switch (result) {
        .applied => |applied| if (try reportShortcutResult(arena, io, applied)) 0 else 1,
        .invalid => |requested| blk: {
            std.debug.print("sayall: invalid shortcut '{s}'; use a chord such as CTRL+SLASH, SUPER+SPACE, or F9\n", .{requested});
            break :blk 2;
        },
        .state => unreachable,
    };
}

fn externalShortcutRequiresMigration(value: []const u8) u8 {
    std.debug.print("sayall: {s} is owned by an existing manual Hyprland binding; remove that 'sayall toggle' line before using 'sayall shortcut set' or 'sayall shortcut disable'. No files were changed.\n", .{value});
    return 1;
}

fn reportShortcutResult(arena: std.mem.Allocator, io: Io, result: product_contract.ShortcutApplyResult) !bool {
    switch (result) {
        .applied => |applied| {
            if (applied.state.enabled) {
                try printLine(io, try std.fmt.allocPrint(arena, "SayAll shortcut {s}: {s}.", .{
                    if (applied.changed) "configured" else "already configured",
                    applied.state.shortcut,
                }));
            } else {
                try printLine(io, try std.fmt.allocPrint(arena, "SayAll shortcut {s}.", .{
                    if (applied.changed) "disabled" else "already disabled",
                }));
            }
            if (applied.activation == .deferred) {
                std.debug.print("sayall: Hyprland is not active; the saved shortcut will load next session. To activate it now, run 'hyprctl reload' inside Hyprland.\n", .{});
            }
            return true;
        },
        .external => |state| {
            try printLine(io, try std.fmt.allocPrint(arena, "SayAll shortcut already configured externally: {s}; leaving the existing binding unchanged.", .{state.shortcut}));
            return true;
        },
        .external_owned => |state| {
            _ = externalShortcutRequiresMigration(state.shortcut);
            return false;
        },
        .conflict => |conflict| {
            std.debug.print(
                "sayall: shortcut conflicts with {s}:{d}:\n  {s}\nChoose another with 'sayall shortcut set <MODIFIERS+KEY>', remove that binding, or run 'sayall shortcut disable'; no files were changed.\n",
                .{ conflict.path, conflict.line, conflict.binding },
            );
            return false;
        },
        .unresolved => |unresolved| {
            std.debug.print(
                "sayall: cannot safely inspect unresolved Hyprland expression at {s}:{d}:\n  {s}\nReplace the variable-based source/modifier/key with a literal value before managing the SayAll shortcut. No files were changed.\n",
                .{ unresolved.path, unresolved.line, unresolved.expression },
            );
            return false;
        },
        .unsupported => |path| {
            std.debug.print("sayall: Hyprland configuration not found at {s}; create the Omarchy/Hyprland config first, then retry. No files were changed.\n", .{path});
            return false;
        },
        .unsafe_root => |path| {
            std.debug.print("sayall: refusing to manage shortcut because {s} is not a regular file (symlinked Hyprland roots are unsupported). Replace it with a regular file and retry. No files were changed.\n", .{path});
            return false;
        },
        .concurrent_modification => |path| {
            std.debug.print("sayall: {s} changed during shortcut setup; SayAll stopped and rolled back transaction files that still matched its writes. Review the concurrent edit and retry.\n", .{path});
            return false;
        },
        .reload_failed => |reason| {
            std.debug.print("sayall: Hyprland could not safely activate the shortcut ({s}); the previous shortcut files were restored. Run 'hyprctl configerrors', fix any reported errors, and retry.\n", .{reason});
            return false;
        },
        .rollback_failed => |reason| {
            if (reason == .concurrent_modification) {
                std.debug.print("sayall: shortcut activation failed and SayAll could not safely restore every transaction file because at least one file changed concurrently. SayAll did not overwrite the concurrent content; inspect hyprland.conf, sayall.conf, and shortcut.json before retrying.\n", .{});
            } else {
                std.debug.print("sayall: shortcut activation failed and an I/O error prevented complete rollback. Inspect hyprland.conf, sayall.conf, and shortcut.json before retrying; SayAll cannot confirm restoration.\n", .{});
            }
            return false;
        },
    }
}

fn doctor(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !u8 {
    var failures: u8 = 0;
    var warnings: u8 = 0;
    try printLine(io, "SayAll diagnostics");

    const exe = try std.process.executablePathAlloc(io, arena);
    try diagnostic(arena, io, "ok", "Version", "sayall " ++ build_options.version);
    try diagnostic(arena, io, "ok", "Executable", exe);

    const environment_diagnostic = product.environmentDiagnostic(env) catch |err| return productError("doctor", err);
    try presentDiagnostic(arena, io, environment_diagnostic, &failures, &warnings);

    var loaded_config: ?config.Config = null;
    const cfg_path = try paths.Config.file(arena, env);
    if (cfg_path) |path| {
        if (Io.Dir.cwd().statFile(io, path, .{})) |stat| {
            try diagnostic(arena, io, "ok", "Configuration", path);
            if (stat.permissions.toMode() & 0o077 == 0) {
                try diagnostic(arena, io, "ok", "Config permissions", "private");
            } else {
                warnings += 1;
                try diagnostic(arena, io, "warn", "Config permissions", try std.fmt.allocPrint(arena, "restrict {s} to mode 0600", .{path}));
            }
        } else |err| switch (err) {
            error.FileNotFound => {
                warnings += 1;
                try diagnostic(arena, io, "warn", "Configuration", "config.json is absent; checking environment credentials");
            },
            else => {
                failures += 1;
                try diagnostic(arena, io, "fail", "Configuration", @errorName(err));
            },
        }

        if (config.loadReadOnly(arena, io, env)) |cfg| {
            loaded_config = cfg;
            if (cfg.stt.api_key.len > 0) {
                try diagnostic(arena, io, "ok", "Deepgram credentials", "configured");
            } else {
                failures += 1;
                try diagnostic(arena, io, "fail", "Deepgram credentials", "missing API key");
            }
            if (cfg.llm.enabled and cfg.llm.api_key.len == 0) {
                warnings += 1;
                try diagnostic(arena, io, "warn", "Groq credentials", "cleanup is enabled but its API key is missing");
            } else {
                try diagnostic(arena, io, "ok", "Groq cleanup", if (cfg.llm.enabled) "configured" else "disabled");
            }
        } else |err| {
            failures += 1;
            try diagnostic(arena, io, "fail", "Config validation", @errorName(err));
        }
    } else {
        failures += 1;
        try diagnostic(arena, io, "fail", "Configuration", "HOME and XDG_CONFIG_HOME are unavailable");
    }

    const platform_diagnostics = product.diagnostics(arena, io, env, if (loaded_config) |cfg| cfg.notifications else null, if (loaded_config) |cfg| cfg.output.method else null) catch |err|
        return productError("doctor", err);
    for (platform_diagnostics.commands) |item|
        try presentDiagnostic(arena, io, item, &failures, &warnings);
    if (platform_diagnostics.notification) |item|
        try presentDiagnostic(arena, io, item, &failures, &warnings);
    for (platform_diagnostics.services) |item|
        try presentDiagnostic(arena, io, item, &failures, &warnings);

    const runtime = try paths.Runtime.discover(arena, env);
    if (ipc.sendCommand(arena, io, runtime.endpoint, "status")) |reply| {
        try diagnostic(arena, io, "ok", "Daemon", reply);
    } else |err| {
        failures += 1;
        try diagnostic(arena, io, "fail", "Daemon", try std.fmt.allocPrint(arena, "cannot reach {s} ({s})", .{ runtime.endpoint.path, @errorName(err) }));
    }

    try printLine(io, try std.fmt.allocPrint(arena, "Result: {d} failure(s), {d} warning(s)", .{ failures, warnings }));
    return if (failures == 0) 0 else 1;
}

fn presentDiagnostic(
    arena: std.mem.Allocator,
    io: Io,
    item: product_contract.Diagnostic,
    failures: *u8,
    warnings: *u8,
) !void {
    const status = switch (item.status) {
        .ok => "ok",
        .warn => blk: {
            warnings.* += 1;
            break :blk "warn";
        },
        .fail => blk: {
            failures.* += 1;
            break :blk "fail";
        },
    };
    try diagnostic(arena, io, status, item.label, item.detail);
}

fn diagnostic(arena: std.mem.Allocator, io: Io, status: []const u8, label: []const u8, detail: []const u8) !void {
    try printLine(io, try std.fmt.allocPrint(arena, "[{s}] {s}: {s}", .{ status, label, detail }));
}

fn printStats(io: Io, summary: metrics.Summary) !void {
    const stdout: Io.File = .stdout();
    var buf: [2048]u8 = undefined;
    var w = stdout.writer(io, &buf);
    try w.interface.print(
        \\SayAll Transcription Statistics
        \\
        \\Attempts:      {d}
        \\Successful:    {d}
        \\No speech:     {d}
        \\Failed:        {d}
        \\Pre-STT fail:  {d}
        \\Success rate:  {d:.1}%
        \\
        \\STT latency
        \\Average:       {d} ms
        \\Minimum:       {d} ms
        \\Maximum:       {d} ms
        \\Recent p50:    {d} ms
        \\Recent p95:    {d} ms
        \\
        \\Normalized successful history
        \\Samples:       {d}
        \\Realtime:      {d:.3}x
        \\Per audio sec: {d:.1} ms
        \\Per word:      {d:.2} ms ({d} samples)
        \\Per character: {d:.3} ms
        \\
        \\Stop to final
        \\Average:       {d} ms
        \\Recent p50:    {d} ms
        \\Recent p95:    {d} ms
        \\Under 500 ms:  {d}/{d} ({d:.1}%)
        \\
    , .{
        summary.attempts,
        summary.successful,
        summary.no_speech,
        summary.failed,
        summary.pre_stt_failed,
        summary.success_rate * 100.0,
        summary.average_latency_ms orelse 0,
        summary.minimum_latency_ms orelse 0,
        summary.maximum_latency_ms orelse 0,
        summary.recent_p50_ms orelse 0,
        summary.recent_p95_ms orelse 0,
        summary.normalized_samples,
        summary.realtime_factor orelse 0,
        summary.average_latency_ms_per_audio_second orelse 0,
        summary.average_latency_ms_per_word orelse 0,
        summary.content_samples,
        summary.average_latency_ms_per_character orelse 0,
        summary.average_stop_to_final_ms orelse 0,
        summary.stop_to_final_p50_ms orelse 0,
        summary.stop_to_final_p95_ms orelse 0,
        summary.stop_to_final_under_500,
        summary.stop_to_final_samples,
        summary.stop_to_final_under_500_percentage orelse 0,
    });
    try w.interface.print(
        \\Transport comparison (successful history)
        \\Global REST:   {d}/{d} ok, {d} ms avg
        \\EU REST:       {d}/{d} ok, {d} ms avg
        \\AU REST:       {d}/{d} ok, {d} ms avg
        \\Global stream: {d}/{d} ok, {d} ms avg, {d} ms connect
        \\EU stream:     {d}/{d} ok, {d} ms avg, {d} ms connect
        \\AU stream:     {d}/{d} ok, {d} ms avg, {d} ms connect
        \\
        \\History:       {d}/{d}
        \\
    , .{
        summary.global_rest.samples,
        summary.global_rest.attempts,
        summary.global_rest.average_latency_ms orelse 0,
        summary.eu_rest.samples,
        summary.eu_rest.attempts,
        summary.eu_rest.average_latency_ms orelse 0,
        summary.au_rest.samples,
        summary.au_rest.attempts,
        summary.au_rest.average_latency_ms orelse 0,
        summary.global_stream.samples,
        summary.global_stream.attempts,
        summary.global_stream.average_latency_ms orelse 0,
        summary.global_stream.average_connection_ms orelse 0,
        summary.eu_stream.samples,
        summary.eu_stream.attempts,
        summary.eu_stream.average_latency_ms orelse 0,
        summary.eu_stream.average_connection_ms orelse 0,
        summary.au_stream.samples,
        summary.au_stream.attempts,
        summary.au_stream.average_latency_ms orelse 0,
        summary.au_stream.average_connection_ms orelse 0,
        summary.history_entries,
        summary.history_limit,
    });
    try w.interface.flush();
}

fn usage() void {
    std.debug.print("{s}", .{cli.help});
}

test {
    _ = cli;
    _ = host_control;
    _ = config;
    _ = events;
    _ = recorder;
    _ = deepgram;
    _ = deepgram_stream;
    _ = groq;
    _ = metrics;
    _ = keywords;
    _ = protocol;
    _ = product_module;
}

test "updates only restart an idle daemon" {
    try std.testing.expect(cli.updateAllowed(.idle));
    try std.testing.expect(!cli.updateAllowed(.recording));
    try std.testing.expect(!cli.updateAllowed(.processing));
    try std.testing.expect(!cli.updateAllowed(.stopping));
}

test "setup readiness distinguishes a live host from startup transport failures" {
    try std.testing.expect(hostReady(.idle));
    try std.testing.expect(hostReady(.recording));
    try std.testing.expect(hostReady(.{ .operation_error = "missing microphone" }));
    try std.testing.expect(!hostReady(.{ .transport_error = "not bound" }));
    try std.testing.expect(!hostReady(.{ .incompatible = "old host" }));
    try std.testing.expect(!hostReady(.unavailable));
}

test "keyword search preserves values and folds ASCII case" {
    try std.testing.expect(containsAsciiIgnoreCase("Model Context Protocol", "context"));
    try std.testing.expect(containsAsciiIgnoreCase("München", "München"));
    try std.testing.expect(!containsAsciiIgnoreCase("München", "munchen"));
    try std.testing.expect(!containsAsciiIgnoreCase("SayAll", "Say All"));
}
