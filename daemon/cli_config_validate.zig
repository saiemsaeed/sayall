const std = @import("std");
const config = @import("config.zig");

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    json: bool,
) !u8 {
    _ = config.loadReadOnly(arena, io, env) catch |err| {
        if (json) {
            const response = try std.json.Stringify.valueAlloc(arena, .{
                .valid = false,
                .@"error" = @errorName(err),
            }, .{});
            try write(io, .stdout(), response);
            try write(io, .stdout(), "\n");
        } else {
            const response = try std.fmt.allocPrint(arena, "sayall: configuration is invalid ({s})\n", .{@errorName(err)});
            try write(io, .stderr(), response);
        }
        return 78;
    };
    if (json) {
        try write(io, .stdout(), "{\"valid\":true}\n");
    } else {
        try write(io, .stdout(), "Configuration is valid.\n");
    }
    return 0;
}

fn write(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    try file.writeStreamingAll(io, bytes);
}
