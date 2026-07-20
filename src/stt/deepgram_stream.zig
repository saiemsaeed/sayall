const std = @import("std");
const websocket = @import("websocket");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("../config.zig");
const deepgram = @import("deepgram.zig");

pub const Success = struct {
    transcript: []u8,
    latency_ms: u64,
    connect_ms: u64,
    stop_to_final_ms: u64,
};

pub const Failure = struct {
    reason: []const u8,
    latency_ms: u64,
};

pub const Result = union(enum) {
    success: Success,
    failed: Failure,
};

pub const Session = struct {
    gpa: Allocator,
    io: Io,
    cfg: *const config.SttConfig,
    path: []u8,
    started_ms: i64,
    finish_requested: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    finish_started_ms: std.atomic.Value(i64) = .init(0),
    mutex: Io.Mutex = .init,
    owner_released: bool = false,
    result: ?Result = null,

    pub fn start(gpa: Allocator, io: Io, cfg: *const config.SttConfig, path: []const u8) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = cfg,
            .path = try gpa.dupe(u8, path),
            .started_ms = std.Io.Clock.now(.awake, io).toMilliseconds(),
        };
        errdefer gpa.free(self.path);
        const thread = try std.Thread.spawn(.{}, workerMain, .{self});
        thread.detach();
        return self;
    }

    pub fn requestFinish(self: *Session) void {
        self.finish_started_ms.store(std.Io.Clock.now(.awake, self.io).toMilliseconds(), .release);
        self.finish_requested.store(true, .release);
    }

    pub fn finish(self: *Session) Result {
        if (!self.finish_requested.load(.acquire)) self.requestFinish();
        const wait_ms = self.cfg.stream_finalize_timeout_ms + 750;
        const io = self.io;
        const started_ms = self.started_ms;
        return self.takeResult(wait_ms) orelse Result{ .failed = .{
            .reason = "WorkerTimeout",
            .latency_ms = @intCast(@max(0, std.Io.Clock.now(.awake, io).toMilliseconds() - started_ms)),
        } };
    }

    pub fn cancel(self: *Session) void {
        const gpa = self.gpa;
        self.cancel_requested.store(true, .release);
        self.finish_requested.store(true, .release);
        if (self.takeResult(750)) |result| freeResult(gpa, result);
    }

    fn takeResult(self: *Session, wait_ms: u32) ?Result {
        const deadline = std.Io.Clock.now(.awake, self.io).toMilliseconds() + wait_ms;
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.result) |result| {
                self.result = null;
                self.mutex.unlock(self.io);
                self.destroy();
                return result;
            }
            if (std.Io.Clock.now(.awake, self.io).toMilliseconds() >= deadline) {
                self.cancel_requested.store(true, .release);
                self.owner_released = true;
                self.mutex.unlock(self.io);
                return null;
            }
            self.mutex.unlock(self.io);
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
    }

    fn destroy(self: *Session) void {
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    fn publishResult(self: *Session, result: Result) void {
        self.mutex.lockUncancelable(self.io);
        if (!self.owner_released) {
            self.result = result;
            self.mutex.unlock(self.io);
            return;
        }
        self.mutex.unlock(self.io);
        freeResult(self.gpa, result);
        self.destroy();
    }

    fn run(self: *Session) !Success {
        const connect_started = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        var client = try websocket.Client.init(self.io, self.gpa, .{
            .host = streamHost(self.cfg.region),
            .port = 443,
            .tls = true,
            .max_size = 1024 * 1024,
            .buffer_size = 16 * 1024,
            .connect_timeout_ms = 2500,
        });
        defer client.deinit();
        if (self.cancel_requested.load(.acquire)) return error.Cancelled;

        const base_path = try std.fmt.allocPrint(
            self.gpa,
            "/v1/listen?model={s}&language={s}&encoding=linear16&sample_rate=16000&channels=1&smart_format=true&punctuate=true&interim_results=true&endpointing=300",
            .{ self.cfg.model, self.cfg.language },
        );
        defer self.gpa.free(base_path);
        const path = try deepgram.addKeyterms(self.gpa, base_path, self.cfg.keyterms);
        defer self.gpa.free(path);
        const headers = try std.fmt.allocPrint(self.gpa, "Host: {s}\r\nAuthorization: Token {s}\r\n", .{
            streamHost(self.cfg.region),
            self.cfg.api_key,
        });
        defer self.gpa.free(headers);
        try client.handshake(path, .{ .timeout_ms = 2500, .headers = headers });
        if (self.cancel_requested.load(.acquire)) return error.Cancelled;
        const connect_ms: u64 = @intCast(@max(0, std.Io.Clock.now(.awake, self.io).toMilliseconds() - connect_started));
        try client.writeTimeout(500);
        try client.readTimeout(1);

        var transcript: std.ArrayList(u8) = .empty;
        defer transcript.deinit(self.gpa);
        var metadata_received = false;
        var file = try openRecording(self);
        defer file.close(self.io);
        var offset: u64 = 0;

        while (true) {
            if (self.cancel_requested.load(.acquire)) return error.Cancelled;
            var chunk: [3200]u8 = undefined;
            const buffers = [_][]u8{chunk[0..]};
            const read_len = file.readPositional(self.io, &buffers, offset) catch return error.RecordingReadFailed;
            const aligned_len = read_len - (read_len % 2);
            if (aligned_len > 0) {
                offset += aligned_len;
                try client.writeBin(chunk[0..aligned_len]);
                try drainAvailable(&client, self, &transcript, &metadata_received);
                continue;
            }
            if (self.finish_requested.load(.acquire)) break;
            std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch return error.Cancelled;
        }

        var close_stream = [_]u8{ '{', '"', 't', 'y', 'p', 'e', '"', ':', '"', 'C', 'l', 'o', 's', 'e', 'S', 't', 'r', 'e', 'a', 'm', '"', '}' };
        try client.writeText(&close_stream);

        const deadline = std.Io.Clock.now(.awake, self.io).toMilliseconds() + self.cfg.stream_finalize_timeout_ms;
        while (!metadata_received) {
            if (self.cancel_requested.load(.acquire)) return error.Cancelled;
            const remaining = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds();
            if (remaining <= 0) return error.FinalizeTimeout;
            try client.readTimeout(@intCast(@min(remaining, 250)));
            const message = client.read() catch |err| switch (err) {
                error.Closed => if (metadata_received) break else return error.ClosedBeforeMetadata,
                else => return err,
            } orelse continue;
            defer client.done(message);
            if (message.type == .ping) {
                try client.writePong(message.data);
                continue;
            }
            try processMessage(self.gpa, &transcript, message, &metadata_received);
        }

        const owned = try transcript.toOwnedSlice(self.gpa);
        const finish_started = self.finish_started_ms.load(.acquire);
        const stop_to_final_ms: u64 = @intCast(@max(0, std.Io.Clock.now(.awake, self.io).toMilliseconds() - finish_started));
        return .{
            .transcript = owned,
            .latency_ms = self.elapsedMs(),
            .connect_ms = connect_ms,
            .stop_to_final_ms = stop_to_final_ms,
        };
    }

    fn elapsedMs(self: *const Session) u64 {
        return @intCast(@max(0, std.Io.Clock.now(.awake, self.io).toMilliseconds() - self.started_ms));
    }
};

