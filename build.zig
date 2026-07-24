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
    build_options.addOption(bool, "e2e_scripted_stt", false);

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

    const process_module = b.createModule(.{
        .root_source_file = b.path("daemon/process_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    process_module.addOptions("build_options", build_options);
    process_module.addImport("websocket", websocket_dep.module("websocket"));
    const process_exe = b.addExecutable(.{ .name = "sayall-process", .root_module = process_module });
    const install_process = b.addInstallArtifact(process_exe, .{});
    const process_step = b.step("process", "Build the per-recording streaming and batch helper");
    process_step.dependOn(&install_process.step);
    const batch_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("daemon/batch.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const batch_step = b.step("test-batch", "Compile and test the platform-free batch operation");
    if (target.query.isNative()) batch_step.dependOn(&b.addRunArtifact(batch_tests).step) else batch_step.dependOn(&batch_tests.step);
    const stream_tests_module = b.createModule(.{
        .root_source_file = b.path("daemon/stream_batch.zig"),
        .target = target,
        .optimize = optimize,
    });
    stream_tests_module.addImport("websocket", websocket_dep.module("websocket"));
    const stream_tests = b.addTest(.{ .root_module = stream_tests_module });
    if (target.query.isNative()) batch_step.dependOn(&b.addRunArtifact(stream_tests).step) else batch_step.dependOn(&stream_tests.step);

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

        const e2e_build_options = b.addOptions();
        e2e_build_options.addOption([]const u8, "version", version);
        e2e_build_options.addOption(bool, "e2e_scripted_stt", true);
        const e2e_mod = b.createModule(.{
            .root_source_file = b.path("daemon/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        e2e_mod.addOptions("build_options", e2e_build_options);
        e2e_mod.addImport("protocol_fixtures", protocol_fixtures);
        e2e_mod.addImport("websocket", websocket_dep.module("websocket"));
        const e2e_exe = b.addExecutable(.{
            .name = "sayall-e2e",
            .root_module = e2e_mod,
        });
        const daemon_e2e_tests = b.addSystemCommand(&.{ "sh", b.pathFromRoot("tests/daemon-e2e.sh") });
        daemon_e2e_tests.addArtifactArg(e2e_exe);
        const e2e_step = b.step("test-e2e", "Run hermetic Linux daemon end-to-end tests");
        e2e_step.dependOn(&daemon_e2e_tests.step);
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
    const readiness_options = b.addOptions();
    readiness_options.addOption(bool, "e2e_scripted_stt", false);
    readiness_module.addOptions("build_options", readiness_options);
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
