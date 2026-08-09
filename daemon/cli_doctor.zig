const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const config = @import("config.zig");
const paths = @import("paths.zig");
const product_contract = @import("product/contracts.zig");
const worker_protocol = @import("worker_protocol.zig");

const report_schema_version: u32 = 1;
const max_report_bytes: usize = 64 * 1024;

const Report = struct {
    schema_version: u32 = report_schema_version,
    version: []const u8,
    executable: []const u8,
    configuration: []const u8,
    configuration_permissions: []const u8,
    worker: []const u8,
    host: []const u8,
    platform: []const product_contract.Diagnostic,
    failures: u8,
    warnings: u8,
};

pub const ConfigAudit = struct { safe: bool, detail: []const u8 };

pub fn configPathSafe(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) bool {
    const audit = auditConfig(arena, io, env) catch return false;
    return audit.safe;
}

pub fn run(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, host: cli.HostControl, version: []const u8, json: bool, platform: []const product_contract.Diagnostic) !u8 {
    const executable = std.process.executablePathAlloc(io, arena) catch "unavailable";
    var config_detail: []const u8 = "valid and credentials configured";
    var config_ok = true;
    var warnings: u8 = 0;
    const audit = auditConfig(arena, io, env) catch |err| ConfigAudit{ .safe = false, .detail = @errorName(err) };
    if (audit.safe) {
        if (config.loadReadOnly(arena, io, env)) |cfg| {
            if (cfg.stt.api_key.len == 0) {
                config_ok = false;
                config_detail = "Deepgram credentials are missing";
            } else if (config.effectiveProcessingProfile(&cfg).usesPlanner() and cfg.llm.api_key.len == 0) {
                warnings += 1;
                config_detail = "valid; polished processing credentials are missing";
            }
        } else |err| {
            config_ok = false;
            config_detail = @errorName(err);
        }
    } else {
        config_ok = false;
        config_detail = "configuration was not loaded because its path is unsafe";
    }
    const permissions_ok = audit.safe;
    const permissions_detail = audit.detail;
    const worker = findWorker(arena, io, executable);
    const worker_ok = if (worker) |path| protocolCompatible(arena, io, path, version) else false;
    const host_result = host.status(); // Status is deliberately nonmutating and never launches the host.
    const host_ok = switch (host_result) {
        .idle, .starting, .recording, .stopping, .processing, .delivering, .success, .host_error, .cancelled => true,
        else => false,
    };
    var failures: u8 = @intFromBool(!config_ok) + @intFromBool(!permissions_ok) + @intFromBool(!worker_ok) + @intFromBool(!host_ok);
    for (platform) |item| switch (item.status) {
        .fail => failures += 1,
        .warn => warnings += 1,
        .ok => {},
    };

    if (json) {
        var sanitized_platform: [8]product_contract.Diagnostic = undefined;
        for (platform, 0..) |item, index| sanitized_platform[index] = .{
            .status = item.status,
            .label = cap(item.label, 128),
            .detail = cap(item.detail, 768),
        };
        const output = try std.json.Stringify.valueAlloc(arena, Report{
            .version = cap(version, 64),
            .executable = cap(executable, 2048),
            .configuration = cap(config_detail, 1024),
            .configuration_permissions = cap(permissions_detail, 1024),
            .worker = if (worker_ok) "compatible" else if (worker != null) "incompatible" else "missing",
            .host = hostStatus(host_result),
            .platform = sanitized_platform[0..platform.len],
            .failures = failures,
            .warnings = warnings,
        }, .{});
        std.debug.assert(output.len <= max_report_bytes);
        try write(io, output);
        try write(io, "\n");
    } else {
        try line(arena, io, "[ok] Version: {s}", .{version});
        try line(arena, io, "[ok] Executable: {s}", .{executable});
        try line(arena, io, "[{s}] Configuration: {s}", .{ if (config_ok) "ok" else "fail", config_detail });
        try line(arena, io, "[{s}] Config permissions: {s}", .{ if (permissions_ok) "ok" else "fail", permissions_detail });
        try line(arena, io, "[{s}] Packaged worker: {s}", .{ if (worker_ok) "ok" else "fail", if (worker) |path| path else "missing" });
        try line(arena, io, "[{s}] Native host: {s}", .{ if (host_ok) "ok" else "fail", if (host_ok) "available (permission state is not exposed by the host protocol)" else "unavailable" });
        for (platform) |item| try line(arena, io, "[{s}] {s}: {s}", .{ @tagName(item.status), item.label, item.detail });
        try line(arena, io, "Result: {d} failure(s), {d} warning(s)", .{ failures, warnings });
    }
    return if (failures == 0) 0 else 1;
}

