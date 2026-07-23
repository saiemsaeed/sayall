const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const deepgram = @import("stt/deepgram.zig");

pub const Outcome = enum { success, no_speech, failed };

pub const Totals = struct {
    attempts: u64 = 0,
    successful: u64 = 0,
    no_speech: u64 = 0,
    failed: u64 = 0,
    pre_stt_failed: u64 = 0,
    latency_count: u64 = 0,
    latency_sum_ms: u64 = 0,
    latency_min_ms: ?u64 = null,
    latency_max_ms: ?u64 = null,
};

pub const ActiveAttempt = struct {
    attempt_id: []const u8,
    started_at_unix_ms: i64,
    source: []const u8,
    provider: []const u8,
    model: []const u8,
    language: []const u8,
    audio_ms: u64,
    region: ?[]const u8 = null,
    transport: ?[]const u8 = null,
};

pub const Record = struct {
    attempt_id: []const u8,
    started_at_unix_ms: i64,
    source: []const u8,
    provider: []const u8,
    model: []const u8,
    language: []const u8,
    audio_ms: u64,
    latency_ms: u64,
    outcome: Outcome,
    reason: ?[]const u8 = null,
    region: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    stop_to_final_ms: ?u64 = null,
    word_count: ?u64 = null,
    character_count: ?u64 = null,
    connection_ms: ?u64 = null,
};

pub const State = struct {
    version: u16 = 2,
    totals: Totals = .{},
    active_attempts: []const ActiveAttempt = &.{},
    history: []const Record = &.{},
};

pub const AttemptMetadata = struct {
    source: []const u8,
    provider: []const u8,
    model: []const u8,
    language: []const u8,
    audio_ms: u64,
    region: []const u8,
    transport: []const u8,
};

pub const CompletionMetadata = struct {
    outcome: Outcome,
    reason: ?[]const u8 = null,
    latency_ms: u64,
    stop_to_final_ms: ?u64 = null,
    word_count: ?u64 = null,
    character_count: ?u64 = null,
    connection_ms: ?u64 = null,
};

pub const TransportSummary = struct {
    attempts: usize,
    samples: usize,
    failed: usize,
    average_latency_ms: ?u64,
    p50_latency_ms: ?u64,
    p95_latency_ms: ?u64,
    realtime_factor: ?f64,
    average_connection_ms: ?u64,
};

pub const Summary = struct {
    attempts: u64,
    successful: u64,
    no_speech: u64,
    failed: u64,
    pre_stt_failed: u64,
    success_rate: f64,
    average_latency_ms: ?u64,
    minimum_latency_ms: ?u64,
    maximum_latency_ms: ?u64,
    recent_p50_ms: ?u64,
    recent_p95_ms: ?u64,
    normalized_samples: usize,
    realtime_factor: ?f64,
    average_latency_ms_per_audio_second: ?f64,
    content_samples: usize,
    average_latency_ms_per_word: ?f64,
    average_latency_ms_per_character: ?f64,
    stop_to_final_samples: usize,
    average_stop_to_final_ms: ?u64,
    stop_to_final_p50_ms: ?u64,
    stop_to_final_p95_ms: ?u64,
    stop_to_final_under_500: usize,
    stop_to_final_under_500_percentage: ?f64,
    global_rest: TransportSummary,
    eu_rest: TransportSummary,
    au_rest: TransportSummary,
    global_stream: TransportSummary,
    eu_stream: TransportSummary,
    au_stream: TransportSummary,
    history_entries: usize,
    history_limit: u32,
};

pub const TrackedResult = struct {
    transcript: []u8,
    latency_ms: u64,
    outcome: Outcome,
};

