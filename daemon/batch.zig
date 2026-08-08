const std = @import("std");
const recorder = @import("recorder.zig");
const provider = @import("provider_config.zig");
const deepgram = @import("stt/deepgram.zig");
const groq = @import("llm/groq.zig");
const keywords = @import("keywords.zig");
const provider_processing = @import("provider_processing.zig");
const worker_protocol = @import("worker_protocol.zig");
const secure_audio = @import("secure_audio.zig");

pub const max_request_bytes = worker_protocol.max_control_bytes;
pub const max_audio_bytes = 10 * 1024 * 1024;
pub const max_output_bytes = worker_protocol.max_result_bytes;
pub const Request = struct {
    version: u32,
    wav_path: []const u8,
    deepgram_api_key: []const u8,
    deepgram_model: []const u8 = "nova-3",
    deepgram_language: []const u8 = "en",
    deepgram_region: []const u8 = "global",
    deepgram_keyterms: []const []const u8 = &.{},
    deepgram_smart_format: bool = false,
    deepgram_punctuate: bool = false,
    deepgram_dictation: bool = false,
    deepgram_numerals: bool = false,
    deepgram_measurements: bool = false,
    groq_api_key: []const u8,
    groq_model: []const u8 = "openai/gpt-oss-20b",
    groq_base_url: []const u8 = "https://api.groq.com/openai/v1/chat/completions",
    cleanup_enabled: bool,
};
pub const ErrorCode = enum {
    invalid_request,
    incompatible_version,
    invalid_audio,
    audio_too_short,
    audio_too_long,
    missing_deepgram_key,
    deepgram_unauthorized,
    deepgram_rate_limited,
    deepgram_server,
    deepgram_network,
    response_too_large,
    internal,
};
pub const Warning = enum { cleanup_failed };
pub const Status = enum { success, no_speech, @"error" };
pub const Transport = enum { rest, stream };
pub const Result = struct {
    version: u32 = worker_protocol.version,
    status: Status,
    text: ?[]const u8 = null,
    warning: ?Warning = null,
    @"error": ?ErrorCode = null,
    transport: ?Transport = null,
};
pub const WireResult = struct {
    version: u32,
    status: Status,
    text: ?[]const u8 = null,
    warning: ?Warning = null,
    @"error": ?ErrorCode = null,
    transport: ?Transport = null,
};
pub const Seam = struct {
    context: ?*anyopaque = null,
    transcribe: *const fn (?*anyopaque, std.mem.Allocator, std.Io, *const provider.SttConfig, []const u8) anyerror![]u8 = liveTranscribe,
    cleanup: *const fn (?*anyopaque, std.mem.Allocator, std.Io, *const provider.LlmConfig, []const []const u8, []const u8) anyerror![]u8 = liveCleanup,
};

pub fn parseRequest(gpa: std.mem.Allocator, input: []const u8) !std.json.Parsed(Request) {
    if (input.len == 0 or input.len > max_request_bytes) return error.InvalidRequest;
    return std.json.parseFromSlice(Request, gpa, input, .{ .allocate = .alloc_always, .ignore_unknown_fields = false }) catch error.InvalidRequest;
}

pub fn process(gpa: std.mem.Allocator, io: std.Io, r: Request, seam: Seam) Result {
    return processWithTranscript(gpa, io, r, seam, null);
}

