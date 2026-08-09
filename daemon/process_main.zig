const std = @import("std");
const batch = @import("batch.zig");
const stream_batch = @import("stream_batch.zig");
const worker_protocol = @import("worker_protocol.zig");
const config = @import("config.zig");
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
    if ((argv.len == 2 or (argv.len == 3 and std.mem.eql(u8, std.mem.span(argv[2]), "--wait"))) and
        std.mem.eql(u8, std.mem.span(argv[1]), "--worker-info"))
    {
        const info = try worker_protocol.stringifyInfo(gpa, build_options.version);
        defer gpa.free(info);
        try writeBytes(io, info);
        try writeBytes(io, "\n");
        if (argv.len == 3) {
            var storage: [1]u8 = undefined;
            var reader = std.Io.File.stdin().reader(io, &storage);
            _ = reader.interface.allocRemaining(gpa, .limited(1)) catch return;
        }
        return;
    }
    if (argv.len == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--stream")) {
        return stream_batch.run(gpa, io);
    }
    if (argv.len == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--config-init")) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const path = config.initDefault(arena_state.allocator(), io, init.environ_map) catch |err| {
            if (err == error.PathAlreadyExists)
                try writeBytes(io, "{\"version\":1,\"status\":\"exists\"}\n")
            else
                try writeBytes(io, "{\"version\":1,\"status\":\"error\"}\n");
            return;
        };
        _ = path;
        try writeBytes(io, "{\"version\":1,\"status\":\"created\"}\n");
        return;
    }
    if (argv.len == 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--config-validate")) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const result = config.loadReadOnlyWithPresence(arena_state.allocator(), io, init.environ_map) catch {
            try writeBytes(io, "{\"version\":1,\"status\":\"invalid\"}\n");
            return;
        };
        try writeBytes(io, if (result.present)
            "{\"version\":1,\"status\":\"valid\"}\n"
        else
            "{\"version\":1,\"status\":\"missing\"}\n");
        return;
    }
    if (argv.len != 1) return error.InvalidArguments;
    var storage: [batch.max_request_bytes + 1]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &storage);
    const input = reader.interface.allocRemaining(gpa, .limited(batch.max_request_bytes + 1)) catch {
        return writeInvalid(io, gpa);
    };
    defer gpa.free(input);
    const parsed = batch.parseRequest(gpa, input) catch {
        return writeInvalid(io, gpa);
    };
    defer parsed.deinit();
    const result = batch.process(gpa, io, parsed.value, .{});
    defer if (result.text) |text| gpa.free(text);
    try write(io, gpa, result);
}

fn writeInvalid(io: std.Io, gpa: std.mem.Allocator) !void {
    return write(io, gpa, .{
        .status = .@"error",
        .@"error" = .invalid_request,
        .processing_profile = .verbatim,
        .transport = .rest,
    });
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
