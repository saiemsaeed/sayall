//! Platform-neutral compile coverage for the public Darwin CLI grammar/config frontend.
const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");

test "Darwin public frontend and config initializer remain portable" {
    try std.testing.expectEqual(cli.Command.toggle, try cli.parse(&.{"toggle"}));
    const template = try config.defaultTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    try std.testing.expect(std.mem.indexOf(u8, template, "nova-3") != null);
}
