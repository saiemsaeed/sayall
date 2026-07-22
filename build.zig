const std = @import("std");
const builtin = @import("builtin");

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
        .root_source_file = b.path("daemon/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const protocol_fixtures = b.createModule(.{
        .root_source_file = b.path("tests/protocol_v1_fixtures.zig"),
    });
    mod.addOptions("build_options", build_options);
    mod.addImport("protocol_fixtures", protocol_fixtures);
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
    const portable_audio_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("daemon/recorder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_portable_audio_tests = b.addRunArtifact(portable_audio_tests);
    const runtime_platform_test_module = b.createModule(.{
        .root_source_file = b.path("daemon/platform/runtime_platforms_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_platform_tests = b.addTest(.{
        .root_module = runtime_platform_test_module,
    });
    const run_runtime_platform_tests = b.addRunArtifact(runtime_platform_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_portable_audio_tests.step);
    test_step.dependOn(&run_runtime_platform_tests.step);
    if (builtin.os.tag == .linux and target.result.os.tag == .linux) {
        const shortcut_cli_tests = b.addSystemCommand(&.{ "sh", b.pathFromRoot("tests/shortcut-cli.sh") });
        shortcut_cli_tests.addArtifactArg(exe);
        test_step.dependOn(&shortcut_cli_tests.step);
    }
}
