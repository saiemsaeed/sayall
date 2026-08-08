const std = @import("std");
const cli = @import("cli.zig");
const protocol = @import("host_control.zig");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("darwin_host_control.h");
});

extern fn sayall_darwin_probe(deadline: u64) c_int;
extern fn sayall_darwin_exchange(method: [*:0]const u8, deadline: u64, reply: *?[*]u8, len: *usize) c_int;
extern fn sayall_darwin_launch_containing_app() c_int;
extern fn sayall_darwin_free(pointer: ?*anyopaque) void;
extern fn sayall_darwin_monotonic_now() u64;
extern fn sayall_darwin_sleep_ns(u64) void;

const Result = enum(c_int) { success, absent_launchable, unsafe, timeout, incompatible, transport };

pub const Darwin = struct {
    arena: std.mem.Allocator,
    ops: Ops = .{},
    pub const Ops = struct {
        probe: *const fn (u64) callconv(.c) c_int = sayall_darwin_probe,
        launch: *const fn () callconv(.c) c_int = sayall_darwin_launch_containing_app,
        exchange: *const fn ([*:0]const u8, u64, *?[*]u8, *usize) callconv(.c) c_int = sayall_darwin_exchange,
        free: *const fn (?*anyopaque) callconv(.c) void = sayall_darwin_free,
        now: *const fn () callconv(.c) u64 = sayall_darwin_monotonic_now,
        sleep: *const fn (u64) callconv(.c) void = sayall_darwin_sleep_ns,
    };
    pub fn adapter(self: *Darwin) cli.HostControl {
        return .{ .context = self, .statusFn = status, .toggleFn = toggle, .reloadFn = reload };
    }
    fn status(ctx: *anyopaque) cli.HostOutcome {
        return send(@ptrCast(@alignCast(ctx)), .status);
    }
    fn toggle(ctx: *anyopaque) cli.HostOutcome {
        const self: *Darwin = @ptrCast(@alignCast(ctx));
        const outer = self.ops.now() +| 5 * std.time.ns_per_s;
        const initial = result(self.ops.probe(cappedDeadline(self, outer)));
        if (initial == .absent_launchable) {
            if (result(self.ops.launch()) != .success) return .{ .transport_error = "sayall: cannot launch containing SayAll app\n" };
            var attempts: usize = 0;
            while (attempts < 50) : (attempts += 1) {
                if (self.ops.now() >= outer) return .{ .transport_error = "sayall: timed out waiting for SayAll app\n" };
                const readiness = result(self.ops.probe(cappedDeadline(self, outer)));
                if (readiness == .success) break;
                if (readiness != .absent_launchable) return classify(readiness, false);
                self.ops.sleep(100 * std.time.ns_per_ms);
            } else return .{ .transport_error = "sayall: timed out waiting for SayAll app\n" };
        } else if (initial != .success) return classify(initial, false);
        // From this point there is one mutating exchange and no retry path.
        return send(self, .toggle);
    }
    fn reload(ctx: *anyopaque) cli.HostOutcome {
        return send(@ptrCast(@alignCast(ctx)), .reload);
    }
    fn send(self: *Darwin, method: protocol.Method) cli.HostOutcome {
        var bytes: ?[*]u8 = null;
        var len: usize = 0;
        const name: [:0]const u8 = switch (method) {
            .status => "status",
            .toggle => "toggle",
            .reload => "reload",
        };
        const code = result(self.ops.exchange(name.ptr, self.ops.now() +| std.time.ns_per_s, &bytes, &len));
        if (code != .success) return classify(code, method == .status);
        defer self.ops.free(bytes);
        if (bytes == null) return .{ .incompatible = "sayall: malformed host response\n" };
        const parsed = protocol.parseResponse(self.arena, bytes.?[0..len]) catch return .{ .incompatible = "sayall: malformed host response\n" };
        defer parsed.deinit();
        return protocol.mapResponsePublic(self.arena, parsed.value);
    }
};

fn result(code: c_int) Result {
    return switch (code) {
        @intFromEnum(Result.success) => .success,
        @intFromEnum(Result.absent_launchable) => .absent_launchable,
        @intFromEnum(Result.unsafe) => .unsafe,
        @intFromEnum(Result.timeout) => .timeout,
        @intFromEnum(Result.incompatible) => .incompatible,
        else => .transport,
    };
}
fn cappedDeadline(self: *Darwin, outer: u64) u64 {
    return @min(outer, self.ops.now() +| 250 * std.time.ns_per_ms);
}
fn classify(code: Result, status: bool) cli.HostOutcome {
    if (status and code != .incompatible) return .{ .transport_error = "sayall: not running\n" };
    if (code == .incompatible) return .{ .incompatible = "sayall: unsupported or malformed host protocol\n" };
    return .{ .transport_error = "sayall: cannot reach macOS host\n" };
}