pub fn transcribeTracked(
    gpa: Allocator,
    io: Io,
    store: ?Store,
    cfg: *const config.SttConfig,
    wav: []const u8,
    verbose: bool,
    source: []const u8,
    audio_ms: u64,
    stopped_at_awake_ms: ?i64,
) deepgram.TranscribeError!TrackedResult {
    var attempt_id: ?[]u8 = null;
    defer if (attempt_id) |id| gpa.free(id);
    if (store) |metrics_store| {
        attempt_id = metrics_store.begin(gpa, io, .{
            .source = source,
            .provider = cfg.provider,
            .model = cfg.model,
            .language = cfg.language,
            .audio_ms = audio_ms,
            .region = cfg.region,
            .transport = "rest",
        }) catch null;
    }

    const started = std.Io.Clock.now(.awake, io).toMilliseconds();
    const transcript = deepgram.transcribe(gpa, io, cfg, wav, verbose) catch |err| {
        const elapsed: u64 = @intCast(@max(0, std.Io.Clock.now(.awake, io).toMilliseconds() - started));
        if (store) |metrics_store| if (attempt_id) |id| {
            metrics_store.complete(gpa, io, id, .{
                .outcome = .failed,
                .reason = reasonForError(err),
                .latency_ms = elapsed,
            }) catch {};
        };
        return err;
    };
    const elapsed: u64 = @intCast(@max(0, std.Io.Clock.now(.awake, io).toMilliseconds() - started));
    const outcome: Outcome = if (transcript.len == 0) .no_speech else .success;
    const stop_to_final_ms: ?u64 = if (stopped_at_awake_ms) |stopped|
        @intCast(@max(0, std.Io.Clock.now(.awake, io).toMilliseconds() - stopped))
    else
        null;
    if (store) |metrics_store| if (attempt_id) |id| {
        metrics_store.complete(gpa, io, id, .{
            .outcome = outcome,
            .latency_ms = elapsed,
            .stop_to_final_ms = stop_to_final_ms,
            .word_count = if (outcome == .success) countWords(transcript) else null,
            .character_count = if (outcome == .success) countCharacters(transcript) else null,
        }) catch {};
    };
    return .{ .transcript = transcript, .latency_ms = elapsed, .outcome = outcome };
}

pub fn recordCompletedTranscript(
    gpa: Allocator,
    io: Io,
    store: ?Store,
    cfg: *const config.SttConfig,
    source: []const u8,
    audio_ms: u64,
    transport: []const u8,
    transcript: []const u8,
    latency_ms: u64,
    stop_to_final_ms: u64,
    connection_ms: u64,
) void {
    const metrics_store = store orelse return;
    const id = metrics_store.begin(gpa, io, .{
        .source = source,
        .provider = cfg.provider,
        .model = cfg.model,
        .language = cfg.language,
        .audio_ms = audio_ms,
        .region = cfg.region,
        .transport = transport,
    }) catch return;
    defer gpa.free(id);
    const outcome: Outcome = if (transcript.len == 0) .no_speech else .success;
    metrics_store.complete(gpa, io, id, .{
        .outcome = outcome,
        .latency_ms = latency_ms,
        .stop_to_final_ms = stop_to_final_ms,
        .word_count = if (outcome == .success) countWords(transcript) else null,
        .character_count = if (outcome == .success) countCharacters(transcript) else null,
        .connection_ms = connection_ms,
    }) catch {};
}

pub fn recordFailedStream(
    gpa: Allocator,
    io: Io,
    store: ?Store,
    cfg: *const config.SttConfig,
    source: []const u8,
    audio_ms: u64,
    reason: []const u8,
    latency_ms: u64,
) void {
    const metrics_store = store orelse return;
    const id = metrics_store.begin(gpa, io, .{
        .source = source,
        .provider = cfg.provider,
        .model = cfg.model,
        .language = cfg.language,
        .audio_ms = audio_ms,
        .region = cfg.region,
        .transport = "stream",
    }) catch return;
    defer gpa.free(id);
    metrics_store.complete(gpa, io, id, .{
        .outcome = .failed,
        .reason = reason,
        .latency_ms = latency_ms,
    }) catch {};
}

fn countWords(text: []const u8) u64 {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var count: u64 = 0;
    while (words.next() != null) count += 1;
    return count;
}

fn countCharacters(text: []const u8) u64 {
    return @intCast(std.unicode.utf8CountCodepoints(text) catch text.len);
}

fn reasonForError(err: deepgram.TranscribeError) []const u8 {
    return switch (err) {
        error.MissingApiKey => "missing_api_key",
        error.Unauthorized => "unauthorized",
        error.RateLimited => "rate_limited",
        error.ServerError => "server_error",
        error.RequestFailed => "transport",
        error.BadStatus => "http_status",
        error.BadResponse => "invalid_response",
        error.ResponseTooLarge => "response_too_large",
        error.OutOfMemory => "out_of_memory",
    };
}