pub fn processWithTranscript(gpa: std.mem.Allocator, io: std.Io, r: Request, seam: Seam, streamed: ?[]const u8) Result {
    if (r.version != worker_protocol.version) return fail(.incompatible_version);
    if (r.deepgram_api_key.len == 0) return fail(.missing_deepgram_key);
    if (r.deepgram_dictation and !r.deepgram_punctuate) return fail(.invalid_request);
    if (!safeSecret(r.deepgram_api_key) or !safeSecret(r.groq_api_key)) return fail(.invalid_request);
    if (!safeProviderValue(r.deepgram_model) or !safeProviderValue(r.deepgram_language) or
        !safeLlmModel(r.groq_model) or !validRegion(r.deepgram_region) or
        !std.mem.eql(u8, r.groq_base_url, "https://api.groq.com/openai/v1/chat/completions")) return fail(.invalid_request);
    keywords.validate(r.deepgram_keyterms) catch return fail(.invalid_request);
    if (r.deepgram_keyterms.len > 0 and !std.mem.eql(u8, r.deepgram_model, "nova-3") and
        !std.mem.startsWith(u8, r.deepgram_model, "nova-3-")) return fail(.invalid_request);
    const opened = secure_audio.open(io, r.wav_path, max_audio_bytes, .nonempty) catch return fail(.invalid_audio);
    var file = opened.file;
    defer file.close(io);
    const stat = file.stat(io) catch return fail(.invalid_audio);
    if (stat.kind != .file) return fail(.invalid_audio);
    var file_reader = file.reader(io, &.{});
    const wav = file_reader.interface.allocRemaining(gpa, .limited(max_audio_bytes)) catch return fail(.invalid_audio);
    defer gpa.free(wav);
    const info = recorder.inspectWav(wav) catch return fail(.invalid_audio);
    if (info.channels != 1 or info.sample_rate != 16_000) return fail(.invalid_audio);
    if (info.seconds < 0.3) return fail(.audio_too_short);
    if (info.seconds > 300) return fail(.audio_too_long);
    const stt: provider.SttConfig = .{
        .api_key = r.deepgram_api_key,
        .model = r.deepgram_model,
        .language = r.deepgram_language,
        .region = r.deepgram_region,
        .keyterms = r.deepgram_keyterms,
        .smart_format = r.deepgram_smart_format,
        .punctuate = r.deepgram_punctuate,
        .dictation = r.deepgram_dictation,
        .numerals = r.deepgram_numerals,
        .measurements = r.deepgram_measurements,
        .streaming = false,
    };
    var context: CoreContext = .{ .io = io, .request = &r, .seam = seam, .stt = &stt, .wav = wav };
    const streamed_owned = if (streamed) |text| gpa.dupe(u8, text) catch return fail(.internal) else null;
    const transport: Transport = if (streamed != null) .stream else .rest;
    const outcome = provider_processing.process(gpa, streamed_owned, r.cleanup_enabled and r.groq_api_key.len > 0, .{
        .max_bytes = max_output_bytes,
        .require_utf8 = true,
    }, .{
        .context = &context,
        .rest = coreRest,
        .cleanup = coreCleanup,
    }) catch |err| return failWithTransport(
        if (err == error.ResponseTooLarge) .response_too_large else mapDeepgramError(err),
        transport,
    );
    return switch (outcome) {
        .no_speech => .{ .status = .no_speech, .transport = transport },
        .success => |value| .{
            .status = .success,
            .text = value.text,
            .warning = if (value.warning != null) .cleanup_failed else null,
            .transport = transport,
        },
    };
}

const CoreContext = struct {
    io: std.Io,
    request: *const Request,
    seam: Seam,
    stt: *const provider.SttConfig,
    wav: []const u8,
};

fn coreRest(context_ptr: ?*anyopaque, gpa: std.mem.Allocator) ![]u8 {
    const context: *CoreContext = @ptrCast(@alignCast(context_ptr.?));
    return context.seam.transcribe(context.seam.context, gpa, context.io, context.stt, context.wav);
}

fn coreCleanup(context_ptr: ?*anyopaque, gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    const context: *CoreContext = @ptrCast(@alignCast(context_ptr.?));
    const llm: provider.LlmConfig = .{
        .api_key = context.request.groq_api_key,
        .model = context.request.groq_model,
        .base_url = context.request.groq_base_url,
    };
    return context.seam.cleanup(context.seam.context, gpa, context.io, &llm, context.request.deepgram_keyterms, raw);
}

fn fail(code: ErrorCode) Result {
    return .{ .status = .@"error", .@"error" = code };
}

fn failWithTransport(code: ErrorCode, transport: Transport) Result {
    return .{ .status = .@"error", .@"error" = code, .transport = transport };
}

fn safeSecret(secret: []const u8) bool {
    for (secret) |byte| {
        if (std.ascii.isWhitespace(byte) or std.ascii.isControl(byte)) return false;
    }
    return true;
}

fn safeProviderValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '.' and byte != '_') return false;
    return true;
}

pub fn safeLlmModel(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    const slash = std.mem.indexOfScalar(u8, value, '/');
    if (slash) |at| {
        if (at == 0 or at + 1 == value.len or std.mem.indexOfScalar(u8, value[at + 1 ..], '/') != null) return false;
        return safeProviderValue(value[0..at]) and safeProviderValue(value[at + 1 ..]);
    }
    return safeProviderValue(value);
}

fn validRegion(region: []const u8) bool {
    return std.mem.eql(u8, region, "global") or std.mem.eql(u8, region, "eu") or std.mem.eql(u8, region, "au");
}

test "batch LLM model validation accepts one optional namespace" {
    try std.testing.expect(safeLlmModel("openai/gpt-oss-20b"));
    try std.testing.expect(!safeLlmModel("/openai"));
    try std.testing.expect(!safeLlmModel("openai/"));
    try std.testing.expect(!safeLlmModel("a/b/c"));
    var overlong: [65]u8 = @splat('a');
    try std.testing.expect(!safeLlmModel(&overlong));
}