fn workerMain(self: *Session) void {
    const result = if (self.run()) |success|
        Result{ .success = success }
    else |err|
        Result{ .failed = .{
            .reason = @errorName(err),
            .latency_ms = self.elapsedMs(),
        } };
    self.publishResult(result);
}

fn freeResult(gpa: Allocator, result: Result) void {
    switch (result) {
        .success => |success| gpa.free(success.transcript),
        .failed => {},
    }
}

fn openRecording(self: *Session) !Io.File {
    var attempt: usize = 0;
    while (attempt < 80) : (attempt += 1) {
        if (Io.Dir.openFileAbsolute(self.io, self.path, .{})) |file| return file else |_| {}
        if (self.cancel_requested.load(.acquire)) return error.Cancelled;
        std.Io.sleep(self.io, .fromMilliseconds(25), .awake) catch return error.Cancelled;
    }
    return error.RecordingOpenFailed;
}

fn drainAvailable(client: *websocket.Client, session: *Session, transcript: *std.ArrayList(u8), metadata_received: *bool) !void {
    var drained: usize = 0;
    while (drained < 32) : (drained += 1) {
        if (session.cancel_requested.load(.acquire)) return error.Cancelled;
        const message = client.read() catch |err| switch (err) {
            error.Closed => return,
            else => return err,
        } orelse return;
        defer client.done(message);
        if (message.type == .ping) {
            try client.writePong(message.data);
            continue;
        }
        try processMessage(session.gpa, transcript, message, metadata_received);
    }
}

