const std = @import("std");
const builtin = @import("builtin");
const batch = @import("batch.zig");
const config = @import("config.zig");
const worker_protocol = @import("worker_protocol.zig");

pub const Options = struct {
    wav_path: []const u8,
    json: bool = false,
    raw: bool = false,
};

pub const ParseError = error{InvalidArguments};

pub fn parse(args: []const []const u8) ParseError!Options {
    var result: Options = .{ .wav_path = "" };
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json") and !result.json) {
            result.json = true;
        } else if (std.mem.eql(u8, arg, "--raw") and !result.raw) {
            result.raw = true;
        } else if (!std.mem.startsWith(u8, arg, "-") and result.wav_path.len == 0) {
            result.wav_path = arg;
        } else {
            return error.InvalidArguments;
        }
    }
    if (result.wav_path.len == 0) return error.InvalidArguments;
    return result;
}

pub fn run(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    options: Options,
) !u8 {
    const cfg = config.load(arena, io, env) catch |err| {
        try diagnostic(io, "configuration is invalid", @errorName(err));
        return 78;
    };
    if (cfg.stt.api_key.len == 0) {
        try write(io, .stderr(), "sayall: transcribe: Deepgram credentials are not configured\n");
        return 78;
    }

    const source = std.Io.Dir.cwd().readFileAlloc(io, options.wav_path, arena, .limited(batch.max_audio_bytes + 1)) catch |err| {
        try diagnostic(io, "cannot read input WAV", @errorName(err));
        return 66;
    };
    if (source.len == 0 or source.len > batch.max_audio_bytes) {
        try write(io, .stderr(), "sayall: transcribe: input WAV must be between 1 byte and 10 MiB\n");
        return 66;
    }

    var nonce: u64 = undefined;
    try std.Io.randomSecure(io, std.mem.asBytes(&nonce));
    const default_temp = if (builtin.os.tag == .macos) "/private/tmp" else "/tmp";
    const temp_base = std.mem.trimEnd(u8, env.get("TMPDIR") orelse default_temp, &.{std.fs.path.sep});
    if (!std.fs.path.isAbsolute(temp_base)) {
        try write(io, .stderr(), "sayall: transcribe: TMPDIR must be an absolute path\n");
        return 78;
    }
    var temp_root = std.Io.Dir.openDirAbsolute(io, temp_base, .{ .iterate = true, .follow_symlinks = false }) catch {
        try write(io, .stderr(), "sayall: transcribe: temporary directory is unavailable\n");
        return 73;
    };
    defer temp_root.close(io);
    if (!safeTempRoot(io, temp_root)) {
        try write(io, .stderr(), "sayall: transcribe: refusing unsafe TMPDIR permissions or ownership\n");
        return 78;
    }
    const temp_name = try std.fmt.allocPrint(arena, "sayall-cli-{d}-{x}", .{ processId(), nonce });
    try temp_root.createDir(io, temp_name, .fromMode(0o700));
    defer temp_root.deleteDir(io, temp_name) catch {};
    var temp_dir = try temp_root.openDir(io, temp_name, .{ .iterate = true, .follow_symlinks = false });
    defer temp_dir.close(io);
    const private_wav = try std.fmt.allocPrint(arena, "{s}{c}{s}{c}input.wav", .{ temp_base, std.fs.path.sep, temp_name, std.fs.path.sep });
    {
        var file = try temp_dir.createFile(io, "input.wav", .{
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        });
        defer file.close(io);
        try file.writeStreamingAll(io, source);
    }
    defer temp_dir.deleteFile(io, "input.wav") catch {};

    const request = batch.Request{
        .version = worker_protocol.version,
        .wav_path = private_wav,
        .deepgram_api_key = cfg.stt.api_key,
        .deepgram_model = cfg.stt.model,
        .deepgram_language = cfg.stt.language,
        .deepgram_region = cfg.stt.region,
        .deepgram_keyterms = cfg.stt.keyterms,
        .deepgram_smart_format = cfg.stt.smart_format,
        .deepgram_punctuate = cfg.stt.punctuate,
        .deepgram_dictation = cfg.stt.dictation,
        .deepgram_numerals = cfg.stt.numerals,
        .deepgram_measurements = cfg.stt.measurements,
        .groq_api_key = cfg.llm.api_key,
        .groq_model = cfg.llm.model,
        .groq_base_url = cfg.llm.base_url,
        .processing_profile = if (options.raw) .verbatim else config.effectiveProcessingProfile(&cfg),
    };
    const request_json = try std.json.Stringify.valueAlloc(arena, request, .{});
    if (request_json.len > batch.max_request_bytes) {
        try write(io, .stderr(), "sayall: transcribe: configuration exceeds the worker request limit\n");
        return 78;
    }

    const worker = resolveWorker(arena, io) catch {
        try write(io, .stderr(), "sayall: transcribe: packaged processing worker is unavailable\n");
        return 69;
    };
    var empty_env = std.process.Environ.Map.init(gpa);
    defer empty_env.deinit();
    var child = std.process.spawn(io, .{
        .argv = &.{worker},
        .environ_map = &empty_env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        try write(io, .stderr(), "sayall: transcribe: could not start the processing worker\n");
        return 69;
    };
    defer child.kill(io);

    const child_stdin = child.stdin.?;
    try child_stdin.writeStreamingAll(io, request_json);
    child_stdin.close(io);
    child.stdin = null;

    var output_buffer: [4096]u8 = undefined;
    var output_reader = child.stdout.?.reader(io, &output_buffer);
    const response = output_reader.interface.allocRemaining(arena, .limited(batch.max_output_bytes + 1)) catch {
        try write(io, .stderr(), "sayall: transcribe: worker response exceeded the 1 MiB limit\n");
        return 70;
    };
    child.stdout.?.close(io);
    child.stdout = null;
    const term = child.wait(io) catch {
        try write(io, .stderr(), "sayall: transcribe: processing worker failed\n");
        return 70;
    };
    if (term != .exited or term.exited != 0 or response.len == 0 or response.len > batch.max_output_bytes) {
        try write(io, .stderr(), "sayall: transcribe: processing worker failed\n");
        return 70;
    }

    const parsed = batch.parseResult(arena, response) catch |err| {
        if (err == error.IncompatibleVersion) {
            try write(io, .stderr(), "sayall: transcribe: processing worker uses an incompatible protocol\n");
            return 69;
        }
        try write(io, .stderr(), "sayall: transcribe: processing worker returned an invalid response\n");
        return 70;
    };
    defer parsed.deinit();
    if (options.json) {
        try write(io, .stdout(), response);
        try write(io, .stdout(), "\n");
        return if (parsed.value.status == .@"error") 1 else 0;
    }
    return presentHuman(io, parsed.value);
}

fn presentHuman(io: std.Io, result: batch.WireResult) !u8 {
    return switch (result.status) {
        .success => blk: {
            const text = result.text orelse {
                try write(io, .stderr(), "sayall: transcribe: worker success response omitted text\n");
                break :blk 70;
            };
            try write(io, .stdout(), text);
            try write(io, .stdout(), "\n");
            if (result.warning) |warning| {
                const message = try std.fmt.allocPrint(std.heap.page_allocator, "sayall: transcribe: warning: {s}\n", .{@tagName(warning)});
                defer std.heap.page_allocator.free(message);
                try write(io, .stderr(), message);
            }
            break :blk 0;
        },
        .no_speech => 0,
        .@"error" => blk: {
            const code = if (result.@"error") |value| @tagName(value) else "invalid_worker_response";
            const message = try std.fmt.allocPrint(std.heap.page_allocator, "sayall: transcribe: {s}\n", .{code});
            defer std.heap.page_allocator.free(message);
            try write(io, .stderr(), message);
            break :blk 1;
        },
    };
}

fn resolveWorker(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const executable = try std.process.executablePathAlloc(io, arena);
    const executable_dir = std.fs.path.dirname(executable) orelse return error.WorkerNotFound;
    const sibling = try std.fs.path.join(arena, &.{ executable_dir, "sayall-process" });
    if (isRegular(io, sibling)) return sibling;
    const archive_relative = try std.fs.path.join(arena, &.{ executable_dir, "..", "lib", "sayall", "sayall-process" });
    if (isRegular(io, archive_relative)) return archive_relative;
    if (builtin.os.tag == .linux and isRegular(io, "/usr/lib/sayall/sayall-process")) return "/usr/lib/sayall/sayall-process";
    return error.WorkerNotFound;
}

fn isRegular(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos => @intCast(std.c.getpid()),
        else => 0,
    };
}

