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
    cfg: config.SttConfig,
    path: []u8,
    max_audio_bytes: ?u64,
    started_ms: i64,
    finish_requested: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    finish_started_ms: std.atomic.Value(i64) = .init(0),
    mutex: Io.Mutex = .init,
    owner_released: bool = false,
    result: ?Result = null,

    pub fn start(gpa: Allocator, io: Io, cfg: *const config.SttConfig, path: []const u8) !*Session {
        return startBounded(gpa, io, cfg, path, null);
    }

    pub fn startBounded(gpa: Allocator, io: Io, cfg: *const config.SttConfig, path: []const u8, max_audio_bytes: ?u64) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        const owned_cfg = try cloneConfig(gpa, cfg);
        errdefer freeConfig(gpa, owned_cfg);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .cfg = owned_cfg,
            .path = try gpa.dupe(u8, path),
            .max_audio_bytes = max_audio_bytes,
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
        freeConfig(self.gpa, self.cfg);
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

        const path = try listenPath(self.gpa, &self.cfg);
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
            const remaining = if (self.max_audio_bytes) |maximum| maximum -| offset else chunk.len;
            if (remaining == 0) {
                if (!self.finish_requested.load(.acquire)) return error.AudioTooLarge;
                break;
            }
            const buffers = [_][]u8{chunk[0..@min(chunk.len, remaining)]};
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

fn cloneConfig(gpa: Allocator, source: *const config.SttConfig) !config.SttConfig {
    const provider = try gpa.dupe(u8, source.provider);
    errdefer gpa.free(provider);
    const api_key = try gpa.dupe(u8, source.api_key);
    errdefer gpa.free(api_key);
    const model = try gpa.dupe(u8, source.model);
    errdefer gpa.free(model);
    const language = try gpa.dupe(u8, source.language);
    errdefer gpa.free(language);
    const region = try gpa.dupe(u8, source.region);
    errdefer gpa.free(region);
    const keyterms = try gpa.alloc([]const u8, source.keyterms.len);
    errdefer gpa.free(keyterms);
    var initialized: usize = 0;
    errdefer for (keyterms[0..initialized]) |keyterm| gpa.free(keyterm);
    for (source.keyterms, 0..) |keyterm, index| {
        keyterms[index] = try gpa.dupe(u8, keyterm);
        initialized += 1;
    }
    return .{
        .provider = provider,
        .api_key = api_key,
        .model = model,
        .language = language,
        .keyterms = keyterms,
        .region = region,
        .streaming = source.streaming,
        .stream_finalize_timeout_ms = source.stream_finalize_timeout_ms,
    };
}

fn freeConfig(gpa: Allocator, cfg: config.SttConfig) void {
    gpa.free(cfg.provider);
    gpa.free(cfg.api_key);
    gpa.free(cfg.model);
    gpa.free(cfg.language);
    for (cfg.keyterms) |keyterm| gpa.free(keyterm);
    gpa.free(cfg.keyterms);
    gpa.free(cfg.region);
}

fn listenPath(gpa: Allocator, cfg: *const config.SttConfig) ![]u8 {
    const base_path = try std.fmt.allocPrint(
        gpa,
        "/v1/listen?model={s}&language={s}&encoding=linear16&sample_rate=16000&channels=1&{s}&interim_results=true&endpointing=300",
        .{ cfg.model, cfg.language, deepgram.formatting_params },
    );
    defer gpa.free(base_path);
    return deepgram.addKeyterms(gpa, base_path, cfg.keyterms);
}

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
        if (Io.Dir.cwd().openFile(self.io, self.path, .{ .allow_directory = false, .follow_symlinks = false })) |file| {
            const stat = file.stat(self.io) catch {
                file.close(self.io);
                return error.RecordingStatFailed;
            };
            if (stat.kind != .file) {
                file.close(self.io);
                return error.InvalidRecording;
            }
            return file;
        } else |_| {}
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
    const segment = std.mem.trim(u8, channel.alternatives[0].transcript, " \t");
    if (segment.len == 0) return;
    const needs_separator = transcript.items.len > 0 and
        !std.ascii.isWhitespace(transcript.items[transcript.items.len - 1]) and
        !std.ascii.isWhitespace(segment[0]);
    if (transcript.items.len + segment.len + @intFromBool(needs_separator) > 1024 * 1024) return error.TranscriptTooLarge;
    if (needs_separator) try transcript.append(gpa, ' ');
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

test "streaming path uses effective keyterms" {
    var cfg: config.SttConfig = .{};
    cfg.keyterms = &.{ "SayAll", "Model Context Protocol", "München" };
    const path = try listenPath(std.testing.allocator, &cfg);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.indexOf(
        u8,
        path,
        "&smart_format=true&punctuate=true&dictation=true&numerals=true&measurements=true&",
    ) != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        path,
        "&keyterm=SayAll&keyterm=Model%20Context%20Protocol&keyterm=M%C3%BCnchen",
    ));
}

test "stream session configuration owns all caller-backed values" {
    var api_key = "secret".*;
    var region = "global".*;
    var keyterm = "SayAll".*;
    const source: config.SttConfig = .{
        .api_key = &api_key,
        .region = &region,
        .keyterms = &.{&keyterm},
    };
    const owned = try cloneConfig(std.testing.allocator, &source);
    defer freeConfig(std.testing.allocator, owned);
    @memset(&api_key, 'x');
    @memset(&region, 'x');
    @memset(&keyterm, 'x');
    try std.testing.expectEqualStrings("secret", owned.api_key);
    try std.testing.expectEqualStrings("global", owned.region);
    try std.testing.expectEqualStrings("SayAll", owned.keyterms[0]);
}

test "streaming preserves dictated newlines between final segments" {
    var transcript: std.ArrayList(u8) = .empty;
    defer transcript.deinit(std.testing.allocator);
    var metadata = false;
    var first = "{\"type\":\"Results\",\"is_final\":true,\"channel\":{\"alternatives\":[{\"transcript\":\"first line\\n\"}]}}".*;
    var second = "{\"type\":\"Results\",\"is_final\":true,\"channel\":{\"alternatives\":[{\"transcript\":\"second line\"}]}}".*;
    try processMessage(std.testing.allocator, &transcript, .{
        .type = .text,
        .data = &first,
    }, &metadata);
    try processMessage(std.testing.allocator, &transcript, .{
        .type = .text,
        .data = &second,
    }, &metadata);
    try std.testing.expectEqualStrings("first line\nsecond line", transcript.items);
}