fn auditConfig(arena: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !ConfigAudit {
    const path = try paths.Config.file(arena, env) orelse
        return .{ .safe = false, .detail = "configuration home is unavailable" };
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;
    var parent = std.Io.Dir.openDirAbsolute(io, parent_path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .safe = true, .detail = "configuration file is absent" },
        else => return err,
    };
    defer parent.close(io);
    const parent_stat = try parent.stat(io);
    if (parent_stat.kind != .directory or parent_stat.permissions.toMode() & 0o077 != 0 or try owner(parent.handle) != effectiveUserId())
        return .{ .safe = false, .detail = "configuration directory must be owned by the current user and mode 0700" };
    var file = parent.openFile(io, std.fs.path.basename(path), .{ .allow_directory = false, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .safe = true, .detail = "configuration file is absent" },
        else => return err,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0 or try owner(file.handle) != effectiveUserId())
        return .{ .safe = false, .detail = "configuration must be owned by the current user and mode 0600" };
    return .{ .safe = true, .detail = "private" };
}

fn owner(handle: std.Io.File.Handle) !u32 {
    if (builtin.os.tag == .linux) {
        var raw: std.os.linux.Statx = undefined;
        if (std.os.linux.errno(std.os.linux.statx(handle, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true }, &raw)) != .SUCCESS)
            return error.StatFailed;
        return raw.uid;
    }
    if (builtin.os.tag == .macos) {
        var raw: std.c.Stat = undefined;
        if (std.c.fstat(handle, &raw) != 0) return error.StatFailed;
        return raw.uid;
    }
    return error.UnsupportedPlatform;
}

fn effectiveUserId() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.geteuid(),
        .macos => @intCast(std.c.geteuid()),
        else => 0,
    };
}

fn hostStatus(outcome: cli.HostOutcome) []const u8 {
    return switch (outcome) {
        .idle => "idle",
        .starting => "starting",
        .recording => "recording",
        .stopping => "stopping",
        .processing => "processing",
        .delivering => "delivering",
        .success => "success",
        .host_error => "host_error",
        .operation_error => "operation_error",
        .busy => "busy",
        .cancelled => "cancelled",
        .incompatible => "incompatible",
        .transport_error => "transport_error",
        .unavailable => "unavailable",
    };
}

fn cap(value: []const u8, maximum: usize) []const u8 {
    return value[0..@min(value.len, maximum)];
}

fn findWorker(arena: std.mem.Allocator, io: std.Io, executable: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(executable) orelse return null;
    const candidates = [_][]const u8{
        std.fs.path.join(arena, &.{ dir, "sayall-process" }) catch return null,
        std.fs.path.join(arena, &.{ dir, "..", "lib", "sayall", "sayall-process" }) catch return null,
    };
    for (candidates) |path| if (std.Io.Dir.cwd().statFile(io, path, .{})) |stat| {
        if (stat.kind == .file) return path;
    } else |_| {};
    return null;
}

fn protocolCompatible(arena: std.mem.Allocator, io: std.Io, path: []const u8, build_version: []const u8) bool {
    const ProbeInfo = struct { protocol_version: u32, build_version: []const u8 };
    const result = std.process.run(arena, io, .{
        .argv = &.{ path, "--worker-info" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(2) } },
    }) catch return false;
    switch (result.term) {
        .exited => |code| if (code != 0) return false,
        else => return false,
    }
    const parsed = std.json.parseFromSlice(ProbeInfo, arena, std.mem.trim(u8, result.stdout, " \r\n\t"), .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    return parsed.value.protocol_version == worker_protocol.version and std.mem.eql(u8, parsed.value.build_version, build_version);
}

fn line(arena: std.mem.Allocator, io: std.Io, comptime format: []const u8, args: anytype) !void {
    try write(io, try std.fmt.allocPrint(arena, format ++ "\n", args));
}
fn write(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, bytes);
}

test "machine host status preserves state without messages" {
    try std.testing.expectEqualStrings("idle", hostStatus(.idle));
    try std.testing.expectEqualStrings("recording", hostStatus(.recording));
    try std.testing.expectEqualStrings("busy", hostStatus(.{ .busy = "secret message" }));
    try std.testing.expectEqualStrings("transport_error", hostStatus(.{ .transport_error = "private path" }));
}

test "doctor JSON schema is frozen and bounded" {
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, Report{
        .version = "0.2.0",
        .executable = "/usr/bin/sayall",
        .configuration = "ok",
        .configuration_permissions = "private",
        .worker = "compatible",
        .host = "idle",
        .platform = &.{},
        .failures = 0,
        .warnings = 0,
    }, .{});
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"version\":\"0.2.0\",\"executable\":\"/usr/bin/sayall\",\"configuration\":\"ok\",\"configuration_permissions\":\"private\",\"worker\":\"compatible\",\"host\":\"idle\",\"platform\":[],\"failures\":0,\"warnings\":0}", bytes);
    try std.testing.expect(bytes.len < max_report_bytes);
    try std.testing.expectEqual(@as(usize, 4), cap("oversize", 4).len);
}
