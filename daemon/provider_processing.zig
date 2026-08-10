const std = @import("std");
const processing = @import("processing.zig");
const cleanup_engine = @import("llm/cleanup_engine.zig");

pub const Warning = enum { transformation_failed };

pub const Success = struct {
    text: []u8,
    warning: ?Warning = null,
    transformation_outcome: processing.TransformationOutcome,
};

pub const Outcome = union(enum) {
    success: Success,
    no_speech,
};

pub const OutputPolicy = struct {
    max_bytes: ?usize,
    require_utf8: bool,
};

pub const Seam = struct {
    context: ?*anyopaque = null,
    rest: *const fn (?*anyopaque, std.mem.Allocator) anyerror![]u8,
    clean: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
    baseline: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!cleanup_engine.PolishedBaseline,
    planner: *const fn (?*anyopaque, std.mem.Allocator, processing.Profile, []const u8) anyerror![]u8,
};

/// Selects a completed stream (including an empty transcript) or performs one
/// REST attempt, then validates and optionally cleans the selected transcript.
/// `streamed_owned`, provider callback results, and successful outcome text are
/// allocator-owned. This function takes ownership of `streamed_owned`.
pub fn process(
    allocator: std.mem.Allocator,
    streamed_owned: ?[]u8,
    profile: processing.Profile,
    output_policy: OutputPolicy,
    seam: Seam,
) !Outcome {
    const raw = streamed_owned orelse try seam.rest(seam.context, allocator);
    errdefer allocator.free(raw);

    try validate(raw, output_policy);
    if (raw.len == 0) {
        allocator.free(raw);
        return .no_speech;
    }

    if (profile == .ai_only) {
        const planned = seam.planner(seam.context, allocator, profile, raw) catch {
            return .{ .success = .{ .text = raw, .warning = .transformation_failed, .transformation_outcome = .failed } };
        };
        validate(planned, output_policy) catch {
            allocator.free(planned);
            return .{ .success = .{ .text = raw, .warning = .transformation_failed, .transformation_outcome = .failed } };
        };
        const outcome: processing.TransformationOutcome = if (std.mem.eql(u8, raw, planned)) .no_change else .changed;
        allocator.free(raw);
        return .{ .success = .{ .text = planned, .transformation_outcome = outcome } };
    }

    if (profile == .polished) {
        const baseline = seam.baseline(seam.context, allocator, raw) catch {
            return .{ .success = .{ .text = raw, .warning = .transformation_failed, .transformation_outcome = .failed } };
        };
        validate(baseline.text, output_policy) catch {
            allocator.free(baseline.text);
            return .{ .success = .{ .text = raw, .warning = .transformation_failed, .transformation_outcome = .failed } };
        };
        if (baseline.sufficient) {
            const outcome: processing.TransformationOutcome = if (std.mem.eql(u8, raw, baseline.text)) .no_change else .changed;
            allocator.free(raw);
            return .{ .success = .{ .text = baseline.text, .transformation_outcome = outcome } };
        }
        const planned = seam.planner(seam.context, allocator, profile, baseline.text) catch {
            allocator.free(raw);
            return .{ .success = .{ .text = baseline.text, .transformation_outcome = .degraded } };
        };
        validate(planned, output_policy) catch {
            allocator.free(planned);
            allocator.free(raw);
            return .{ .success = .{ .text = baseline.text, .transformation_outcome = .degraded } };
        };
        allocator.free(baseline.text);
        const outcome: processing.TransformationOutcome = if (std.mem.eql(u8, raw, planned)) .no_change else .changed;
        allocator.free(raw);
        return .{ .success = .{ .text = planned, .transformation_outcome = outcome } };
    }
    const transformed_result = switch (profile) {
        .verbatim => return .{ .success = .{ .text = raw, .transformation_outcome = .not_requested } },
        .clean => seam.clean(seam.context, allocator, raw),
        .legacy_v1 => seam.planner(seam.context, allocator, profile, raw),
        .polished, .ai_only => unreachable,
    };
    if (transformed_result) |transformed| {
        validate(transformed, output_policy) catch {
            allocator.free(transformed);
            return .{ .success = .{ .text = raw, .warning = .transformation_failed, .transformation_outcome = .failed } };
        };
        const transformation_outcome: processing.TransformationOutcome = if (std.mem.eql(u8, raw, transformed)) .no_change else .changed;
        allocator.free(raw);
        return .{ .success = .{ .text = transformed, .transformation_outcome = transformation_outcome } };
    } else |_| {
        return .{ .success = .{ .text = raw, .warning = .transformation_failed, .transformation_outcome = .failed } };
    }
}