fn safeTempRoot(io: std.Io, dir: std.Io.Dir) bool {
    const stat = dir.stat(io) catch return false;
    const mode = stat.permissions.toMode();
    const uid = directoryOwner(dir.handle) catch return false;
    const euid = effectiveUserId();
    return (uid == euid and mode & 0o022 == 0) or
        (uid == 0 and mode & 0o1000 != 0 and mode & 0o002 != 0);
}

fn directoryOwner(handle: std.Io.File.Handle) !u32 {
    if (builtin.os.tag == .linux) {
        var raw: std.os.linux.Statx = undefined;
        if (std.os.linux.errno(std.os.linux.statx(handle, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true }, &raw)) != .SUCCESS)
            return error.StatFailed;
        return raw.uid;
    }
    if (builtin.os.tag == .macos) {
        var raw: std.c.Stat = undefined;
        if (std.c.fstat(handle, &raw) != 0) return error.StatFailed;
        return raw.uid;
    }
    return error.UnsupportedPlatform;
}

fn effectiveUserId() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid(),
        .macos => @intCast(std.c.geteuid()),
        else => 0,
    };
}

fn diagnostic(io: std.Io, message: []const u8, detail: []const u8) !void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "sayall: transcribe: {s} ({s})\n", .{ message, detail }) catch
        "sayall: transcribe: operation failed\n";
    try write(io, .stderr(), text);
}

fn write(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    if (bytes.len != 0) try file.writeStreamingAll(io, bytes);
}

test "standalone transcribe grammar is exact" {
    const plain = try parse(&.{"clip.wav"});
    try std.testing.expectEqualStrings("clip.wav", plain.wav_path);
    try std.testing.expect(!plain.json);
    const machine = try parse(&.{ "--raw", "clip.wav", "--json" });
    try std.testing.expect(machine.raw);
    try std.testing.expect(machine.json);
    for ([_][]const []const u8{ &.{}, &.{"--json"}, &.{ "a.wav", "b.wav" }, &.{ "a.wav", "--json", "--json" }, &.{"--unknown"} }) |args|
        try std.testing.expectError(error.InvalidArguments, parse(args));
}
