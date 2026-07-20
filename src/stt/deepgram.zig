const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");

pub const TranscribeError = error{
    MissingApiKey,
    RequestFailed,
    BadStatus,
    BadResponse,
    ResponseTooLarge,
    OutOfMemory,
};

const DeepgramResponse = struct {
    results: struct {
        channels: []struct {
            alternatives: []struct {
                transcript: []const u8,
            },
        },
    },
};

/// Transcribes a WAV file with Deepgram Nova. Returns an owned slice
/// (whitespace-trimmed) on success.
pub fn transcribe(gpa: Allocator, io: Io, cfg: *const config.SttConfig, wav: []const u8, verbose: bool) TranscribeError![]u8 {
    if (cfg.api_key.len == 0) return error.MissingApiKey;

    const url = std.fmt.allocPrint(
        gpa,
        "{s}?model={s}&smart_format=true&punctuate=true&language={s}",
        .{ restBaseUrl(cfg.region), cfg.model, cfg.language },
    ) catch return error.OutOfMemory;
    defer gpa.free(url);

    const auth = std.fmt.allocPrint(gpa, "Token {s}", .{cfg.api_key}) catch return error.OutOfMemory;
    defer gpa.free(auth);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const response_storage = gpa.alloc(u8, 1024 * 1024) catch return error.OutOfMemory;
    defer gpa.free(response_storage);
    var body = Io.Writer.fixed(response_storage);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = wav,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "audio/wav" },
        },
        .response_writer = &body,
    }) catch |err| {
        if (err == error.WriteFailed) return error.ResponseTooLarge;
        logVerbose(verbose, "deepgram request failed: {s}", .{@errorName(err)});
        return error.RequestFailed;
    };

    const response_bytes = body.buffered();
    if (result.status != .ok) {
        logVerbose(verbose, "deepgram status {d}", .{@intFromEnum(result.status)});
        return error.BadStatus;
    }

    const parsed = std.json.parseFromSlice(DeepgramResponse, gpa, response_bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        logVerbose(verbose, "deepgram returned invalid JSON", .{});
        return error.BadResponse;
    };
    defer parsed.deinit();

    const channels = parsed.value.results.channels;
    if (channels.len == 0 or channels[0].alternatives.len == 0) {
        return gpa.dupe(u8, "") catch return error.OutOfMemory;
    }

    const trimmed = std.mem.trim(u8, channels[0].alternatives[0].transcript, " \t\r\n");
    return gpa.dupe(u8, trimmed) catch return error.OutOfMemory;
}

pub fn restBaseUrl(region: []const u8) []const u8 {
    if (std.mem.eql(u8, region, "eu")) return "https://api.eu.deepgram.com/v1/listen";
    if (std.mem.eql(u8, region, "au")) return "https://api.au.deepgram.com/v1/listen";
    return "https://api.deepgram.com/v1/listen";
}

fn logVerbose(verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (verbose) std.debug.print("sayall: " ++ fmt ++ "\n", args);
}

test "parses a realistic deepgram response" {
    const json =
        \\{"metadata":{"transaction_key":"deprecated","request_id":"abc","sha256":"x","created":"2026-07-17T00:00:00.000Z","duration":1.5,"channels":1},
        \\"results":{"channels":[{"alternatives":[{"transcript":" hello world ","confidence":0.99,"words":[],"paragraphs":{}}]}]}}
    ;
    const parsed = try std.json.parseFromSlice(DeepgramResponse, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const t = parsed.value.results.channels[0].alternatives[0].transcript;
    try std.testing.expectEqualStrings(" hello world ", t);
}

test "regional endpoints are allow-listed" {
    try std.testing.expectEqualStrings("https://api.deepgram.com/v1/listen", restBaseUrl("global"));
    try std.testing.expectEqualStrings("https://api.eu.deepgram.com/v1/listen", restBaseUrl("eu"));
    try std.testing.expectEqualStrings("https://api.au.deepgram.com/v1/listen", restBaseUrl("au"));
}