test "Darwin operation policy covers every launch and no-retry branch" {
    const Fake = struct {
        var probes: usize = 0;
        var launches: usize = 0;
        var exchanges: usize = 0;
        var probe_sequence: []const c_int = &.{};
        var exchange_result: c_int = 0;
        var exchange_text: []const u8 = "{\"version\":2,\"ok\":true,\"state\":\"idle\"}";
        var last_method: []const u8 = "";
        var time: u64 = 0;
        fn reset(sequence: []const c_int) void {
            probes = 0;
            launches = 0;
            exchanges = 0;
            probe_sequence = sequence;
            exchange_result = 0;
            exchange_text = "{\"version\":2,\"ok\":true,\"state\":\"idle\"}";
            last_method = "";
            time = 0;
        }
        fn probe(_: u64) callconv(.c) c_int {
            const index = probes;
            probes += 1;
            return if (index < probe_sequence.len) probe_sequence[index] else @intFromEnum(Result.absent_launchable);
        }
        fn launch() callconv(.c) c_int {
            launches += 1;
            return 0;
        }
        fn free(_: ?*anyopaque) callconv(.c) void {}
        fn exchange(method: [*:0]const u8, _: u64, out: *?[*]u8, len: *usize) callconv(.c) c_int {
            exchanges += 1;
            last_method = std.mem.span(method);
            out.* = @constCast(exchange_text.ptr);
            len.* = exchange_text.len;
            return exchange_result;
        }
        fn now() callconv(.c) u64 {
            return time;
        }
        fn sleep(duration: u64) callconv(.c) void {
            time +|= duration;
        }
    };
    var d = Darwin{ .arena = std.testing.allocator, .ops = .{ .probe = Fake.probe, .launch = Fake.launch, .exchange = Fake.exchange, .free = Fake.free, .now = Fake.now, .sleep = Fake.sleep } };

    Fake.reset(&.{});
    _ = d.adapter().status();
    try std.testing.expectEqualSlices(u8, "status", Fake.last_method);
    try std.testing.expectEqual(@as(usize, 0), Fake.probes);
    try std.testing.expectEqual(@as(usize, 0), Fake.launches);
    try std.testing.expectEqual(@as(usize, 1), Fake.exchanges);

    Fake.reset(&.{});
    Fake.exchange_result = @intFromEnum(Result.transport);
    const absent_status = d.adapter().status();
    try std.testing.expectEqualStrings("sayall: not running\n", absent_status.transport_error);
    try std.testing.expectEqual(@as(usize, 0), Fake.probes);
    try std.testing.expectEqual(@as(usize, 0), Fake.launches);
    try std.testing.expectEqual(@as(usize, 1), Fake.exchanges);

    Fake.reset(&.{@intFromEnum(Result.success)});
    _ = d.adapter().toggle();
    try std.testing.expectEqualSlices(u8, "toggle", Fake.last_method);
    try std.testing.expectEqual(@as(usize, 0), Fake.launches);
    try std.testing.expectEqual(@as(usize, 1), Fake.exchanges);

    Fake.reset(&.{ @intFromEnum(Result.absent_launchable), @intFromEnum(Result.absent_launchable), @intFromEnum(Result.success) });
    _ = d.adapter().toggle();
    try std.testing.expectEqual(@as(usize, 3), Fake.probes);
    try std.testing.expectEqual(@as(usize, 1), Fake.launches);
    try std.testing.expectEqual(@as(usize, 1), Fake.exchanges);

    for ([_]Result{ .unsafe, .timeout }) |failure| {
        Fake.reset(&.{@intFromEnum(failure)});
        _ = d.adapter().toggle();
        try std.testing.expectEqual(@as(usize, 0), Fake.launches);
        try std.testing.expectEqual(@as(usize, 0), Fake.exchanges);
    }

    Fake.reset(&.{@intFromEnum(Result.absent_launchable)});
    Fake.time = 5 * std.time.ns_per_s;
    _ = d.adapter().toggle();
    try std.testing.expectEqual(@as(usize, 1), Fake.launches);
    try std.testing.expectEqual(@as(usize, 0), Fake.exchanges);

    for ([_]struct { code: c_int, text: []const u8 }{
        .{ .code = @intFromEnum(Result.incompatible), .text = "" },
        .{ .code = 0, .text = "{" },
        .{ .code = 0, .text = "{\"version\":2,\"ok\":true,\"state\":\"idle\",\"error\":\"ambiguous\"}" },
    }) |failure| {
        Fake.reset(&.{@intFromEnum(Result.success)});
        Fake.exchange_result = failure.code;
        Fake.exchange_text = failure.text;
        _ = d.adapter().toggle();
        try std.testing.expectEqual(@as(usize, 1), Fake.exchanges);
    }
}