const StreamEvent = struct {
    type: []const u8,
    is_final: bool = false,
    channel: ?struct {
        alternatives: []struct {
            transcript: []const u8,
        },
    } = null,
};

fn processMessage(gpa: Allocator, transcript: *std.ArrayList(u8), message: websocket.Message, metadata_received: *bool) !void {
    switch (message.type) {
        .text => {},
        .ping => return,
        .pong, .binary => return,
        .close => return error.ProviderClosed,
    }
    const parsed = try std.json.parseFromSlice(StreamEvent, gpa, message.data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const event = parsed.value;
    if (std.mem.eql(u8, event.type, "Metadata")) {
        metadata_received.* = true;
        return;
    }
    if (std.mem.eql(u8, event.type, "Error")) return error.ProviderError;
    if (!std.mem.eql(u8, event.type, "Results") or !event.is_final) return;
    const channel = event.channel orelse return;
    if (channel.alternatives.len == 0) return;
    const segment = std.mem.trim(u8, channel.alternatives[0].transcript, " \t\r\n");
    if (segment.len == 0) return;
    if (transcript.items.len > 0) try transcript.append(gpa, ' ');
    try transcript.appendSlice(gpa, segment);
}

pub fn streamHost(region: []const u8) []const u8 {
    if (std.mem.eql(u8, region, "eu")) return "api.eu.deepgram.com";
    if (std.mem.eql(u8, region, "au")) return "api.au.deepgram.com";
    return "api.deepgram.com";
}

test "streaming results append only final transcript segments" {
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(std.testing.allocator);
    var metadata = false;
    var draft = "{\"type\":\"Results\",\"is_final\":false,\"channel\":{\"alternatives\":[{\"transcript\":\"draft\"}]}}".*;
    var final = "{\"type\":\"Results\",\"is_final\":true,\"channel\":{\"alternatives\":[{\"transcript\":\"hello world\"}]}}".*;
    var metadata_message = "{\"type\":\"Metadata\"}".*;
    try processMessage(std.testing.allocator, &transcript, .{
        .type = .text,
        .data = &draft,
    }, &metadata);
    try processMessage(std.testing.allocator, &transcript, .{
        .type = .text,
        .data = &final,
    }, &metadata);
    try processMessage(std.testing.allocator, &transcript, .{
        .type = .text,
        .data = &metadata_message,
    }, &metadata);
    try std.testing.expectEqualStrings("hello world", transcript.items);
    try std.testing.expect(metadata);
}

test "regional streaming hosts are allow-listed" {
    try std.testing.expectEqualStrings("api.deepgram.com", streamHost("global"));
    try std.testing.expectEqualStrings("api.eu.deepgram.com", streamHost("eu"));
    try std.testing.expectEqualStrings("api.au.deepgram.com", streamHost("au"));
}