fn validate(text: []const u8, policy: OutputPolicy) !void {
    if (policy.max_bytes) |max_bytes| {
        if (text.len > max_bytes) return error.ResponseTooLarge;
    }
    if (policy.require_utf8 and !std.unicode.utf8ValidateSlice(text)) return error.ResponseTooLarge;
}

const Fake = struct {
    rest_text: []const u8 = "raw",
    clean_text: []const u8 = "clean",
    baseline_text: []const u8 = "baseline",
    baseline_sufficient: bool = false,
    rest_error: ?anyerror = null,
    cleanup_error: ?anyerror = null,
    planner_error: ?anyerror = null,
    rest_calls: usize = 0,
    clean_calls: usize = 0,
    planner_calls: usize = 0,
    baseline_calls: usize = 0,
    polished_calls: usize = 0,
    ai_only_calls: usize = 0,
    legacy_calls: usize = 0,
    expected_planner_input: ?[]const u8 = null,

    fn rest(context: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.rest_calls += 1;
        if (self.rest_error) |err| return err;
        return allocator.dupe(u8, self.rest_text);
    }

    fn clean(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.clean_calls += 1;
        if (self.cleanup_error) |err| return err;
        return allocator.dupe(u8, self.clean_text);
    }

    fn planner(context: ?*anyopaque, allocator: std.mem.Allocator, profile: processing.Profile, input: []const u8) ![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.planner_calls += 1;
        if (self.expected_planner_input) |expected| {
            if (!std.mem.eql(u8, expected, input)) return error.UnexpectedPlannerInput;
        }
        switch (profile) {
            .polished => self.polished_calls += 1,
            .ai_only => self.ai_only_calls += 1,
            .legacy_v1 => self.legacy_calls += 1,
            else => return error.InvalidProfile,
        }
        if (self.planner_error) |err| return err;
        if (self.cleanup_error) |err| return err;
        return allocator.dupe(u8, self.clean_text);
    }

    fn baseline(context: ?*anyopaque, allocator: std.mem.Allocator, raw: []const u8) !cleanup_engine.PolishedBaseline {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.baseline_calls += 1;
        if (self.cleanup_error) |err| return err;
        _ = raw;
        return .{ .text = try allocator.dupe(u8, self.baseline_text), .sufficient = self.baseline_sufficient };
    }

    fn seam(self: *Fake) Seam {
        return .{ .context = self, .rest = rest, .clean = clean, .baseline = baseline, .planner = planner };
    }
};

fn freeOutcome(outcome: Outcome) void {
    switch (outcome) {
        .success => |success| std.testing.allocator.free(success.text),
        .no_speech => {},
    }
}

const worker_policy: OutputPolicy = .{ .max_bytes = 1024, .require_utf8 = true };

fn owned(text: []const u8) ![]u8 {
    return std.testing.allocator.dupe(u8, text);
}

test "REST success is attempted exactly once" {
    var fake: Fake = .{};
    const outcome = try process(std.testing.allocator, null, .verbatim, worker_policy, fake.seam());
    defer freeOutcome(outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.rest_calls);
    try std.testing.expectEqualStrings("raw", outcome.success.text);
    try std.testing.expectEqual(processing.TransformationOutcome.not_requested, outcome.success.transformation_outcome);
}

test "stream success including empty never falls back to REST" {
    var fake: Fake = .{};
    const streamed = try process(std.testing.allocator, try owned("stream"), .verbatim, worker_policy, fake.seam());
    defer freeOutcome(streamed);
    try std.testing.expectEqual(@as(usize, 0), fake.rest_calls);
    try std.testing.expectEqualStrings("stream", streamed.success.text);
    const empty = try process(std.testing.allocator, try owned(""), .verbatim, worker_policy, fake.seam());
    try std.testing.expect(empty == .no_speech);
    try std.testing.expectEqual(@as(usize, 0), fake.rest_calls);
}

