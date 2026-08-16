const std = @import("std");

pub const Error = error{ RequestFailed, RateLimited, BadStatus, BadResponse, EmptyResponse, ResponseTooLarge, OutOfMemory };

const ChatResponse = struct { choices: []struct { message: struct { content: []const u8 } } };

/// Bounded, single-attempt OpenAI chat-completions transport. The response
/// body is decoded locally and is never logged.
pub fn post(gpa: std.mem.Allocator, io: std.Io, endpoint: []const u8, api_key: []const u8, payload: []const u8, verbose: bool) Error![]u8 {
    const auth = std.fmt.allocPrint(gpa, "Bearer {s}", .{api_key}) catch return error.OutOfMemory;
    defer gpa.free(auth);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const storage = gpa.alloc(u8, 512 * 1024) catch return error.OutOfMemory;
    defer gpa.free(storage);
    var body = std.Io.Writer.fixed(storage);
    const result = client.fetch(.{ .location = .{ .url = endpoint }, .method = .POST, .payload = payload, .headers = .{
        .authorization = .{ .override = auth },
        .content_type = .{ .override = "application/json" },
    }, .response_writer = &body }) catch |err| {
        if (err == error.WriteFailed) return error.ResponseTooLarge;
        if (verbose) std.log.warn("llm request failed: {s}", .{@errorName(err)});
        return error.RequestFailed;
    };
    if (result.status == .too_many_requests) return error.RateLimited;
    if (result.status != .ok) {
        if (verbose) std.log.warn("llm status {d}", .{@intFromEnum(result.status)});
        return error.BadStatus;
    }
    const response = std.json.parseFromSlice(ChatResponse, gpa, body.buffered(), .{ .ignore_unknown_fields = true }) catch return error.BadResponse;
    defer response.deinit();
    if (response.value.choices.len == 0) return error.EmptyResponse;
    const content = response.value.choices[0].message.content;
    if (content.len == 0 or content.len > 128 * 1024) return error.BadResponse;
    return gpa.dupe(u8, content) catch error.OutOfMemory;
}
