const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const config = @import("config.zig");
const keywords = @import("keywords.zig");
const ipc = @import("ipc.zig");
const metrics = @import("metrics.zig");
const daemon = @import("daemon.zig");
const events = @import("events.zig");
const recorder = @import("recorder.zig");
const protocol = @import("protocol.zig");
const shortcut = @import("shortcut.zig");
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
        usage();
        return 2;
    }

    const cmd = std.mem.span(argv[1]);

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version")) {
        if (argv.len != 2) return invalidArguments(cmd);
        try printLine(io, "sayall " ++ build_options.version);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "daemon")) {
        if (argv.len > 3) return invalidArguments("daemon");
        const verbose = if (argv.len == 3) flag(std.mem.span(argv[2]), "--verbose", "-v") else false;
        if (argv.len == 3 and !verbose) return invalidArguments("daemon");
        var cfg = config.load(arena, io, env) catch |err| {
            std.debug.print("sayall: cannot load configuration: {s}\n", .{@errorName(err)});
            return 78; // EX_CONFIG; systemd is configured not to restart this.
        };
        if (verbose) cfg.verbose = true;
        if (cfg.stt.api_key.len == 0) {
            std.debug.print("sayall: error: no STT API key — set DEEPGRAM_API_KEY or stt.api_key in ~/.config/sayall/config.json\n", .{});
            return 78;
        }
        if (cfg.llm.enabled and cfg.llm.api_key.len == 0) {
            std.debug.print("sayall: warning: no LLM API key (GROQ_API_KEY) — cleanup pass disabled\n", .{});
            cfg.llm.enabled = false;
        }
        const sock = try config.socketPath(arena, env);
        const metrics_path = try config.metricsPath(arena, env);
        try daemon.run(gpa, io, &cfg, sock, metrics_path);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "restart")) {
        if (argv.len != 2) return invalidArguments("restart");
        var child = std.process.spawn(io, .{
            .argv = &.{ "systemctl", "--user", "restart", "sayall.service" },
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            std.debug.print("sayall: could not run systemctl ({s})\n", .{@errorName(err)});
            return 1;
        };
        const term = child.wait(io) catch |err| {
            std.debug.print("sayall: could not restart service ({s})\n", .{@errorName(err)});
            return 1;
        };
        switch (term) {
            .exited => |code| if (code != 0) return 1,
            else => return 1,
        }
        try printLine(io, "SayAll restarted; configuration reloaded.");
        return 0;
    }

    if (std.mem.eql(u8, cmd, "setup")) {
        if (argv.len != 2) return invalidArguments("setup");
        const shortcut_ok = try setupShortcut(arena, io, env);
        const services_ok = setupServices(io);
        if (!services_ok) {
            std.debug.print("sayall: could not configure the systemd user services\n", .{});
            return 1;
        }
        if (!shortcut_ok) {
            std.debug.print("sayall: services were enabled and restarted, but shortcut setup is incomplete; resolve the error above and retry 'sayall setup'.\n", .{});
            return 1;
        }
        try printLine(io, "SayAll services enabled and restarted.");
        return 0;
    }

    if (std.mem.eql(u8, cmd, "update")) {
        if (argv.len != 2) return invalidArguments("update");
        const sock = try config.socketPath(arena, env);
        if (ipc.sendCommand(arena, io, sock, "status")) |state| {
            if (!updateAllowed(state)) {
                std.debug.print("sayall: cannot update while the daemon is {s}; wait for it to become idle\n", .{state});
                return 1;
            }
        } else |_| {}
        const package = try installedPackage(arena, io) orelse {
            std.debug.print("sayall: update requires an installed AUR package (sayall, sayall-src, or sayall-git; legacy sayall-bin is also recognized)\n", .{});
            return 1;
        };
        if (!try commandExists(arena, io, "yay")) {
            std.debug.print("sayall: update requires the 'yay' AUR helper\n", .{});
            return 1;
        }
        if (package.legacy_migration) {
            try printLine(io, "Migrating legacy sayall-bin installation to the current sayall package with yay...");
        } else {
            try printLine(io, try std.fmt.allocPrint(arena, "Checking/updating {s} with yay...", .{package.installed}));
        }
        const updated = runInherited(io, &.{ "yay", "-S", "--needed", package.update_target });
        if (!updated) {
            std.debug.print("sayall: package update failed; services were not restarted\n", .{});
            return 1;
        }
        if (!setupServices(io)) {
            std.debug.print("sayall: yay completed successfully, but the systemd user services could not be restarted\n", .{});
            return 1;
        }
        if (!try setupShortcut(arena, io, env)) {
            std.debug.print("sayall: package updated and services restarted, but the saved shortcut could not be applied\n", .{});
            return 1;
        }
        try printLine(io, "yay completed successfully; SayAll services enabled and restarted.");
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

    if (std.mem.eql(u8, cmd, "toggle") or std.mem.eql(u8, cmd, "stop") or std.mem.eql(u8, cmd, "status")) {
        const is_toggle = std.mem.eql(u8, cmd, "toggle");
        if ((!is_toggle and argv.len != 2) or (is_toggle and argv.len > 3)) return invalidArguments(cmd);
        const raw = is_toggle and argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "--raw");
        if (is_toggle and argv.len == 3 and !raw) return invalidArguments("toggle");
        const sock = try config.socketPath(arena, env);
        const wire: []const u8 = if (raw) "toggle raw" else cmd;
        const reply = ipc.sendCommand(arena, io, sock, wire) catch |err| {
            std.debug.print("sayall: cannot reach daemon ({s}) — is 'sayall daemon' running?\n", .{@errorName(err)});
            return 1;
        };
        try printLine(io, reply);
        return if (std.mem.startsWith(u8, reply, "error") or std.mem.startsWith(u8, reply, "busy")) 1 else 0;
    }

    if (std.mem.eql(u8, cmd, "transcribe")) {
        var raw = false;
        var verbose = false;
        var path: ?[]const u8 = null;
        for (argv[2..]) |a| {
            const value = std.mem.span(a);
            if (std.mem.eql(u8, value, "--raw") and !raw) raw = true else if (flag(value, "--verbose", "-v") and !verbose) verbose = true else if (path == null and !std.mem.startsWith(u8, value, "-")) path = value else return invalidArguments("transcribe");
        }
        const wav_path = path orelse {
            std.debug.print("sayall: transcribe needs a WAV file path\n", .{});
            return 2;
        };
        var cfg = try config.load(arena, io, env);
        if (cfg.stt.api_key.len == 0) {
            std.debug.print("sayall: error: no Deepgram API key configured\n", .{});
            return 1;
        }
        if (cfg.llm.enabled and cfg.llm.api_key.len == 0) cfg.llm.enabled = false;
        cfg.verbose = cfg.verbose or verbose;
        const wav = try Io.Dir.cwd().readFileAlloc(io, wav_path, arena, .limited(256 * 1024 * 1024));
        const info = recorder.inspectWav(wav) catch {
            std.debug.print("sayall: not a valid WAV file: {s}\n", .{wav_path});
            return 1;
        };
        var line_buf: [256]u8 = undefined;
        const info_line = std.fmt.bufPrint(&line_buf, "duration: {d:.2}s ({d} Hz, {d} ch)", .{
            info.seconds, info.sample_rate, info.channels,
        }) catch "?";
        try printLine(io, info_line);

        const metrics_path = try config.metricsPath(arena, env);
        const metrics_store: ?metrics.Store = if (cfg.metrics.enabled)
            metrics.Store.init(metrics_path, cfg.metrics.history_max_entries)
        else
            null;
        const tracked = try metrics.transcribeTracked(
            arena,
            io,
            metrics_store,
            &cfg.stt,
            wav,
            cfg.verbose,
            "cli",
            @intFromFloat(info.seconds * 1000.0),
            null,
        );
        const transcript = tracked.transcript;
        try printLine(io, try std.fmt.allocPrint(arena, "raw: {s}", .{transcript}));

        if (!raw and cfg.llm.enabled and transcript.len > 0) {
            const cleaned = try groq.cleanup(arena, io, &cfg.llm, cfg.stt.keyterms, transcript, cfg.verbose);
            try printLine(io, try std.fmt.allocPrint(arena, "clean: {s}", .{cleaned}));
        }
        return 0;
    }

    if (std.mem.eql(u8, cmd, "stats")) {
        if (argv.len > 3) return invalidArguments("stats");
        const as_json = argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "--json");
        if (argv.len == 3 and !as_json) return invalidArguments("stats");
        const cfg = try config.load(arena, io, env);
        const metrics_path = try config.metricsPath(arena, env);
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
        const sock = try config.socketPath(arena, env);
        const scratch_dir = std.fs.path.dirname(sock) orelse "/tmp";
        var mic_recorder: recorder.Recorder = .{};
        try printLine(io, try std.fmt.allocPrint(arena, "Source: {s}", .{
            if (source.len == 0) "OS default" else source,
        }));
        try printLine(io, "Speak normally for 3 seconds...");
        try mic_recorder.start(gpa, io, scratch_dir, source);
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

    usage();
    return 2;
}

