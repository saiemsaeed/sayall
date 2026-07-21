const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version_contents = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(64),
    ) catch @panic("could not read VERSION");
    const release_version = std.mem.trim(u8, version_contents, " \t\r\n");
    if (release_version.len == 0) @panic("VERSION must not be empty");
    const version = b.option(
        []const u8,
        "version",
        "Override the embedded version (for development packages)",
    ) orelse release_version;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);
    const websocket_dep = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("websocket", websocket_dep.module("websocket"));

    const exe = b.addExecutable(.{
        .name = "sayall",
        .root_module = mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