pub const Store = struct {
    path: []const u8,
    history_limit: u32,

    pub fn init(path: []const u8, history_limit: u32) Store {
        return .{ .path = path, .history_limit = history_limit };
    }

    pub fn begin(self: Store, gpa: Allocator, io: Io, metadata: AttemptMetadata) ![]u8 {
        try self.ensureDirectory(io);
        const attempt_id = try randomId(gpa, io);
        errdefer gpa.free(attempt_id);

        var change: BeginUpdate = .{
            .attempt_id = attempt_id,
            .started_at_unix_ms = std.Io.Clock.now(.real, io).toMilliseconds(),
            .metadata = metadata,
        };
        try self.update(gpa, io, &change, BeginUpdate.apply);
        return attempt_id;
    }

    pub fn complete(
        self: Store,
        gpa: Allocator,
        io: Io,
        attempt_id: []const u8,
        completion: CompletionMetadata,
    ) !void {
        var change: CompleteUpdate = .{
            .attempt_id = attempt_id,
            .completion = completion,
            .history_limit = self.history_limit,
        };
        try self.update(gpa, io, &change, CompleteUpdate.apply);
    }

    pub fn recordPreSttFailure(self: Store, gpa: Allocator, io: Io) !void {
        var change: PreSttUpdate = .{};
        try self.update(gpa, io, &change, PreSttUpdate.apply);
    }

    pub fn reconcileInterrupted(self: Store, gpa: Allocator, io: Io) !void {
        var change: ReconcileUpdate = .{ .history_limit = self.history_limit };
        try self.update(gpa, io, &change, ReconcileUpdate.apply);
    }

    pub fn summary(self: Store, gpa: Allocator, io: Io) !Summary {
        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const state = try self.load(arena_state.allocator(), io);
        return summarize(gpa, state, self.history_limit);
    }

    fn update(self: Store, gpa: Allocator, io: Io, context: anytype, apply: anytype) !void {
        try self.ensureDirectory(io);
        var locked = try self.lock(io);
        defer locked.close(io);

        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var state = try self.load(arena, io);
        if (state.version != 2) return error.UnsupportedMetricsVersion;
        try apply(context, arena, &state);
        try self.atomicWrite(gpa, io, state);
    }

    fn ensureDirectory(self: Store, io: Io) !void {
        const parent = std.fs.path.dirname(self.path) orelse return error.InvalidMetricsPath;
        const dir = try Io.Dir.cwd().createDirPathOpen(io, parent, .{
            .open_options = .{ .iterate = true },
            .permissions = @enumFromInt(0o700),
        });
        defer dir.close(io);
        try dir.setPermissions(io, @enumFromInt(0o700));
    }

    fn lock(self: Store, io: Io) !Io.File {
        const lock_path = try std.fmt.allocPrint(std.heap.smp_allocator, "{s}.lock", .{self.path});
        defer std.heap.smp_allocator.free(lock_path);
        return Io.Dir.createFileAbsolute(io, lock_path, .{
            .truncate = false,
            .lock = .exclusive,
            .permissions = @enumFromInt(0o600),
        });
    }

    fn load(self: Store, gpa: Allocator, io: Io) !State {
        const bytes = Io.Dir.cwd().readFileAlloc(io, self.path, gpa, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => blk: {
                const suffix = "metrics-v2.json";
                if (!std.mem.endsWith(u8, self.path, suffix)) return .{};
                const legacy_path = try std.fmt.allocPrint(gpa, "{s}metrics-v1.json", .{self.path[0 .. self.path.len - suffix.len]});
                break :blk Io.Dir.cwd().readFileAlloc(io, legacy_path, gpa, .limited(8 * 1024 * 1024)) catch |legacy_err| switch (legacy_err) {
                    error.FileNotFound => return .{},
                    else => return legacy_err,
                };
            },
            else => return err,
        };
        var state = try std.json.parseFromSliceLeaky(State, gpa, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        if (state.version == 1) try migrateV1(gpa, &state);
        return state;
    }

    fn atomicWrite(self: Store, gpa: Allocator, io: Io, state: State) !void {
        const json = try std.json.Stringify.valueAlloc(gpa, state, .{ .whitespace = .indent_2 });
        defer gpa.free(json);
        var nonce: u64 = undefined;
        try std.Io.randomSecure(io, std.mem.asBytes(&nonce));
        const temp_path = try std.fmt.allocPrint(gpa, "{s}.tmp-{x}", .{ self.path, nonce });
        defer gpa.free(temp_path);
        errdefer Io.Dir.deleteFileAbsolute(io, temp_path) catch {};

        const file = try Io.Dir.createFileAbsolute(io, temp_path, .{ .permissions = @enumFromInt(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, json);
        try file.sync(io);
        try Io.Dir.rename(.cwd(), temp_path, .cwd(), self.path, io);
    }
};

const BeginUpdate = struct {
    attempt_id: []const u8,
    started_at_unix_ms: i64,
    metadata: AttemptMetadata,

    fn apply(self: *BeginUpdate, arena: Allocator, state: *State) !void {
        const attempts = try arena.alloc(ActiveAttempt, state.active_attempts.len + 1);
        @memcpy(attempts[0..state.active_attempts.len], state.active_attempts);
        attempts[state.active_attempts.len] = .{
            .attempt_id = self.attempt_id,
            .started_at_unix_ms = self.started_at_unix_ms,
            .source = self.metadata.source,
            .provider = self.metadata.provider,
            .model = self.metadata.model,
            .language = self.metadata.language,
            .audio_ms = self.metadata.audio_ms,
            .region = self.metadata.region,
            .transport = self.metadata.transport,
        };
        state.active_attempts = attempts;
    }
};

const CompleteUpdate = struct {
    attempt_id: []const u8,
    completion: CompletionMetadata,
    history_limit: u32,

    fn apply(self: *CompleteUpdate, arena: Allocator, state: *State) !void {
        const index = findActive(state.active_attempts, self.attempt_id) orelse return error.AttemptNotFound;
        const active = state.active_attempts[index];
        const remaining = try arena.alloc(ActiveAttempt, state.active_attempts.len - 1);
        @memcpy(remaining[0..index], state.active_attempts[0..index]);
        @memcpy(remaining[index..], state.active_attempts[index + 1 ..]);
        state.active_attempts = remaining;
        appendRecord(arena, state, .{
            .attempt_id = active.attempt_id,
            .started_at_unix_ms = active.started_at_unix_ms,
            .source = active.source,
            .provider = active.provider,
            .model = active.model,
            .language = active.language,
            .audio_ms = active.audio_ms,
            .latency_ms = self.completion.latency_ms,
            .outcome = self.completion.outcome,
            .reason = self.completion.reason,
            .region = active.region,
            .transport = active.transport,
            .stop_to_final_ms = self.completion.stop_to_final_ms,
            .word_count = self.completion.word_count,
            .character_count = self.completion.character_count,
            .connection_ms = self.completion.connection_ms,
        }, self.history_limit) catch return error.OutOfMemory;
        account(&state.totals, self.completion.outcome, self.completion.latency_ms);
    }
};

const PreSttUpdate = struct {
    fn apply(_: *PreSttUpdate, _: Allocator, state: *State) !void {
        state.totals.pre_stt_failed += 1;
    }
};

const ReconcileUpdate = struct {
    history_limit: u32,

    fn apply(self: *ReconcileUpdate, arena: Allocator, state: *State) !void {
        const active = state.active_attempts;
        for (active) |attempt| {
            try appendRecord(arena, state, .{
                .attempt_id = attempt.attempt_id,
                .started_at_unix_ms = attempt.started_at_unix_ms,
                .source = attempt.source,
                .provider = attempt.provider,
                .model = attempt.model,
                .language = attempt.language,
                .audio_ms = attempt.audio_ms,
                .latency_ms = 0,
                .outcome = .failed,
                .reason = "interrupted",
                .region = attempt.region,
                .transport = attempt.transport,
            }, self.history_limit);
            state.totals.attempts += 1;
            state.totals.failed += 1;
        }
        state.active_attempts = &.{};
    }
};

fn migrateV1(arena: Allocator, state: *State) !void {
    if (state.version != 1) return;

    const active = try arena.alloc(ActiveAttempt, state.active_attempts.len);
    for (state.active_attempts, 0..) |attempt, index| {
        active[index] = attempt;
        active[index].region = "global";
        active[index].transport = "rest";
    }
    const history = try arena.alloc(Record, state.history.len);
    for (state.history, 0..) |record, index| {
        history[index] = record;
        history[index].region = "global";
        history[index].transport = "rest";
    }
    state.active_attempts = active;
    state.history = history;
    state.version = 2;
}

fn appendRecord(arena: Allocator, state: *State, record: Record, limit: u32) !void {
    if (limit == 0) {
        state.history = &.{};
        return;
    }
    const keep = @min(state.history.len, @as(usize, limit - 1));
    const history = try arena.alloc(Record, keep + 1);
    if (keep > 0) @memcpy(history[0..keep], state.history[state.history.len - keep ..]);
    history[keep] = record;
    state.history = history;
}

fn account(totals: *Totals, outcome: Outcome, latency_ms: u64) void {
    totals.attempts += 1;
    switch (outcome) {
        .success => totals.successful += 1,
        .no_speech => totals.no_speech += 1,
        .failed => totals.failed += 1,
    }
    totals.latency_count += 1;
    totals.latency_sum_ms += latency_ms;
    totals.latency_min_ms = if (totals.latency_min_ms) |value| @min(value, latency_ms) else latency_ms;
    totals.latency_max_ms = if (totals.latency_max_ms) |value| @max(value, latency_ms) else latency_ms;
}

fn findActive(attempts: []const ActiveAttempt, id: []const u8) ?usize {
    for (attempts, 0..) |attempt, index| if (std.mem.eql(u8, attempt.attempt_id, id)) return index;
    return null;
}

fn randomId(gpa: Allocator, io: Io) ![]u8 {
    var bytes: [16]u8 = undefined;
    try std.Io.randomSecure(io, &bytes);
    const hex = std.fmt.bytesToHex(bytes, .lower);
    return gpa.dupe(u8, &hex);
}

pub fn summarize(gpa: Allocator, state: State, history_limit: u32) !Summary {
    const latency_storage = try gpa.alloc(u64, state.history.len);
    defer gpa.free(latency_storage);
    const stop_storage = try gpa.alloc(u64, state.history.len);
    defer gpa.free(stop_storage);
    var count: usize = 0;
    var stop_count: usize = 0;
    var stop_sum: u64 = 0;
    var stop_under_500: usize = 0;
    var normalized_samples: usize = 0;
    var normalized_latency_sum: u64 = 0;
    var audio_sum: u64 = 0;
    var content_samples: usize = 0;
    var content_latency_sum: u64 = 0;
    var word_sum: u64 = 0;
    var character_sum: u64 = 0;
    for (state.history) |record| {
        if (record.reason != null and std.mem.eql(u8, record.reason.?, "interrupted")) continue;
        latency_storage[count] = record.latency_ms;
        count += 1;
        if (record.outcome != .success) continue;
        if (record.audio_ms > 0) {
            normalized_samples += 1;
            normalized_latency_sum += record.latency_ms;
            audio_sum += record.audio_ms;
        }
        if (record.word_count) |words| if (record.character_count) |characters| {
            if (words > 0 and characters > 0) {
                content_samples += 1;
                content_latency_sum += record.latency_ms;
                word_sum += words;
                character_sum += characters;
            }
        };
        if (record.stop_to_final_ms) |value| {
            stop_storage[stop_count] = value;
            stop_count += 1;
            stop_sum += value;
            if (value < 500) stop_under_500 += 1;
        }
    }
    const latencies = latency_storage[0..count];
    const stop_latencies = stop_storage[0..stop_count];
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    std.mem.sort(u64, stop_latencies, {}, std.sort.asc(u64));
    const average = if (state.totals.latency_count == 0) null else state.totals.latency_sum_ms / state.totals.latency_count;
    const rtf = ratio(normalized_latency_sum, audio_sum);
    return .{
        .attempts = state.totals.attempts,
        .successful = state.totals.successful,
        .no_speech = state.totals.no_speech,
        .failed = state.totals.failed,
        .pre_stt_failed = state.totals.pre_stt_failed,
        .success_rate = if (state.totals.attempts == 0) 0 else @as(f64, @floatFromInt(state.totals.successful)) / @as(f64, @floatFromInt(state.totals.attempts)),
        .average_latency_ms = average,
        .minimum_latency_ms = state.totals.latency_min_ms,
        .maximum_latency_ms = state.totals.latency_max_ms,
        .recent_p50_ms = percentile(latencies, 50),
        .recent_p95_ms = percentile(latencies, 95),
        .normalized_samples = normalized_samples,
        .realtime_factor = rtf,
        .average_latency_ms_per_audio_second = if (rtf) |value| value * 1000.0 else null,
        .content_samples = content_samples,
        .average_latency_ms_per_word = ratio(content_latency_sum, word_sum),
        .average_latency_ms_per_character = ratio(content_latency_sum, character_sum),
        .stop_to_final_samples = stop_count,
        .average_stop_to_final_ms = if (stop_count == 0) null else stop_sum / stop_count,
        .stop_to_final_p50_ms = percentile(stop_latencies, 50),
        .stop_to_final_p95_ms = percentile(stop_latencies, 95),
        .stop_to_final_under_500 = stop_under_500,
        .stop_to_final_under_500_percentage = if (stop_count == 0) null else @as(f64, @floatFromInt(stop_under_500)) * 100.0 / @as(f64, @floatFromInt(stop_count)),
        .global_rest = try summarizeTransport(gpa, state.history, "global", "rest"),
        .eu_rest = try summarizeTransport(gpa, state.history, "eu", "rest"),
        .au_rest = try summarizeTransport(gpa, state.history, "au", "rest"),
        .global_stream = try summarizeTransport(gpa, state.history, "global", "stream"),
        .eu_stream = try summarizeTransport(gpa, state.history, "eu", "stream"),
        .au_stream = try summarizeTransport(gpa, state.history, "au", "stream"),
        .history_entries = state.history.len,
        .history_limit = history_limit,
    };
}

fn summarizeTransport(gpa: Allocator, history: []const Record, region: []const u8, transport: []const u8) !TransportSummary {
    const storage = try gpa.alloc(u64, history.len);
    defer gpa.free(storage);
    var count: usize = 0;
    var latency_sum: u64 = 0;
    var audio_sum: u64 = 0;
    var connection_count: usize = 0;
    var connection_sum: u64 = 0;
    var attempts: usize = 0;
    var failed: usize = 0;
    for (history) |record| {
        const record_region = record.region orelse "global";
        const record_transport = record.transport orelse "rest";
        if (!std.mem.eql(u8, record_region, region) or !std.mem.eql(u8, record_transport, transport)) continue;
        attempts += 1;
        if (record.outcome == .failed) failed += 1;
        if (record.connection_ms) |value| {
            connection_count += 1;
            connection_sum += value;
        }
        if (record.outcome != .success) continue;
        storage[count] = record.latency_ms;
        count += 1;
        latency_sum += record.latency_ms;
        audio_sum += record.audio_ms;
    }
    const latencies = storage[0..count];
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    return .{
        .attempts = attempts,
        .samples = count,
        .failed = failed,
        .average_latency_ms = if (count == 0) null else latency_sum / count,
        .p50_latency_ms = percentile(latencies, 50),
        .p95_latency_ms = percentile(latencies, 95),
        .realtime_factor = ratio(latency_sum, audio_sum),
        .average_connection_ms = if (connection_count == 0) null else connection_sum / connection_count,
    };
}

fn ratio(numerator: u64, denominator: u64) ?f64 {
    if (denominator == 0) return null;
    return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
}

fn percentile(sorted: []const u64, value: usize) ?u64 {
    if (sorted.len == 0) return null;
    return sorted[((sorted.len - 1) * value) / 100];
}

test "summary separates outcomes and calculates latency" {
    const state: State = .{
        .totals = .{
            .attempts = 4,
            .successful = 2,
            .no_speech = 1,
            .failed = 1,
            .latency_count = 4,
            .latency_sum_ms = 2000,
            .latency_min_ms = 200,
            .latency_max_ms = 800,
        },
        .history = &.{
            .{ .attempt_id = "1", .started_at_unix_ms = 0, .source = "daemon", .provider = "deepgram", .model = "nova-3", .language = "en", .audio_ms = 1, .latency_ms = 200, .outcome = .success, .region = "eu", .transport = "stream", .connection_ms = 40 },
            .{ .attempt_id = "2", .started_at_unix_ms = 0, .source = "daemon", .provider = "deepgram", .model = "nova-3", .language = "en", .audio_ms = 1, .latency_ms = 800, .outcome = .failed },
        },
    };
    const result = try summarize(std.testing.allocator, state, 1000);
    try std.testing.expectEqual(@as(?u64, 500), result.average_latency_ms);
    try std.testing.expectEqual(@as(u64, 2), result.successful);
    try std.testing.expectEqual(@as(usize, 1), result.eu_stream.samples);
    try std.testing.expectEqual(@as(usize, 1), result.eu_stream.attempts);
    try std.testing.expectEqual(@as(?u64, 40), result.eu_stream.average_connection_ms);
}

test "store persists outcomes and rotates detailed history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/metrics-v2.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const store = Store.init(path, 2);
    const metadata: AttemptMetadata = .{
        .source = "test",
        .provider = "deepgram",
        .model = "nova-3",
        .language = "en",
        .audio_ms = 1000,
        .region = "eu",
        .transport = "rest",
    };
    inline for (.{ Outcome.no_speech, Outcome.failed, Outcome.success }, 0..) |outcome, index| {
        const id = try store.begin(std.testing.allocator, std.testing.io, metadata);
        defer std.testing.allocator.free(id);
        try store.complete(std.testing.allocator, std.testing.io, id, .{
            .outcome = outcome,
            .reason = if (outcome == .failed) "transport" else null,
            .latency_ms = 100 + index * 100,
            .stop_to_final_ms = if (outcome == .success) 300 else null,
            .word_count = if (outcome == .success) 4 else null,
            .character_count = if (outcome == .success) 20 else null,
        });
    }
    const result = try store.summary(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 3), result.attempts);
    try std.testing.expectEqual(@as(u64, 1), result.successful);
    try std.testing.expectEqual(@as(u64, 1), result.no_speech);
    try std.testing.expectEqual(@as(u64, 1), result.failed);
    try std.testing.expectEqual(@as(usize, 2), result.history_entries);
    try std.testing.expectEqual(@as(usize, 1), result.content_samples);
    try std.testing.expectApproxEqAbs(@as(f64, 75), result.average_latency_ms_per_word.?, 0.001);
    try std.testing.expectEqual(@as(usize, 1), result.stop_to_final_under_500);
    try std.testing.expectEqual(@as(usize, 1), result.eu_rest.samples);
}

test "store reconciles an interrupted attempt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/metrics-v2.json", .{tmp.sub_path});
    defer std.testing.allocator.free(path);
    const store = Store.init(path, 10);
    const id = try store.begin(std.testing.allocator, std.testing.io, .{
        .source = "test",
        .provider = "deepgram",
        .model = "nova-3",
        .language = "en",
        .audio_ms = 1,
        .region = "global",
        .transport = "rest",
    });
    defer std.testing.allocator.free(id);
    try store.reconcileInterrupted(std.testing.allocator, std.testing.io);
    const result = try store.summary(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 1), result.attempts);
    try std.testing.expectEqual(@as(u64, 1), result.failed);
}

test "v2 store imports v1 history as global REST" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(base);
    const legacy_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/metrics-v1.json", .{base});
    defer std.testing.allocator.free(legacy_path);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/metrics-v2.json", .{base});
    defer std.testing.allocator.free(path);
    const legacy_json =
        \\{"version":1,"totals":{"attempts":1,"successful":1,"latency_count":1,"latency_sum_ms":250,"latency_min_ms":250,"latency_max_ms":250},"active_attempts":[],"history":[{"attempt_id":"old","started_at_unix_ms":0,"source":"daemon","provider":"deepgram","model":"nova-3","language":"en","audio_ms":2000,"latency_ms":250,"outcome":"success","reason":null}]}
    ;
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = legacy_path, .data = legacy_json });

    const store = Store.init(path, 1000);
    const result = try store.summary(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), result.global_rest.samples);
    try std.testing.expectApproxEqAbs(@as(f64, 0.125), result.realtime_factor.?, 0.001);
    try std.testing.expectEqual(@as(usize, 0), result.content_samples);

    try store.reconcileInterrupted(std.testing.allocator, std.testing.io);
    var migrated = try Io.Dir.cwd().openFile(std.testing.io, path, .{});
    migrated.close(std.testing.io);
}
