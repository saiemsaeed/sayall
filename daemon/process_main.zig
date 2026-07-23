const std = @import("std");
const batch = @import("batch.zig");
const stream_batch = @import("stream_batch.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) u8 {
    run(init) catch return 1;
    return 0;
}

fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = init.minimal.args.vector;
    if (argv.len == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--version")) {
        return writeBytes(io, "sayall-process " ++ build_options.version ++ "\n");
    }
    if (argv.len == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--stream")) {
        return stream_batch.run(gpa, io);
    }
    if (argv.len != 1) return error.InvalidArguments;
    var storage: [batch.max_request_bytes + 1]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &storage);
    const input = reader.interface.allocRemaining(gpa, .limited(batch.max_request_bytes + 1)) catch {
        return write(io, gpa, .{ .status = .@"error", .@"error" = .invalid_request });
    };
    defer gpa.free(input);
    const parsed = batch.parseRequest(gpa, input) catch {
        return write(io, gpa, .{ .status = .@"error", .@"error" = .invalid_request });
    };
    defer parsed.deinit();
    const result = batch.process(gpa, io, parsed.value, .{});
    defer if (result.text) |text| gpa.free(text);
    try write(io, gpa, result);
}

fn write(io: std.Io, gpa: std.mem.Allocator, result: batch.Result) !void {
    const json = batch.stringifyResult(gpa, result) catch return;
    defer gpa.free(json);
    try writeBytes(io, json);
}

fn writeBytes(io: std.Io, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
