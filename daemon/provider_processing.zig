const std = @import("std");

pub const Warning = enum { cleanup_failed };

pub const Success = struct {
    text: []u8,
    warning: ?Warning = null,
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
    cleanup: *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,
};

/// Selects a completed stream (including an empty transcript) or performs one
/// REST attempt, then validates and optionally cleans the selected transcript.
/// `streamed_owned`, provider callback results, and successful outcome text are
/// allocator-owned. This function takes ownership of `streamed_owned`.
pub fn process(
    allocator: std.mem.Allocator,
    streamed_owned: ?[]u8,
    cleanup_enabled: bool,
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

    if (cleanup_enabled) {
        if (seam.cleanup(seam.context, allocator, raw)) |cleaned| {
            validate(cleaned, output_policy) catch {
                allocator.free(cleaned);
                return .{ .success = .{ .text = raw, .warning = .cleanup_failed } };
            };
            allocator.free(raw);
            return .{ .success = .{ .text = cleaned } };
        } else |_| {
            return .{ .success = .{ .text = raw, .warning = .cleanup_failed } };
        }
    }
    return .{ .success = .{ .text = raw } };
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
    rest_error: ?anyerror = null,
    cleanup_error: ?anyerror = null,
    rest_calls: usize = 0,
    cleanup_calls: usize = 0,

    fn rest(context: ?*anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.rest_calls += 1;
        if (self.rest_error) |err| return err;
        return allocator.dupe(u8, self.rest_text);
    }

    fn cleanup(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8) ![]u8 {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.cleanup_calls += 1;
        if (self.cleanup_error) |err| return err;
        return allocator.dupe(u8, self.clean_text);
    }

    fn seam(self: *Fake) Seam {
        return .{ .context = self, .rest = rest, .cleanup = cleanup };
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
    const outcome = try process(std.testing.allocator, null, false, worker_policy, fake.seam());
    defer freeOutcome(outcome);
    try std.testing.expectEqual(@as(usize, 1), fake.rest_calls);
    try std.testing.expectEqualStrings("raw", outcome.success.text);
}

test "stream success including empty never falls back to REST" {
    var fake: Fake = .{};
    const streamed = try process(std.testing.allocator, try owned("stream"), false, worker_policy, fake.seam());
    defer freeOutcome(streamed);
    try std.testing.expectEqual(@as(usize, 0), fake.rest_calls);
    try std.testing.expectEqualStrings("stream", streamed.success.text);
    const empty = try process(std.testing.allocator, try owned(""), false, worker_policy, fake.seam());
    try std.testing.expect(empty == .no_speech);
    try std.testing.expectEqual(@as(usize, 0), fake.rest_calls);
}

test "absent or failed stream is represented by one REST attempt" {
    var fake: Fake = .{ .rest_error = error.RequestFailed };
    try std.testing.expectError(error.RequestFailed, process(std.testing.allocator, null, false, worker_policy, fake.seam()));
    try std.testing.expectEqual(@as(usize, 1), fake.rest_calls);
}

test "cleanup succeeds or falls back to raw with warning" {
    var fake: Fake = .{};
    const cleaned = try process(std.testing.allocator, null, true, worker_policy, fake.seam());
    defer freeOutcome(cleaned);
    try std.testing.expectEqualStrings("clean", cleaned.success.text);
    try std.testing.expectEqual(@as(?Warning, null), cleaned.success.warning);

    fake.cleanup_error = error.RequestFailed;
    const fallback = try process(std.testing.allocator, try owned("raw"), true, worker_policy, fake.seam());
    defer freeOutcome(fallback);
    try std.testing.expectEqualStrings("raw", fallback.success.text);
    try std.testing.expectEqual(Warning.cleanup_failed, fallback.success.warning.?);
}

test "no speech and output bounds and UTF-8 are canonical" {
    var fake: Fake = .{ .rest_text = "" };
    const small_policy: OutputPolicy = .{ .max_bytes = 3, .require_utf8 = true };
    const empty = try process(std.testing.allocator, null, false, small_policy, fake.seam());
    try std.testing.expect(empty == .no_speech);
    fake.rest_text = "four";
    try std.testing.expectError(error.ResponseTooLarge, process(std.testing.allocator, null, false, small_policy, fake.seam()));
    fake.rest_text = "\xff";
    try std.testing.expectError(error.ResponseTooLarge, process(std.testing.allocator, null, false, small_policy, fake.seam()));
}

test "worker rejects invalid bytes while daemon accepts them" {
    var fake: Fake = .{ .rest_text = "\xff" };
    try std.testing.expectError(error.ResponseTooLarge, process(std.testing.allocator, null, false, worker_policy, fake.seam()));

    const daemon = try process(std.testing.allocator, null, false, .{ .max_bytes = null, .require_utf8 = false }, fake.seam());
    defer freeOutcome(daemon);
    try std.testing.expectEqualSlices(u8, "\xff", daemon.success.text);
}