pub fn mapDeepgramError(err: anyerror) ErrorCode {
    return switch (err) {
        error.MissingApiKey => .missing_deepgram_key,
        error.Unauthorized => .deepgram_unauthorized,
        error.RateLimited => .deepgram_rate_limited,
        error.ServerError => .deepgram_server,
        error.RequestFailed => .deepgram_network,
        error.ResponseTooLarge => .response_too_large,
        else => .internal,
    };
}

pub fn stringifyResult(gpa: std.mem.Allocator, result: Result) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(gpa, result, .{ .emit_null_optional_fields = false });
    if (bytes.len > max_output_bytes) {
        gpa.free(bytes);
        return error.ResponseTooLarge;
    }
    return bytes;
}

/// Requires protocol fields and validates status-specific semantics while
/// allowing unknown additive object fields.
pub fn parseResult(gpa: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(WireResult) {
    if (bytes.len == 0 or bytes.len > max_output_bytes) return error.InvalidResult;
    const parsed = std.json.parseFromSlice(WireResult, gpa, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidResult;
    errdefer parsed.deinit();
    const value = parsed.value;
    if (value.version != worker_protocol.version) return error.IncompatibleVersion;
    switch (value.status) {
        .success => if (value.text == null or value.text.?.len == 0 or value.@"error" != null) return error.InvalidResult,
        .no_speech => if (value.text != null or value.warning != null or value.@"error" != null) return error.InvalidResult,
        .@"error" => if (value.@"error" == null or value.text != null or value.warning != null) return error.InvalidResult,
    }
    return parsed;
}

fn liveTranscribe(_: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, cfg: *const provider.SttConfig, wav: []const u8) ![]u8 {
    return deepgram.transcribe(gpa, io, cfg, wav, false);
}

fn liveCleanup(_: ?*anyopaque, gpa: std.mem.Allocator, io: std.Io, cfg: *const provider.LlmConfig, keyterms: []const []const u8, raw: []const u8) ![]u8 {
    return groq.cleanup(gpa, io, cfg, keyterms, raw, false);
}

const FakeProvider = struct {
    transcript: []const u8 = "München",
    cleanup_fails: bool = false,
    expected_region: []const u8 = "global",
    expected_formatting: bool = false,

    fn transcribe(context: ?*anyopaque, gpa: std.mem.Allocator, _: std.Io, cfg: *const provider.SttConfig, _: []const u8) ![]u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        if (!std.mem.eql(u8, cfg.region, self.expected_region)) return error.UnexpectedRegion;
        if (cfg.smart_format != self.expected_formatting or cfg.punctuate != self.expected_formatting or
            cfg.dictation != self.expected_formatting or cfg.numerals != self.expected_formatting or
            cfg.measurements != self.expected_formatting) return error.UnexpectedFormatting;
        return gpa.dupe(u8, self.transcript);
    }

    fn cleanup(context: ?*anyopaque, gpa: std.mem.Allocator, _: std.Io, _: *const provider.LlmConfig, _: []const []const u8, raw: []const u8) ![]u8 {
        const self: *FakeProvider = @ptrCast(@alignCast(context.?));
        if (self.cleanup_fails) return error.RequestFailed;
        return std.fmt.allocPrint(gpa, "clean: {s}", .{raw});
    }

    fn seam(self: *FakeProvider) Seam {
        return .{ .context = self, .transcribe = transcribe, .cleanup = cleanup };
    }
};

fn writeTestWav(tmp: *std.testing.TmpDir, sample_bytes: usize) ![]u8 {
    try tmp.dir.setPermissions(std.testing.io, .fromMode(0o700));
    const pcm = try std.testing.allocator.alloc(u8, sample_bytes);
    defer std.testing.allocator.free(pcm);
    @memset(pcm, 0);
    const wav = try recorder.wavFromPcm(std.testing.allocator, pcm);
    defer std.testing.allocator.free(wav);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "clip.wav", .data = wav });
    var file = try tmp.dir.openFile(std.testing.io, "clip.wav", .{});
    defer file.close(std.testing.io);
    try file.setPermissions(std.testing.io, .fromMode(0o600));
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/clip.wav", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);
    const real_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(real_path);
    return std.testing.allocator.dupe(u8, real_path);
}

test "strict bounded request and result JSON" {
    const json = "{\"version\":2,\"wav_path\":\"/a\",\"deepgram_api_key\":\"d\",\"groq_api_key\":\"g\",\"cleanup_enabled\":true}";
    const parsed = try parseRequest(std.testing.allocator, json);
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidRequest, parseRequest(std.testing.allocator, json ++ "x"));
    const out = try stringifyResult(std.testing.allocator, .{ .status = .success, .text = "München" });
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "München") != null);
}

