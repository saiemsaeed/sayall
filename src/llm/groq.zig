const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");

pub const CleanupError = error{
    MissingApiKey,
    RequestFailed,
    BadStatus,
    BadResponse,
    EmptyResponse,
    ResponseTooLarge,
    OutOfMemory,
};

pub const system_prompt =
    \\Rewrite the following speech transcript into clean written text.
    \\Remove filler words (um, uh, like, you know), false starts, and stutters.
    \\Fix grammar and punctuation. Never add information, never change meaning,
    \\never answer questions contained in the text. Preserve the speaker's tone
    \\and word choice wherever possible. Output ONLY the rewritten text.
;

const Message = struct {
    role: []const u8,
    content: []const u8,
};

const Payload = struct {
    model: []const u8,
    temperature: f32 = 0.0,
    max_completion_tokens: u32 = 4096,
    messages: []const Message,
};

const ChatResponse = struct {
    choices: []struct {
        message: struct {
            role: []const u8,
            content: []const u8,
        },
    },
};

/// Cleans up a raw transcript with an OpenAI-compatible chat completions API
/// (Groq by default). Returns an owned slice on success.
pub fn cleanup(gpa: Allocator, io: Io, cfg: *const config.LlmConfig, keyterms: []const []const u8, transcript: []const u8, verbose: bool) CleanupError![]u8 {
    if (cfg.api_key.len == 0) return error.MissingApiKey;

    const cleanup_prompt = promptWithKeyterms(gpa, keyterms) catch return error.OutOfMemory;
    defer gpa.free(cleanup_prompt);
    const payload = Payload{
        .model = cfg.model,
        .messages = &.{
            .{ .role = "system", .content = cleanup_prompt },
            .{ .role = "user", .content = transcript },
        },
    };
    const payload_json = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return error.OutOfMemory;
    defer gpa.free(payload_json);

    const auth = std.fmt.allocPrint(gpa, "Bearer {s}", .{cfg.api_key}) catch return error.OutOfMemory;
    defer gpa.free(auth);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const response_storage = gpa.alloc(u8, 1024 * 1024) catch return error.OutOfMemory;
    defer gpa.free(response_storage);
    var body = Io.Writer.fixed(response_storage);

    const result = client.fetch(.{
        .location = .{ .url = cfg.base_url },
        .method = .POST,
        .payload = payload_json,
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
        },
        .response_writer = &body,
    }) catch |err| {
        if (err == error.WriteFailed) return error.ResponseTooLarge;
        logVerbose(verbose, "llm request failed: {s}", .{@errorName(err)});
        return error.RequestFailed;
    };

    const response_bytes = body.buffered();
    if (result.status != .ok) {
        logVerbose(verbose, "llm status {d}", .{@intFromEnum(result.status)});
        return error.BadStatus;
    }

    const parsed = std.json.parseFromSlice(ChatResponse, gpa, response_bytes, .{
        .ignore_unknown_fields = true,
    }) catch {
        logVerbose(verbose, "llm returned invalid JSON", .{});
        return error.BadResponse;
    };
    defer parsed.deinit();

    if (parsed.value.choices.len == 0) return error.EmptyResponse;

    const trimmed = std.mem.trim(u8, parsed.value.choices[0].message.content, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyResponse;
    if (trimmed.len > transcript.len * 2 + 256) return error.BadResponse;
    return gpa.dupe(u8, trimmed) catch return error.OutOfMemory;
}

fn promptWithKeyterms(gpa: Allocator, keyterms: []const []const u8) Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(gpa);
    try result.appendSlice(gpa, system_prompt);
    if (keyterms.len > 0) {
        try result.appendSlice(gpa, "\nPreserve the spelling and capitalization of these glossary terms when they occur; do not insert them otherwise:");
        for (keyterms) |keyterm| {
            try result.appendSlice(gpa, "\n- ");
            try result.appendSlice(gpa, keyterm);
        }
    }
    return result.toOwnedSlice(gpa);
}

fn logVerbose(verbose: bool, comptime fmt: []const u8, args: anytype) void {
    if (verbose) std.debug.print("sayall: " ++ fmt ++ "\n", args);
}

test "parses a realistic chat completions response" {
    const json =
        \\{"id":"chatcmpl-1","object":"chat.completion","created":1,"model":"llama-3.1-8b-instant",
        \\"choices":[{"index":0,"message":{"role":"assistant","content":" Clean text. "},"finish_reason":"stop"}],
        \\"usage":{"prompt_tokens":10,"completion_tokens":4}}
    ;
    const parsed = try std.json.parseFromSlice(ChatResponse, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(" Clean text. ", parsed.value.choices[0].message.content);
}

test "cleanup prompt includes keyterms as spelling hints" {
    const prompt = try promptWithKeyterms(std.testing.allocator, &.{ "SayAll", "Model Context Protocol" });
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "\n- SayAll\n- Model Context Protocol"));
}