test "absent or failed stream is represented by one REST attempt" {
    var fake: Fake = .{ .rest_error = error.RequestFailed };
    try std.testing.expectError(error.RequestFailed, process(std.testing.allocator, null, .verbatim, worker_policy, fake.seam()));
    try std.testing.expectEqual(@as(usize, 1), fake.rest_calls);
}

test "all profiles route once and verbatim clean never invoke planner" {
    var fake: Fake = .{};
    const verbatim = try process(std.testing.allocator, null, .verbatim, worker_policy, fake.seam());
    defer freeOutcome(verbatim);
    try std.testing.expectEqualStrings("raw", verbatim.success.text);
    try std.testing.expectEqual(@as(usize, 0), fake.clean_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.planner_calls);

    const cleaned = try process(std.testing.allocator, null, .clean, worker_policy, fake.seam());
    defer freeOutcome(cleaned);
    try std.testing.expectEqualStrings("clean", cleaned.success.text);
    try std.testing.expectEqual(@as(?Warning, null), cleaned.success.warning);
    try std.testing.expectEqual(processing.TransformationOutcome.changed, cleaned.success.transformation_outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.clean_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.planner_calls);

    const polished = try process(std.testing.allocator, null, .polished, worker_policy, fake.seam());
    defer freeOutcome(polished);
    try std.testing.expectEqual(@as(usize, 1), fake.planner_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.polished_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.legacy_calls);

    const legacy = try process(std.testing.allocator, null, .legacy_v1, worker_policy, fake.seam());
    defer freeOutcome(legacy);
    try std.testing.expectEqual(@as(usize, 2), fake.planner_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.polished_calls);
    try std.testing.expectEqual(@as(usize, 1), fake.legacy_calls);

    fake.cleanup_error = error.RequestFailed;
    const clean_fallback = try process(std.testing.allocator, try owned("raw"), .clean, worker_policy, fake.seam());
    defer freeOutcome(clean_fallback);
    try std.testing.expectEqualStrings("raw", clean_fallback.success.text);
    try std.testing.expectEqual(Warning.transformation_failed, clean_fallback.success.warning.?);
    try std.testing.expectEqual(processing.TransformationOutcome.failed, clean_fallback.success.transformation_outcome);
    try std.testing.expectEqual(@as(usize, 2), fake.planner_calls);

    const fallback = try process(std.testing.allocator, try owned("raw"), .polished, worker_policy, fake.seam());
    defer freeOutcome(fallback);
    try std.testing.expectEqualStrings("raw", fallback.success.text);
    try std.testing.expectEqual(Warning.transformation_failed, fallback.success.warning.?);
    try std.testing.expectEqual(processing.TransformationOutcome.failed, fallback.success.transformation_outcome);

    fake.cleanup_error = null;
    fake.clean_text = "too long";
    const invalid_output = try process(
        std.testing.allocator,
        try owned("raw"),
        .clean,
        .{ .max_bytes = 3, .require_utf8 = true },
        fake.seam(),
    );
    defer freeOutcome(invalid_output);
    try std.testing.expectEqualStrings("raw", invalid_output.success.text);
    try std.testing.expectEqual(Warning.transformation_failed, invalid_output.success.warning.?);
    try std.testing.expectEqual(processing.TransformationOutcome.failed, invalid_output.success.transformation_outcome);

    fake.clean_text = "raw";
    const no_change = try process(std.testing.allocator, try owned("raw"), .polished, worker_policy, fake.seam());
    defer freeOutcome(no_change);
    try std.testing.expectEqualStrings("raw", no_change.success.text);
    try std.testing.expectEqual(@as(?Warning, null), no_change.success.warning);
    try std.testing.expectEqual(processing.TransformationOutcome.no_change, no_change.success.transformation_outcome);
}

test "no speech and output bounds and UTF-8 are canonical" {
    var fake: Fake = .{ .rest_text = "" };
    const small_policy: OutputPolicy = .{ .max_bytes = 3, .require_utf8 = true };
    const empty = try process(std.testing.allocator, null, .verbatim, small_policy, fake.seam());
    try std.testing.expect(empty == .no_speech);
    fake.rest_text = "four";
    try std.testing.expectError(error.ResponseTooLarge, process(std.testing.allocator, null, .verbatim, small_policy, fake.seam()));
    fake.rest_text = "\xff";
    try std.testing.expectError(error.ResponseTooLarge, process(std.testing.allocator, null, .verbatim, small_policy, fake.seam()));
}