fn flag(value: []const u8, long: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, value, long) or std.mem.eql(u8, value, short);
}

fn keywordCommand(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, raw_args: []const [*:0]const u8) !u8 {
    const keywords_path = try keywords.path(arena, env) orelse {
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
        try keywordRestartInstruction(io);
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
        try keywordRestartInstruction(io);
        return 0;
    }

    if (std.mem.eql(u8, action, "delete")) {
        if (raw_args.len != 2) return invalidArguments("keywords delete");
        const legacy = loadKeywordFallback(arena, io, env, store) catch |err| return keywordError(err, null);
        const value = std.mem.span(raw_args[1]);
        const updated = store.delete(arena, io, legacy, value) catch |err| return keywordError(err, value);
        try printLine(io, try std.fmt.allocPrint(arena, "Keyword deleted; {d} configured.", .{updated.len}));
        try keywordRestartInstruction(io);
        return 0;
    }

    if (std.mem.eql(u8, action, "clear")) {
        if (raw_args.len != 2 or !std.mem.eql(u8, std.mem.span(raw_args[1]), "--confirm")) {
            std.debug.print("sayall: refusing to clear keywords without: sayall keywords clear --confirm\n", .{});
            return 2;
        }
        store.clear(arena, io) catch |err| return keywordError(err, null);
        try printLine(io, "All keywords cleared.");
        try keywordRestartInstruction(io);
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

fn keywordRestartInstruction(io: Io) !void {
    try printLine(io, "Run 'sayall restart' to apply keyword changes to the running daemon.");
}

fn invalidArguments(command: []const u8) u8 {
    std.debug.print("sayall: invalid arguments for '{s}'\n", .{command});
    usage();
    return 2;
}

fn printLine(io: Io, text: []const u8) !void {
    const stdout: Io.File = .stdout();
    var buf: [256]u8 = undefined;
    var w = stdout.writer(io, &buf);
    try w.interface.writeAll(text);
    try w.interface.writeByte('\n');
    try w.interface.flush();
}

fn setupServices(io: Io) bool {
    if (!runInherited(io, &.{ "systemctl", "--user", "daemon-reload" })) return false;
    if (!runInherited(io, &.{ "systemctl", "--user", "enable", "sayall.service", "sayall-hud.service" })) return false;
    return runInherited(io, &.{ "systemctl", "--user", "restart", "sayall.service", "sayall-hud.service" });
}

fn setupShortcut(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !bool {
    return reportShortcutResult(arena, io, try shortcut.apply(arena, io, env, .current));
}

fn shortcutCommand(
    arena: std.mem.Allocator,
    io: Io,
    env: *const std.process.Environ.Map,
    argv: []const [*:0]const u8,
) !u8 {
    if (argv.len == 2 or (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "show"))) {
        const state = shortcut.loadState(arena, io, env) catch |err| {
            std.debug.print("sayall: cannot read shortcut state ({s})\n", .{@errorName(err)});
            return 1;
        };
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
        const ok = try reportShortcutResult(arena, io, try shortcut.apply(arena, io, env, .disable));
        return if (ok) 0 else 1;
    }

    if (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "reset")) {
        const ok = try reportShortcutResult(arena, io, try shortcut.apply(arena, io, env, .reset));
        return if (ok) 0 else 1;
    }

    if ((argv.len == 4 or argv.len == 5) and std.mem.eql(u8, std.mem.span(argv[2]), "set")) {
        const requested = if (argv.len == 4)
            std.mem.span(argv[3])
        else
            try std.fmt.allocPrint(arena, "{s}+{s}", .{ std.mem.span(argv[3]), std.mem.span(argv[4]) });
        const normalized = shortcut.parseShortcut(arena, requested) catch {
            std.debug.print("sayall: invalid shortcut '{s}'; use a chord such as CTRL+SLASH, SUPER+SPACE, or F9\n", .{requested});
            return 2;
        };
        const ok = try reportShortcutResult(arena, io, try shortcut.apply(arena, io, env, .{ .set = normalized }));
        return if (ok) 0 else 1;
    }

    return invalidArguments("shortcut");
}

fn externalShortcutRequiresMigration(value: []const u8) u8 {
    std.debug.print("sayall: {s} is owned by an existing manual Hyprland binding; remove that 'sayall toggle' line before using 'sayall shortcut set' or 'sayall shortcut disable'. No files were changed.\n", .{value});
    return 1;
}

fn reportShortcutResult(arena: std.mem.Allocator, io: Io, result: shortcut.ApplyResult) !bool {
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

const InstalledPackage = struct {
    installed: []const u8,
    update_target: []const u8,
    legacy_migration: bool,
};

fn installedPackage(arena: std.mem.Allocator, io: Io) !?InstalledPackage {
    for (aur_package_candidates) |package| {
        if (try commandSucceeds(arena, io, &.{ "pacman", "-Qq", package })) return packageIdentity(package).?;
    }
    return null;
}

fn packageIdentity(installed: []const u8) ?InstalledPackage {
    if (std.mem.eql(u8, installed, "sayall-bin")) return .{
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
    "sayall-src",
    "sayall-git",
    "sayall-bin", // Legacy migration/update fallback; no current recipe uses this name.
};

fn updateAllowed(daemon_state: []const u8) bool {
    return std.mem.eql(u8, daemon_state, "idle");
}

fn doctor(arena: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) !u8 {
    var failures: u8 = 0;
    var warnings: u8 = 0;
    try printLine(io, "SayAll diagnostics");

    const exe = try std.process.executablePathAlloc(io, arena);
    try diagnostic(arena, io, "ok", "Version", "sayall " ++ build_options.version);
    try diagnostic(arena, io, "ok", "Executable", exe);

    const wayland = env.get("WAYLAND_DISPLAY");
    if (wayland) |display| {
        try diagnostic(arena, io, "ok", "Wayland", display);
    } else {
        failures += 1;
        try diagnostic(arena, io, "fail", "Wayland", "WAYLAND_DISPLAY is not set");
    }

    var loaded_config: ?config.Config = null;
    const cfg_path = try config.configPath(arena, env);
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

        if (config.load(arena, io, env)) |cfg| {
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

    const required_commands = [_][]const u8{ "pw-record", "wtype", "wl-copy", "sayall-hud" };
    for (required_commands) |command| {
        if (try commandExists(arena, io, command)) {
            try diagnostic(arena, io, "ok", "Command", command);
        } else {
            failures += 1;
            try diagnostic(arena, io, "fail", "Missing command", command);
        }
    }
    if (loaded_config) |cfg| {
        if (cfg.notifications) {
            if (try commandExists(arena, io, "notify-send")) {
                try diagnostic(arena, io, "ok", "Command", "notify-send");
            } else {
                warnings += 1;
                try diagnostic(arena, io, "warn", "Missing command", "notify-send (notifications will fail)");
            }
        }
    }

    if (try commandSucceeds(arena, io, &.{ "systemctl", "--user", "is-active", "--quiet", "sayall.service" })) {
        try diagnostic(arena, io, "ok", "Service", "sayall.service is active");
    } else {
        failures += 1;
        try diagnostic(arena, io, "fail", "Service", "start with: systemctl --user enable --now sayall sayall-hud");
    }
    if (try commandSucceeds(arena, io, &.{ "systemctl", "--user", "is-active", "--quiet", "sayall-hud.service" })) {
        try diagnostic(arena, io, "ok", "HUD service", "sayall-hud.service is active");
    } else {
        failures += 1;
        try diagnostic(arena, io, "fail", "HUD service", "start with: systemctl --user enable --now sayall-hud");
    }

    const sock = try config.socketPath(arena, env);
    if (ipc.sendCommand(arena, io, sock, "status")) |reply| {
        try diagnostic(arena, io, "ok", "Daemon", reply);
    } else |err| {
        failures += 1;
        try diagnostic(arena, io, "fail", "Daemon", try std.fmt.allocPrint(arena, "cannot reach {s} ({s})", .{ sock, @errorName(err) }));
    }

    try printLine(io, try std.fmt.allocPrint(arena, "Result: {d} failure(s), {d} warning(s)", .{ failures, warnings }));
    return if (failures == 0) 0 else 1;
}

fn diagnostic(arena: std.mem.Allocator, io: Io, status: []const u8, label: []const u8, detail: []const u8) !void {
    try printLine(io, try std.fmt.allocPrint(arena, "[{s}] {s}: {s}", .{ status, label, detail }));
}

fn commandExists(arena: std.mem.Allocator, io: Io, command: []const u8) !bool {
    return commandSucceeds(arena, io, &.{ "sh", "-c", "command -v -- \"$1\" >/dev/null 2>&1", "sayall-doctor", command });
}

fn commandSucceeds(arena: std.mem.Allocator, io: Io, argv: []const []const u8) !bool {
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
    std.debug.print(
        \\sayall — voice dictation daemon
        \\
        \\usage:
        \\  sayall --version                     print the installed version
        \\  sayall setup                         enable and restart user services
        \\  sayall update                        update the installed AUR package
        \\  sayall doctor                        check installation and runtime health
        \\  sayall shortcut [show]               show the saved global shortcut
        \\  sayall shortcut set CTRL+SLASH       set and activate a global shortcut
        \\  sayall shortcut reset                restore the CTRL+SLASH default
        \\  sayall shortcut disable              disable the global shortcut
        \\  sayall daemon [--verbose]            run the daemon in the foreground
        \\  sayall restart                       restart the systemd user service and reload config
        \\  sayall toggle [--raw]                toggle recording (raw = skip LLM cleanup)
        \\  sayall stop                          cancel an active recording
        \\  sayall status                        print daemon state
        \\  sayall transcribe <file.wav> [--raw] transcribe a file (debugging)
        \\  sayall mic-test [source]             record 3 seconds and report mic level
        \\  sayall stats [--json]                show persistent STT metrics
        \\  sayall keywords list                list configured keywords
        \\  sayall keywords search <text>       search configured keywords
        \\  sayall keywords add <keyword>...    add words or quoted phrases
        \\  sayall keywords update <old> <new>  rename one exact keyword
        \\  sayall keywords delete <keyword>    delete one exact keyword
        \\  sayall keywords clear --confirm     delete every keyword
        \\
    , .{});
}

test {
    _ = config;
    _ = daemon;
    _ = events;
    _ = recorder;
    _ = deepgram;
    _ = deepgram_stream;
    _ = groq;
    _ = metrics;
    _ = keywords;
    _ = protocol;
    _ = shortcut;
}

test "doctor recognizes successful process exits" {
    try std.testing.expect(termSucceeded(.{ .exited = 0 }));
    try std.testing.expect(!termSucceeded(.{ .exited = 1 }));
    try std.testing.expect(!termSucceeded(.{ .unknown = 1 }));
}

test "updates only restart an idle daemon" {
    try std.testing.expect(updateAllowed("idle"));
    try std.testing.expect(!updateAllowed("recording"));
    try std.testing.expect(!updateAllowed("processing"));
    try std.testing.expect(!updateAllowed("stopping"));
}

test "update recognizes every current AUR package and the legacy binary name" {
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "sayall", "sayall-src", "sayall-git", "sayall-bin" },
        &aur_package_candidates,
    );
    for (aur_package_candidates[0..3]) |package| {
        const identity = packageIdentity(package).?;
        try std.testing.expectEqualStrings(package, identity.installed);
        try std.testing.expectEqualStrings(package, identity.update_target);
        try std.testing.expect(!identity.legacy_migration);
    }
    const legacy = packageIdentity("sayall-bin").?;
    try std.testing.expectEqualStrings("sayall-bin", legacy.installed);
    try std.testing.expectEqualStrings("sayall", legacy.update_target);
    try std.testing.expect(legacy.legacy_migration);
    try std.testing.expect(packageIdentity("unrelated") == null);
}

test "keyword search preserves values and folds ASCII case" {
    try std.testing.expect(containsAsciiIgnoreCase("Model Context Protocol", "context"));
    try std.testing.expect(containsAsciiIgnoreCase("München", "München"));
    try std.testing.expect(!containsAsciiIgnoreCase("München", "munchen"));
    try std.testing.expect(!containsAsciiIgnoreCase("SayAll", "Say All"));
}
