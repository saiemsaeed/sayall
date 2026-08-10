//! Test-only process boundary for the synthetic transformation benchmark.
//! Production transformation functions remain the single implementation under test.
const std = @import("std");
const cloud_planner = @import("llm/cloud_planner.zig");
const provider = @import("provider_config.zig");
const processing = @import("processing.zig");
const provider_processing = @import("provider_processing.zig");

const Mode = enum { verbatim, clean, polished };
const Fault = enum { malformed_plan, unsafe_plan };
const Request = struct {
    schema_version: u32,
    mode: Mode,
    input: []const u8,
    llm_api_key: []const u8,
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
const TransformResult = struct {
    output: []u8,
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
    defer if (transformed) |result| gpa.free(result.output) else |_| {};
    const response: Response = if (transformed) |result| .{
        .outcome = if (result.fallback_reason == null) .applied else .safe_fallback,
        .output = result.output,
        .fallback_reason = result.fallback_reason,
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

fn transform(gpa: std.mem.Allocator, io: std.Io, request: Request) !TransformResult {
    var context: BenchmarkContext = .{ .io = io, .request = &request };
    const profile: processing.Profile = switch (request.mode) {
        .verbatim => .verbatim,
        .clean => .clean,
        .polished => .polished,
    };
    const owned = try gpa.dupe(u8, request.input);
    const outcome = try provider_processing.process(
        gpa,
        owned,
        profile,
        .{ .max_bytes = null, .require_utf8 = false },
        .{ .context = &context, .rest = unexpectedRest, .clean = benchmarkClean, .baseline = benchmarkBaseline, .planner = benchmarkPlanner },
    );
    return switch (outcome) {
        .success => |success| .{
            .output = success.text,
            .fallback_reason = if (success.warning != null or success.transformation_outcome == .degraded)
                if (request.fault) |fault|
                    @tagName(fault)
                else if (request.llm_api_key.len == 0)
                    "missing_credential"
                else
                    "provider_error"
            else
                null,
        },
        .no_speech => error.UnexpectedNoSpeech,
    };
}

const BenchmarkContext = struct {
    io: std.Io,
    request: *const Request,
};

fn unexpectedRest(_: ?*anyopaque, _: std.mem.Allocator) ![]u8 {
    return error.UnexpectedProviderCall;
}

fn benchmarkClean(context_ptr: ?*anyopaque, gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    const context: *BenchmarkContext = @ptrCast(@alignCast(context_ptr.?));
    if (context.request.fault == .unsafe_plan) return error.InvalidPlan;
    return cloud_planner.clean(gpa, input, &.{});
}

fn benchmarkBaseline(_: ?*anyopaque, gpa: std.mem.Allocator, input: []const u8) !cloud_planner.cleanup_engine.PolishedBaseline {
    return cloud_planner.cleanup_engine.polishedBaseline(gpa, input, &.{});
}

fn benchmarkPlanner(context_ptr: ?*anyopaque, gpa: std.mem.Allocator, profile: processing.Profile, input: []const u8) ![]u8 {
    const context: *BenchmarkContext = @ptrCast(@alignCast(context_ptr.?));
    if (context.request.fault != null) return error.InvalidPlan;
    if (profile != .polished) return error.InvalidProfile;
    return cloud_planner.polished(gpa, context.io, &provider.LlmConfig{
        .api_key = context.request.llm_api_key,
        .model = context.request.model,
        .enabled = true,
    }, &.{}, input, false);
}

test "benchmark request and response schemas stay closed" {
    const request = try std.json.parseFromSlice(Request, std.testing.allocator, "{\"schema_version\":1,\"mode\":\"clean\",\"input\":\"um test\",\"llm_api_key\":\"\",\"model\":\"gpt-oss-120b\"}", .{ .ignore_unknown_fields = false });
    defer request.deinit();
    try std.testing.expectEqual(Mode.clean, request.value.mode);
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Request, std.testing.allocator, "{\"schema_version\":1,\"mode\":\"clean\",\"input\":\"x\",\"llm_api_key\":\"\",\"model\":\"gpt-oss-120b\",\"raw_provider_body\":\"no\"}", .{ .ignore_unknown_fields = false }));
}
