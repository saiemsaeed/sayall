//! Test-only process boundary for the synthetic transformation benchmark.
//! Production transformation functions remain the single implementation under test.
const std = @import("std");
const groq = @import("llm/groq.zig");
const provider = @import("provider_config.zig");
const processing = @import("processing.zig");
const provider_processing = @import("provider_processing.zig");

const Mode = enum { verbatim, clean, polished };
const Fault = enum { malformed_plan, unsafe_plan };
const Request = struct {
    schema_version: u32,
    mode: Mode,
    input: []const u8,
    groq_api_key: []const u8,
    model: []const u8,
    fault: ?Fault = null,
};
const Outcome = enum { applied, safe_fallback, adapter_error };
const Response = struct {
    schema_version: u32 = 1,
    outcome: Outcome,
    output: ?[]const u8,
    fallback_reason: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) u8 {
    run(init) catch return 1;
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    var storage: [256 * 1024]u8 = undefined;
    var reader = std.Io.File.stdin().reader(init.io, &storage);
    const input = try reader.interface.allocRemaining(gpa, .limited(storage.len));
    defer gpa.free(input);
    const parsed = try std.json.parseFromSlice(Request, gpa, input, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const request = parsed.value;
    if (request.schema_version != 1) return error.InvalidRequest;

    const transformed = transform(gpa, init.io, request);
    defer if (transformed) |output| gpa.free(output) else |_| {};
    // Inject only after the real mode API has returned or failed. The benchmark
    // never relies on a provider to produce a malformed or unsafe plan.
    const response: Response = if (request.fault) |fault| .{
        .outcome = .safe_fallback,
        .output = request.input,
        .fallback_reason = @tagName(fault),
    } else if (transformed) |output| .{
        .outcome = .applied,
        .output = output,
    } else |err| switch (err) {
        error.OutOfMemory => .{ .outcome = .adapter_error, .output = null },
        else => .{
            .outcome = .safe_fallback,
            .output = request.input,
            .fallback_reason = if (err == error.InvalidPlan)
                "adapter_rejection"
            else if (err == error.MissingApiKey)
                "missing_credential"
            else
                "provider_error",
        },
    };
    const json = try std.json.Stringify.valueAlloc(gpa, response, .{ .emit_null_optional_fields = true });
    defer gpa.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn transform(gpa: std.mem.Allocator, io: std.Io, request: Request) ![]u8 {
    return switch (request.mode) {
        .verbatim => verbatim(gpa, request.input),
        .clean => groq.clean(gpa, request.input, &.{}),
        .polished => groq.polished(gpa, io, &provider.LlmConfig{
            .api_key = request.groq_api_key,
            .model = request.model,
            .enabled = true,
        }, &.{}, request.input, false),
    };
}

fn verbatim(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    const owned = try gpa.dupe(u8, input);
    const outcome = try provider_processing.process(
        gpa,
        owned,
        .verbatim,
        .{ .max_bytes = null, .require_utf8 = false },
        .{ .rest = unexpectedRest, .clean = unexpectedClean, .planner = unexpectedPlanner },
    );
    return switch (outcome) {
        .success => |success| success.text,
        .no_speech => error.UnexpectedNoSpeech,
    };
}

fn unexpectedRest(_: ?*anyopaque, _: std.mem.Allocator) ![]u8 {
    return error.UnexpectedProviderCall;
}

fn unexpectedClean(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) ![]u8 {
    return error.UnexpectedProviderCall;
}

fn unexpectedPlanner(_: ?*anyopaque, _: std.mem.Allocator, _: processing.Profile, _: []const u8) ![]u8 {
    return error.UnexpectedProviderCall;
}

test "benchmark request and response schemas stay closed" {
    const request = try std.json.parseFromSlice(Request, std.testing.allocator, "{\"schema_version\":1,\"mode\":\"clean\",\"input\":\"um test\",\"groq_api_key\":\"\",\"model\":\"openai/gpt-oss-20b\"}", .{ .ignore_unknown_fields = false });
    defer request.deinit();
    try std.testing.expectEqual(Mode.clean, request.value.mode);
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Request, std.testing.allocator, "{\"schema_version\":1,\"mode\":\"clean\",\"input\":\"x\",\"groq_api_key\":\"\",\"model\":\"openai/gpt-oss-20b\",\"raw_provider_body\":\"no\"}", .{ .ignore_unknown_fields = false }));
}
