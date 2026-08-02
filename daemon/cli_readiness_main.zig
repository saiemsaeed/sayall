const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const host = @import("host_control.zig");

pub fn main(init: std.process.Init) u8 {
    return run(init) catch |err| {
        std.debug.print("sayall: frontend failure ({s})\n", .{@errorName(err)});
        return 1;
    };
}

fn run(init: std.process.Init) !u8 {
    const argv = init.minimal.args.vector;
    var args: [2][]const u8 = undefined;
    if (argv.len < 2) return writePresentation(init.io, cli.usage_presentation);
    if (argv.len > 3) return writePresentation(init.io, cli.invalid_presentation);
    for (argv[1..], 0..) |arg, i| args[i] = std.mem.span(arg);
    const command = cli.parse(args[0 .. argv.len - 1]) catch return writePresentation(init.io, cli.invalid_presentation);
    if (command == .config_init) {
        const path = config.initDefault(init.arena.allocator(), init.io, init.environ_map) catch |err| {
            const message = try std.fmt.allocPrint(init.arena.allocator(), "sayall: cannot initialize configuration ({s})\n", .{@errorName(err)});
            try write(init.io, .stderr(), message);
            return 1;
        };
        const message = try std.fmt.allocPrint(init.arena.allocator(), "Created {s}\n", .{path});
        try write(init.io, .stdout(), message);
        return 0;
    }
    var unavailable: host.Unavailable = .{};
    const result = cli.execute(command, "sayall readiness\n", unavailable.adapter());
    try write(init.io, .stdout(), result.stdout);
    try write(init.io, .stderr(), result.stderr);
    return result.exit_code;
}

fn write(io: std.Io, file: std.Io.File, bytes: []const u8) !void {
    if (bytes.len != 0) try file.writeStreamingAll(io, bytes);
}

fn writePresentation(io: std.Io, presentation: cli.Presentation) !u8 {
    try write(io, .stdout(), presentation.stdout);
    try write(io, .stderr(), presentation.stderr);
    return presentation.exit_code;
}