test "bridge normalizes errno and validates inclusive frames" {
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.absent_launchable)), c.sayall_darwin_classify_errno(c.ENOENT, 0, 1));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.transport)), c.sayall_darwin_classify_errno(c.ENOENT, 0, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.absent_launchable)), c.sayall_darwin_classify_errno(c.ECONNREFUSED, 1, 1));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.transport)), c.sayall_darwin_classify_errno(c.ECONNREFUSED, 0, 1));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.unsafe)), c.sayall_darwin_classify_errno(c.EACCES, 0, 1));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.timeout)), c.sayall_darwin_classify_errno(c.ETIMEDOUT, 1, 0));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.incompatible)), c.sayall_darwin_classify_errno(c.EPROTO, 1, 0));
    var payload: usize = 99;
    try std.testing.expectEqual(@as(c_int, 0), c.sayall_darwin_classify_frame("{}\n", 3, &payload));
    try std.testing.expectEqual(@as(usize, 2), payload);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.incompatible)), c.sayall_darwin_classify_frame("{}", 2, &payload));
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.incompatible)), c.sayall_darwin_classify_frame("{}\n{}", 5, &payload));
}

test "app validator accepts only canonical bundled helper and resolves symlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "Good.app/Contents/Helpers");
    try tmp.dir.createDirPath(std.testing.io, "Good.app/Contents/MacOS");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Good.app/Contents/Helpers/sayall", .data = "helper" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Good.app/Contents/MacOS/SayAll", .data = "app" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Good.app/Contents/Info.plist", .data = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>" ++
        "<key>CFBundleIdentifier</key><string>pro.leets.sayall</string>" ++
        "<key>CFBundleExecutable</key><string>SayAll</string>" ++
        "<key>CFBundlePackageType</key><string>APPL</string></dict></plist>" });

    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    const helper = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/Good.app/Contents/Helpers/sayall", .{root}, 0);
    defer std.testing.allocator.free(helper);
    var app: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.sayall_darwin_validate_app_path(helper, &app, app.len));
    try std.testing.expect(std.mem.endsWith(u8, std.mem.sliceTo(&app, 0), "/Good.app"));

    try tmp.dir.symLink(std.testing.io, "Good.app/Contents/Helpers/sayall", "helper-link", .{});
    const link = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/helper-link", .{root}, 0);
    defer std.testing.allocator.free(link);
    try std.testing.expectEqual(@as(c_int, 0), c.sayall_darwin_validate_app_path(link, &app, app.len));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "copied-sayall", .data = "helper" });
    const copied = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/copied-sayall", .{root}, 0);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.unsafe)), c.sayall_darwin_validate_app_path(copied, &app, app.len));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Good.app/Contents/Helpers/wrong", .data = "helper" });
    const wrong_suffix = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/Good.app/Contents/Helpers/wrong", .{root}, 0);
    defer std.testing.allocator.free(wrong_suffix);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.unsafe)), c.sayall_darwin_validate_app_path(wrong_suffix, &app, app.len));

    try tmp.dir.createDirPath(std.testing.io, "Wrong.app/Contents/Helpers");
    try tmp.dir.createDirPath(std.testing.io, "Wrong.app/Contents/MacOS");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Wrong.app/Contents/Helpers/sayall", .data = "helper" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Wrong.app/Contents/MacOS/SayAll", .data = "app" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "Wrong.app/Contents/Info.plist", .data = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" ++
        "<key>CFBundleIdentifier</key><string>invalid.bundle</string>" ++
        "<key>CFBundleExecutable</key><string>SayAll</string></dict></plist>" });
    const wrong_bundle = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/Wrong.app/Contents/Helpers/sayall", .{root}, 0);
    defer std.testing.allocator.free(wrong_bundle);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(Result.unsafe)), c.sayall_darwin_validate_app_path(wrong_bundle, &app, app.len));
}
