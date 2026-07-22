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
    const portable_audio_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("daemon/recorder.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const runtime_platform_test_module = b.createModule(.{
        .root_source_file = b.path("daemon/platform/runtime_platforms_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime_platform_tests = b.addTest(.{
        .root_module = runtime_platform_test_module,
    });
    const test_step = b.step("test", "Run unit tests");

    // A test artifact can always be cross-compiled, but it must only be run
    // when the caller selected the native target. This deliberately does not
    // opt into QEMU, Wine, Darling, or another foreign executor.
    if (target.query.isNative()) {
        const run_unit_tests = b.addRunArtifact(unit_tests);
        const run_portable_audio_tests = b.addRunArtifact(portable_audio_tests);
        const run_runtime_platform_tests = b.addRunArtifact(runtime_platform_tests);
        test_step.dependOn(&run_unit_tests.step);
        test_step.dependOn(&run_portable_audio_tests.step);
        test_step.dependOn(&run_runtime_platform_tests.step);
    } else {
        test_step.dependOn(&unit_tests.step);
        test_step.dependOn(&portable_audio_tests.step);
        test_step.dependOn(&runtime_platform_tests.step);
    }
    if (target.query.isNative() and target.result.os.tag == .linux) {
        const shortcut_cli_tests = b.addSystemCommand(&.{ "sh", b.pathFromRoot("tests/shortcut-cli.sh") });
        shortcut_cli_tests.addArtifactArg(exe);
        test_step.dependOn(&shortcut_cli_tests.step);
    }

    addCoreReadinessCheck(b, optimize, .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    }, "check-darwin-core", "Compile aarch64-macos core readiness / unsupported runtime checks");
    addCoreReadinessCheck(b, optimize, .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    }, "check-windows-core", "Compile x86_64-windows core readiness / unsupported runtime checks");
}

fn addCoreReadinessCheck(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target_query: std.Target.Query,
    step_name: []const u8,
    description: []const u8,
) void {
    const target = b.resolveTargetQuery(target_query);
    const readiness_module = b.createModule(.{
        .root_source_file = b.path("daemon/core_readiness_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    readiness_module.addImport("protocol_fixtures", b.createModule(.{
        .root_source_file = b.path("tests/protocol_v1_fixtures.zig"),
    }));
    readiness_module.addImport("websocket", b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    }).module("websocket"));

    const readiness_tests = b.addTest(.{
        .root_module = readiness_module,
    });
    const readiness_step = b.step(step_name, description);
    // Depend on compilation only. These foreign test binaries are never run,
    // installed, or promoted to release artifacts.
    readiness_step.dependOn(&readiness_tests.step);
}