test "worker rejects invalid bytes while daemon accepts them" {
    var fake: Fake = .{ .rest_text = "\xff" };
    try std.testing.expectError(error.ResponseTooLarge, process(std.testing.allocator, null, .verbatim, worker_policy, fake.seam()));

    const daemon = try process(std.testing.allocator, null, .verbatim, .{ .max_bytes = null, .require_utf8 = false }, fake.seam());
    defer freeOutcome(daemon);
    try std.testing.expectEqualSlices(u8, "\xff", daemon.success.text);
}

test "polished baseline bypass degradation and planner ownership" {
    var sufficient: Fake = .{ .baseline_text = "Can we ship?", .baseline_sufficient = true };
    const bypass = try process(std.testing.allocator, try owned("can we ship"), .polished, worker_policy, sufficient.seam());
    defer freeOutcome(bypass);
    try std.testing.expectEqualStrings("Can we ship?", bypass.success.text);
    try std.testing.expectEqual(@as(usize, 0), sufficient.planner_calls);
    try std.testing.expectEqual(processing.TransformationOutcome.changed, bypass.success.transformation_outcome);

    var failed: Fake = .{ .baseline_text = "Ordinary sentence.", .planner_error = error.RateLimited };
    const degraded = try process(std.testing.allocator, try owned("ordinary sentence"), .polished, worker_policy, failed.seam());
    defer freeOutcome(degraded);
    try std.testing.expectEqualStrings("Ordinary sentence.", degraded.success.text);
    try std.testing.expectEqual(@as(?Warning, null), degraded.success.warning);
    try std.testing.expectEqual(processing.TransformationOutcome.degraded, degraded.success.transformation_outcome);

    var valid: Fake = .{ .baseline_text = "Baseline.", .clean_text = "Planner wins." };
    const planned = try process(std.testing.allocator, try owned("baseline"), .polished, worker_policy, valid.seam());
    defer freeOutcome(planned);
    try std.testing.expectEqualStrings("Planner wins.", planned.success.text);

    var legacy: Fake = .{ .baseline_text = "must not appear", .clean_text = "legacy" };
    const old = try process(std.testing.allocator, try owned("raw"), .legacy_v1, worker_policy, legacy.seam());
    defer freeOutcome(old);
    try std.testing.expectEqualStrings("legacy", old.success.text);
}

test "AI only plans raw input without deterministic processing and falls back to raw" {
    var valid: Fake = .{
        .clean_text = "Planner output.",
        .expected_planner_input = "if. raw input",
    };
    const planned = try process(std.testing.allocator, try owned("if. raw input"), .ai_only, worker_policy, valid.seam());
    defer freeOutcome(planned);
    try std.testing.expectEqualStrings("Planner output.", planned.success.text);
    try std.testing.expectEqual(@as(usize, 1), valid.planner_calls);
    try std.testing.expectEqual(@as(usize, 1), valid.ai_only_calls);
    try std.testing.expectEqual(@as(usize, 0), valid.clean_calls);
    try std.testing.expectEqual(@as(usize, 0), valid.baseline_calls);

    var failed: Fake = .{
        .planner_error = error.RateLimited,
        .expected_planner_input = "if. raw stays raw",
    };
    const fallback = try process(std.testing.allocator, try owned("if. raw stays raw"), .ai_only, worker_policy, failed.seam());
    defer freeOutcome(fallback);
    try std.testing.expectEqualStrings("if. raw stays raw", fallback.success.text);
    try std.testing.expectEqual(Warning.transformation_failed, fallback.success.warning.?);
    try std.testing.expectEqual(processing.TransformationOutcome.failed, fallback.success.transformation_outcome);
    try std.testing.expectEqual(@as(usize, 1), failed.planner_calls);
    try std.testing.expectEqual(@as(usize, 0), failed.clean_calls);
    try std.testing.expectEqual(@as(usize, 0), failed.baseline_calls);
}