test "worker result decoder requires fields and status semantics" {
    const valid = try parseResult(std.testing.allocator, "{\"version\":2,\"status\":\"success\",\"text\":\"hello\",\"future\":true}");
    defer valid.deinit();
    try std.testing.expectEqualStrings("hello", valid.value.text.?);
    for ([_][]const u8{
        "{\"status\":\"success\",\"text\":\"hello\"}",
        "{\"version\":2,\"status\":\"success\"}",
        "{\"version\":2,\"status\":\"success\",\"text\":\"\"}",
        "{\"version\":2,\"status\":\"no_speech\",\"text\":\"unexpected\"}",
        "{\"version\":2,\"status\":\"error\"}",
    }) |invalid_json| try std.testing.expectError(error.InvalidResult, parseResult(std.testing.allocator, invalid_json));
}

test "provider mapping is deterministic" {
    try std.testing.expectEqual(ErrorCode.deepgram_unauthorized, mapDeepgramError(error.Unauthorized));
    try std.testing.expectEqual(ErrorCode.deepgram_rate_limited, mapDeepgramError(error.RateLimited));
    try std.testing.expectEqual(ErrorCode.deepgram_server, mapDeepgramError(error.ServerError));
}

test "process validates canonical audio and preserves raw transcript when cleanup fails" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try writeTestWav(&tmp, 16_000);
    defer std.testing.allocator.free(path);
    const request: Request = .{
        .version = worker_protocol.version,
        .wav_path = path,
        .deepgram_api_key = "deepgram",
        .deepgram_region = "eu",
        .deepgram_smart_format = true,
        .deepgram_punctuate = true,
        .deepgram_dictation = true,
        .deepgram_numerals = true,
        .deepgram_measurements = true,
        .groq_api_key = "groq",
        .cleanup_enabled = true,
    };
    var fake: FakeProvider = .{ .cleanup_fails = true, .expected_region = "eu", .expected_formatting = true };
    const result = process(std.testing.allocator, std.testing.io, request, fake.seam());
    defer if (result.text) |text| std.testing.allocator.free(text);
    try std.testing.expectEqual(.success, result.status);
    try std.testing.expectEqual(Transport.rest, result.transport.?);
    try std.testing.expectEqual(Warning.cleanup_failed, result.warning.?);
    try std.testing.expectEqualStrings("München", result.text.?);

    const streamed = processWithTranscript(std.testing.allocator, std.testing.io, request, fake.seam(), "streamed");
    defer if (streamed.text) |text| std.testing.allocator.free(text);
    try std.testing.expectEqual(.success, streamed.status);
    try std.testing.expectEqual(Transport.stream, streamed.transport.?);
    try std.testing.expectEqualStrings("streamed", streamed.text.?);
}

test "process distinguishes short and invalid audio without calling providers" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try writeTestWav(&tmp, 2);
    defer std.testing.allocator.free(path);
    const request: Request = .{
        .version = worker_protocol.version,
        .wav_path = path,
        .deepgram_api_key = "deepgram",
        .groq_api_key = "",
        .cleanup_enabled = false,
    };
    var fake: FakeProvider = .{};
    const result = process(std.testing.allocator, std.testing.io, request, fake.seam());
    try std.testing.expectEqual(ErrorCode.audio_too_short, result.@"error".?);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "clip.wav", .data = "not a wav" });
    const invalid = process(std.testing.allocator, std.testing.io, request, fake.seam());
    try std.testing.expectEqual(ErrorCode.invalid_audio, invalid.@"error".?);
}

test "process rejects incompatible requests and oversized provider output" {
    var fake: FakeProvider = .{};
    const incompatible = process(std.testing.allocator, std.testing.io, .{
        .version = 2,
        .wav_path = "/unused",
        .deepgram_api_key = "deepgram",
        .groq_api_key = "",
        .cleanup_enabled = false,
    }, fake.seam());
    try std.testing.expectEqual(ErrorCode.incompatible_version, incompatible.@"error".?);

    const oversized = try std.testing.allocator.alloc(u8, max_output_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    fake.transcript = oversized;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const path = try writeTestWav(&tmp, 16_000);
    defer std.testing.allocator.free(path);
    const result = process(std.testing.allocator, std.testing.io, .{
        .version = worker_protocol.version,
        .wav_path = path,
        .deepgram_api_key = "deepgram",
        .groq_api_key = "",
        .cleanup_enabled = false,
    }, fake.seam());
    try std.testing.expectEqual(ErrorCode.response_too_large, result.@"error".?);
}
