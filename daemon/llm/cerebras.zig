const std = @import("std");
const transport = @import("openai_compatible.zig");

pub const endpoint = "https://api.cerebras.ai/v1/chat/completions";
pub const model = "gpt-oss-120b";
pub const Error = transport.Error;

pub const Message = struct { role: []const u8, content: []const u8 };
const ResponseFormat = struct { type: []const u8 = "json_schema", json_schema: struct { name: []const u8, strict: bool = true, schema: std.json.Value } };
const Payload = struct {
    model: []const u8,
    max_completion_tokens: u32 = 2048,
    reasoning_effort: []const u8 = "low",
    temperature: u8 = 0,
    response_format: ResponseFormat,
    messages: []const Message,
};

pub fn supports(candidate: []const u8) bool {
    return std.mem.eql(u8, candidate, model);
}

pub fn chat(gpa: std.mem.Allocator, io: std.Io, api_key: []const u8, candidate_endpoint: []const u8, candidate_model: []const u8, schema_name: []const u8, schema: std.json.Value, messages: []const Message, verbose: bool) Error![]u8 {
    if (!supports(candidate_model) or !std.mem.eql(u8, candidate_endpoint, endpoint)) return error.BadResponse;
    const payload: Payload = .{ .model = candidate_model, .response_format = .{ .json_schema = .{ .name = schema_name, .schema = schema } }, .messages = messages };
    const json = std.json.Stringify.valueAlloc(gpa, payload, .{}) catch return error.OutOfMemory;
    defer gpa.free(json);
    return transport.post(gpa, io, candidate_endpoint, api_key, json, verbose);
}

test "only production model and endpoint are supported" {
    try std.testing.expect(supports(model));
    try std.testing.expect(!supports("openai/gpt-oss-20b"));
}

test "payload bounds completion and requests strict structured output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), "{\"type\":\"object\",\"properties\":{},\"required\":[],\"additionalProperties\":false}", .{});
    const payload: Payload = .{
        .model = model,
        .response_format = .{ .json_schema = .{ .name = "test", .schema = schema } },
        .messages = &.{.{ .role = "user", .content = "test" }},
    };
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{});
    defer std.testing.allocator.free(encoded);
    const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer decoded.deinit();
    const object = decoded.value.object;
    try std.testing.expectEqual(@as(i64, 2048), object.get("max_completion_tokens").?.integer);
    try std.testing.expectEqual(@as(i64, 0), object.get("temperature").?.integer);
    try std.testing.expect(object.get("response_format").?.object.get("json_schema").?.object.get("strict").?.bool);
}
