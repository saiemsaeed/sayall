const std = @import("std");
const batch = @import("batch.zig");
const deepgram_stream = @import("stt/deepgram_stream.zig");
const provider = @import("provider_config.zig");
const keywords = @import("keywords.zig");

pub const Request = struct {
    version: u32,
    wav_path: []const u8,
    pcm_path: []const u8,
    deepgram_api_key: []const u8,
    deepgram_model: []const u8 = "nova-3",
    deepgram_language: []const u8 = "en",
    deepgram_region: []const u8 = "global",
    deepgram_keyterms: []const []const u8 = &.{},
    stream_finalize_timeout_ms: u32 = 2000,
    groq_api_key: []const u8,
    groq_model: []const u8 = "llama-3.1-8b-instant",
    groq_base_url: []const u8 = "https://api.groq.com/openai/v1/chat/completions",
    cleanup_enabled: bool,
};

pub const Finish = struct {
    version: u32,
    command: []const u8,
    force_rest: bool = false,
};

const Ready = struct {
    version: u32 = 1,
    event: []const u8 = "ready",
    streaming: bool,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io) !void {
    var storage: [batch.max_request_bytes + 1]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &storage);
    const header = readLine(&reader.interface) catch {
        return writeResult(gpa, io, .{ .status = .@"error", .@"error" = .invalid_request });
    } orelse return;
    const parsed = parseRequest(gpa, header) catch {
        return writeResult(gpa, io, .{ .status = .@"error", .@"error" = .invalid_request });
    };
    defer parsed.deinit();
    const request = parsed.value;

    if (!validRequest(io, request)) {
        return writeResult(gpa, io, .{ .status = .@"error", .@"error" = .invalid_request });
    }

    var cfg: provider.SttConfig = .{
        .api_key = request.deepgram_api_key,
        .model = request.deepgram_model,
        .language = request.deepgram_language,
        .region = request.deepgram_region,
        .keyterms = request.deepgram_keyterms,
        .streaming = true,
        .stream_finalize_timeout_ms = request.stream_finalize_timeout_ms,
    };
    var session: ?*deepgram_stream.Session = deepgram_stream.Session.startBounded(
        gpa,
        io,
        &cfg,
        request.pcm_path,
        9_600_000,
    ) catch null;
    try writeJsonLine(gpa, io, Ready{ .streaming = session != null });

    const finish_line = readLine(&reader.interface) catch {
        if (session) |active| active.cancel();
        return;
    } orelse {
        if (session) |active| active.cancel();
        return;
    };
    const parsed_finish = std.json.parseFromSlice(Finish, gpa, finish_line, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch {
        if (session) |active| active.cancel();
        return writeResult(gpa, io, .{ .status = .@"error", .@"error" = .invalid_request });
    };
    defer parsed_finish.deinit();
    const finish = parsed_finish.value;
    if (finish.version != 1 or !std.mem.eql(u8, finish.command, "finish")) {
        if (session) |active| active.cancel();
        return writeResult(gpa, io, .{ .status = .@"error", .@"error" = .invalid_request });
    }

    var streamed: ?[]u8 = null;
    defer if (streamed) |text| gpa.free(text);
    if (session) |active| {
        if (finish.force_rest) {
            active.cancel();
        } else switch (active.finish()) {
            .success => |success| streamed = success.transcript,
            .failed => {},
        }
        session = null;
    }

    const result = batch.processWithTranscript(gpa, io, batchRequest(request), .{}, streamed);
    defer if (result.text) |text| gpa.free(text);
    try writeResult(gpa, io, result);
}

pub fn parseRequest(gpa: std.mem.Allocator, input: []const u8) !std.json.Parsed(Request) {
    if (input.len == 0 or input.len > batch.max_request_bytes) return error.InvalidRequest;
    return std.json.parseFromSlice(Request, gpa, input, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch error.InvalidRequest;
}

fn readLine(reader: *std.Io.Reader) !?[]const u8 {
    const line = reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.FrameTooLong,
        else => return err,
    };
    return if (line) |bytes| std.mem.trimEnd(u8, bytes, "\r") else null;
}

fn validRequest(io: std.Io, request: Request) bool {
    if (request.version != 1 or request.deepgram_api_key.len == 0) return false;
    if (!std.fs.path.isAbsolute(request.wav_path) or !std.fs.path.isAbsolute(request.pcm_path)) return false;
    if (std.mem.eql(u8, request.wav_path, request.pcm_path)) return false;
    if (!safeSecret(request.deepgram_api_key) or !safeSecret(request.groq_api_key)) return false;
    if (!safeProviderValue(request.deepgram_model) or !safeProviderValue(request.deepgram_language)) return false;
    if (!validRegion(request.deepgram_region)) return false;
    if (request.stream_finalize_timeout_ms < 250 or request.stream_finalize_timeout_ms > 10_000) return false;
    if (!safeProviderValue(request.groq_model) or
        !std.mem.eql(u8, request.groq_base_url, "https://api.groq.com/openai/v1/chat/completions")) return false;
    keywords.validate(request.deepgram_keyterms) catch return false;
    if (request.deepgram_keyterms.len > 0 and !std.mem.eql(u8, request.deepgram_model, "nova-3") and
        !std.mem.startsWith(u8, request.deepgram_model, "nova-3-")) return false;
    var file = std.Io.Dir.cwd().openFile(io, request.pcm_path, .{
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return false;
    defer file.close(io);
    const stat = file.stat(io) catch return false;
    return stat.kind == .file;
}

fn batchRequest(request: Request) batch.Request {
    return .{
        .version = request.version,
        .wav_path = request.wav_path,
        .deepgram_api_key = request.deepgram_api_key,
        .deepgram_model = request.deepgram_model,
        .deepgram_language = request.deepgram_language,
        .deepgram_region = request.deepgram_region,
        .deepgram_keyterms = request.deepgram_keyterms,
        .groq_api_key = request.groq_api_key,
        .groq_model = request.groq_model,
        .groq_base_url = request.groq_base_url,
        .cleanup_enabled = request.cleanup_enabled,
    };
}

fn safeSecret(secret: []const u8) bool {
    for (secret) |byte| if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return false;
    return true;
}

fn safeProviderValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.' and byte != '_') return false;
    return true;
}

fn validRegion(region: []const u8) bool {
    return std.mem.eql(u8, region, "global") or std.mem.eql(u8, region, "eu") or std.mem.eql(u8, region, "au");
}

fn writeResult(gpa: std.mem.Allocator, io: std.Io, result: batch.Result) !void {
    const json = try batch.stringifyResult(gpa, result);
    defer gpa.free(json);
    try writeLine(io, json);
}

fn writeJsonLine(gpa: std.mem.Allocator, io: std.Io, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    try writeLine(io, json);
}

fn writeLine(io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.writeByte('\n');
    try writer.interface.flush();
}

test "stream request is strict and preserves regional provider settings" {
    const json = "{\"version\":1,\"wav_path\":\"/tmp/a.wav\",\"pcm_path\":\"/tmp/a.pcm\",\"deepgram_api_key\":\"d\",\"deepgram_model\":\"nova-3\",\"deepgram_language\":\"en-GB\",\"deepgram_region\":\"eu\",\"groq_api_key\":\"\",\"cleanup_enabled\":false}";
    const parsed = try parseRequest(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("eu", parsed.value.deepgram_region);
    try std.testing.expectEqualStrings("en-GB", batchRequest(parsed.value).deepgram_language);
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, json[0 .. json.len - 1]));
}
