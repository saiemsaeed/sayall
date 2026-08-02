const std = @import("std");

pub const version: u32 = 1;
pub const max_control_bytes: usize = 64 * 1024;
pub const max_result_bytes: usize = 1024 * 1024;
pub const max_info_bytes: usize = 4096;
pub const max_ready_bytes: usize = 4096;

pub const Info = struct {
    protocol_version: u32 = version,
    build_version: []const u8,
};

pub const Ready = struct {
    version: u32 = version,
    event: []const u8 = "ready",
    streaming: bool,
};

pub fn stringifyInfo(gpa: std.mem.Allocator, build_version: []const u8) ![]u8 {
    const result = try std.json.Stringify.valueAlloc(gpa, Info{ .build_version = build_version }, .{});
    if (result.len + 1 > max_info_bytes) {
        gpa.free(result);
        return error.ResponseTooLarge;
    }
    return result;
}

test "worker info is bounded and fixture-compatible" {
    const bytes = try stringifyInfo(std.testing.allocator, "0.1.8");
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(bytes.len < max_info_bytes);
    const parsed = try std.json.parseFromSlice(Info, std.testing.allocator, "{\"protocol_version\":1,\"build_version\":\"0.1.8\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(version, parsed.value.protocol_version);
}
