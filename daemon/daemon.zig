const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const events = @import("events.zig");
const ipc = @import("ipc.zig");
const metrics = @import("metrics.zig");
const paths = @import("paths.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const recorder_mod = @import("recorder.zig");
const deepgram_stream = @import("stt/deepgram_stream.zig");
const groq = @import("llm/groq.zig");
const typer = @import("typer.zig");
const notify = @import("notify.zig");

pub const State = protocol.State;
const Stage = enum { none, validating, transcribing, cleaning, delivering };

const PipelineJob = struct {
    path: []u8,
    raw: bool,
    session_id: u64,
    stopped_at_awake_ms: i64,
    stream: ?*deepgram_stream.Session,
};

pub fn run(gpa: Allocator, io: Io, cfg: *config.Config, runtime: paths.Runtime, metrics_path: []const u8) !void {
    try runtime.endpoint.validateParent(io);
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{runtime.endpoint.path});
    defer gpa.free(lock_path);
    const lock_file = try Io.Dir.createFileAbsolute(io, lock_path, .{
        .truncate = false,
        .permissions = @enumFromInt(0o600),
    });
    defer lock_file.close(io);
    try lock_file.setPermissions(io, @enumFromInt(0o600));
    if (!try lock_file.tryLock(io, .exclusive)) return error.AlreadyRunning;
    defer lock_file.unlock(io);

    var metrics_store: ?metrics.Store = if (cfg.metrics.enabled)
        metrics.Store.init(metrics_path, cfg.metrics.history_max_entries)
    else
        null;
    if (metrics_store) |store| {
        store.reconcileInterrupted(gpa, io) catch |err| {
            std.debug.print("sayall: metrics disabled: {s}\n", .{@errorName(err)});
            metrics_store = null;
        };
    }

    var d: Daemon = .{
        .gpa = gpa,
        .io = io,
        .cfg = cfg,
        .scratch_dir = runtime.scratch_dir,
        .metrics_store = metrics_store,
        .event_bus = events.EventBus.init(gpa),
    };
    defer d.event_bus.deinit();

    var server = try ipc.listen(io, runtime.endpoint);
    defer server.deinit(io);
    defer Io.Dir.deleteFileAbsolute(io, runtime.endpoint.path) catch {};
    d.log("listening on {s}", .{runtime.endpoint.path});

    const watchdog_thread = try std.Thread.spawn(.{}, watchdogLoop, .{&d});
    watchdog_thread.detach();

    while (true) {
        const stream = server.accept(io) catch |err| {
            d.log("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        const client_thread = std.Thread.spawn(.{}, handleConnection, .{ &d, stream }) catch {
            stream.close(io);
            continue;
        };
        client_thread.detach();
    }
}

fn handleConnection(d: *Daemon, stream: Io.net.Stream) void {
    d.handle(stream);
}

const Daemon = struct {
    gpa: Allocator,
    io: Io,
    cfg: *config.Config,
    scratch_dir: []const u8,
    metrics_store: ?metrics.Store,

    mutex: Io.Mutex = .init,
    state: State = .idle,
    rec: platform.Recorder = .{},
    rec_raw: bool = false,
    rec_started_ms: i64 = 0,
    session_id: u64 = 0,
    stage: Stage = .none,
    event_bus: events.EventBus,
    stream_session: ?*deepgram_stream.Session = null,

    fn lock(self: *Daemon) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Daemon) void {
        self.mutex.unlock(self.io);
    }

    fn nowMs(self: *Daemon) i64 {
        return std.Io.Clock.now(.awake, self.io).toMilliseconds();
    }

    fn log(self: *Daemon, comptime fmt: []const u8, args: anytype) void {
        if (!self.cfg.verbose) return;
        std.debug.print("sayall: " ++ fmt ++ "\n", args);
    }

    fn inform(self: *Daemon, title: []const u8, body: []const u8) void {
        self.log("{s}: {s}", .{ title, body });
        if (self.cfg.notifications) notify.send(self.io, title, body) catch |err| {
            self.log("notification unavailable: {s}", .{@errorName(err)});
        };
    }

    fn handle(self: *Daemon, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        var buf: [ipc.max_command_len]u8 = undefined;
        const cmd = ipc.readCommand(stream, self.io, &buf) catch |err| {
            if (err == error.CommandTooLong) {
                protocol.writeError(stream, self.io, 0, "frame_too_large", "Frame exceeds 65536 bytes including newline") catch {};
            } else {
                ipc.writeReply(stream, self.io, "error: malformed command") catch {};
            }
            return;
        } orelse return;
        if (cmd.len > 0 and cmd[0] == '{') {
            self.handleJson(stream, cmd);
            return;
        }
        ipc.writeReply(stream, self.io, self.dispatch(cmd)) catch {};
    }

    fn handleJson(self: *Daemon, stream: Io.net.Stream, frame: []const u8) void {
        const parsed = protocol.parseRequest(self.gpa, frame) catch |err| {
            protocol.writeError(stream, self.io, 0, "invalid_request", @errorName(err)) catch {};
            return;
        };
        defer parsed.deinit();
        const request = parsed.value;

        if (std.mem.eql(u8, request.method, "get_capabilities")) {
            const capabilities = platform.capabilities;
            protocol.writeResponse(stream, self.io, request.id, protocol.Capabilities{
                .platform = capabilities.name,
                .live_levels = capabilities.live_levels.isImplemented(),
                .text_injection = capabilities.text_injection.isImplemented(),
                .clipboard_fallback = capabilities.clipboard_fallback.isImplemented(),
                .stats = capabilities.stats.isImplemented() and self.metrics_store != null and self.cfg.metrics.expose_api,
                .streaming_stt = capabilities.streaming_stt.isImplemented() and self.cfg.stt.streaming,
            }) catch {};
            return;
        }
        if (std.mem.eql(u8, request.method, "get_state")) {
            protocol.writeResponse(stream, self.io, request.id, self.snapshot()) catch {};
            return;
        }
        if (std.mem.eql(u8, request.method, "get_stats")) {
            if (!self.cfg.metrics.expose_api or self.metrics_store == null) {
                protocol.writeError(stream, self.io, request.id, "method_disabled", "Statistics API is disabled") catch {};
                return;
            }
            const summary = self.metrics_store.?.summary(self.gpa, self.io) catch |err| {
                protocol.writeError(stream, self.io, request.id, "metrics_error", @errorName(err)) catch {};
                return;
            };
            protocol.writeResponse(stream, self.io, request.id, summary) catch {};
            return;
        }
        if (std.mem.eql(u8, request.method, "subscribe")) {
            const barrier = self.subscriptionBarrier();
            var cursor = barrier.next_seq;
            protocol.writeResponse(stream, self.io, request.id, barrier) catch return;
            self.subscriptionLoop(stream, request.id, &cursor);
            return;
        }

        const reply = if (std.mem.eql(u8, request.method, "start_recording"))
            self.onStart(!request.params.cleanup)
        else if (std.mem.eql(u8, request.method, "finish_recording"))
            self.onFinish()
        else if (std.mem.eql(u8, request.method, "cancel_recording"))
            self.onStop()
        else if (std.mem.eql(u8, request.method, "toggle"))
            self.onToggle(!request.params.cleanup)
        else {
            protocol.writeError(stream, self.io, request.id, "unknown_method", "Unknown method") catch {};
            return;
        };

        if (std.mem.startsWith(u8, reply, "error") or std.mem.startsWith(u8, reply, "busy")) {
            protocol.writeError(stream, self.io, request.id, "invalid_state", reply) catch {};
        } else {
            protocol.writeResponse(stream, self.io, request.id, self.snapshot()) catch {};
        }
    }

    fn subscriptionLoop(self: *Daemon, stream: Io.net.Stream, request_id: u64, cursor: *u64) void {
        var frame: [events.max_frame_len]u8 = undefined;
        while (true) {
            switch (self.event_bus.read(self.io, cursor, &frame)) {
                .event => |event_frame| ipc.writeFrame(stream, self.io, event_frame) catch return,
                .empty => std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return,
                .gap => {
                    protocol.writeError(
                        stream,
                        self.io,
                        request_id,
                        "event_gap",
                        "Event history overflowed; resubscribe for a fresh snapshot",
                    ) catch {};
                    return;
                },
            }
        }
    }

    fn snapshot(self: *Daemon) protocol.StateSnapshot {
        self.lock();
        defer self.unlock();
        return self.snapshotLocked();
    }

    fn snapshotLocked(self: *Daemon) protocol.StateSnapshot {
        return .{
            .state = self.state,
            .stage = protocolStage(self.stage),
            .session_id = self.session_id,
            .elapsed_ms = if (self.state == .recording) @max(0, self.nowMs() - self.rec_started_ms) else 0,
            .cleanup = !self.rec_raw,
            .show_timer = self.cfg.hud.show_timer,
        };
    }

    /// State and cursor are captured under the same lock used to publish state
    /// transitions, making this a coherent subscription barrier.
    fn subscriptionBarrier(self: *Daemon) protocol.SubscribeResult {
        self.lock();
        defer self.unlock();
        return .{
            .state = self.snapshotLocked(),
            .next_seq = self.event_bus.cursor(self.io),
        };
    }

    /// Caller holds `mutex`, so the mutation and its event are indivisible from
    /// a subscription barrier's point of view.
    fn publishStateLocked(self: *Daemon) void {
        const value = self.snapshotLocked();
        self.event_bus.publish(self.io, value.session_id, .{ .state_changed = value }) catch {};
    }

    fn setStage(self: *Daemon, stage: Stage) void {
        self.lock();
        self.stage = stage;
        const session = self.session_id;
        self.event_bus.publish(self.io, session, .{ .processing_stage_changed = .{
            .stage = protocolStage(stage),
        } }) catch {};
        self.unlock();
    }

    fn publishError(self: *Daemon, code: []const u8, message: []const u8) void {
        self.lock();
        const session = self.session_id;
        self.unlock();
        self.event_bus.publish(self.io, session, .{ .operation_error = .{ .code = code, .message = message } }) catch {};
    }

    fn recordPreSttFailure(self: *Daemon) void {
        if (self.metrics_store) |store| store.recordPreSttFailure(self.gpa, self.io) catch {};
    }

    fn dispatch(self: *Daemon, cmd: []const u8) []const u8 {
        if (std.mem.eql(u8, cmd, "toggle")) return self.onToggle(false);
        if (std.mem.eql(u8, cmd, "toggle raw")) return self.onToggle(true);
        if (std.mem.eql(u8, cmd, "stop")) return self.onStop();
        if (std.mem.eql(u8, cmd, "status")) return self.onStatus();
        return "error: unknown command";
    }

    fn onToggle(self: *Daemon, raw: bool) []const u8 {
        self.lock();
        const state = self.state;
        self.unlock();
        return switch (state) {
            .idle => self.onStart(raw),
            .recording => self.onFinish(),
            .stopping, .processing => "busy: still processing previous clip",
        };
    }

    fn onStart(self: *Daemon, raw: bool) []const u8 {
        self.lock();
        if (self.state != .idle) {
            self.unlock();
            return "busy: daemon is not idle";
        }
        const recording_path = self.rec.start(self.gpa, self.io, self.scratch_dir, self.cfg.recording.source) catch |err| {
            self.log("recorder start failed: {s}", .{@errorName(err)});
            self.unlock();
            self.recordPreSttFailure();
            self.publishError("recorder_start_failed", "Could not start recording");
            self.inform("SayAll", "Could not start recording (is pw-record installed?)");
            return "error: could not start recording";
        };
        self.session_id +%= 1;
        const session = self.session_id;
        const meter_path = self.gpa.dupe(u8, recording_path) catch null;
        self.state = .recording;
        self.stage = .none;
        self.rec_raw = raw;
        self.rec_started_ms = self.nowMs();
        if (self.cfg.stt.streaming) {
            self.stream_session = deepgram_stream.Session.start(
                self.gpa,
                self.io,
                &self.cfg.stt,
                recording_path,
            ) catch |err| blk: {
                self.log("streaming setup failed: {s}; REST fallback armed", .{@errorName(err)});
                break :blk null;
            };
        }
        self.publishStateLocked();
        self.unlock();
        if (meter_path) |path| {
            const meter_thread = std.Thread.spawn(.{}, meterLoop, .{ self, session, path }) catch {
                self.gpa.free(path);
                return "recording";
            };
            meter_thread.detach();
        }
        self.log("recording started ({s} mode)", .{if (raw) "raw" else "clean"});
        return "recording";
    }

    fn onFinish(self: *Daemon) []const u8 {
        self.lock();
        if (self.state != .recording) {
            self.unlock();
            return "busy: no active recording";
        }
        self.state = .stopping;
        const recording_raw = self.rec_raw;
        self.publishStateLocked();
        self.unlock();
        return if (self.stopAndProcess(recording_raw)) "processing" else "error: could not stop recording";
    }

    fn onStop(self: *Daemon) []const u8 {
        self.lock();
        switch (self.state) {
            .recording => {
                self.state = .stopping;
                const session = self.session_id;
                const stream_session = self.stream_session;
                self.stream_session = null;
                self.publishStateLocked();
                self.unlock();
                self.rec.cancel(self.gpa, self.io) catch |err| {
                    self.log("recorder cancel failed: {s}", .{@errorName(err)});
                };
                if (stream_session) |stream| stream.cancel();
                self.lock();
                self.state = .idle;
                self.publishStateLocked();
                self.unlock();
                self.event_bus.publish(self.io, session, .{ .session_completed = .{
                    .ok = false,
                    .phase = .pre_stt,
                    .reason = "cancelled",
                    .stt_attempted = false,
                    .latency_ms = 0,
                } }) catch {};
                self.inform("SayAll", "Recording cancelled");
                return "stopped";
            },
            .stopping, .processing => {
                self.unlock();
                return "busy: processing cannot be cancelled";
            },
            .idle => {
                self.unlock();
                return "idle";
            },
        }
    }

    fn onStatus(self: *Daemon) []const u8 {
        self.lock();
        defer self.unlock();
        return switch (self.state) {
            .idle => "idle",
            .stopping => "stopping",
            .processing => "processing",
            .recording => "recording",
        };
    }

    /// Stops without holding the state mutex, then starts the processing worker.
    fn stopAndProcess(self: *Daemon, raw: bool) bool {
        const rec = self.rec.stop(self.io) catch |err| {
            self.log("recorder stop failed: {s}", .{@errorName(err)});
            self.lock();
            const stream_session = self.stream_session;
            self.stream_session = null;
            self.state = .idle;
            self.publishStateLocked();
            self.unlock();
            if (stream_session) |stream| stream.cancel();
            self.recordPreSttFailure();
            self.publishError("recorder_stop_failed", "Recording failed to stop");
            self.inform("SayAll", "Recording failed");
            return false;
        };
        self.lock();
        const session = self.session_id;
        const stream_session = self.stream_session;
        self.stream_session = null;
        self.unlock();
        if (stream_session) |stream| stream.requestFinish();
        const job: PipelineJob = .{
            .path = rec.path,
            .raw = raw,
            .session_id = session,
            .stopped_at_awake_ms = self.nowMs(),
            .stream = stream_session,
        };
        self.lock();
        self.state = .processing;
        self.stage = .validating;
        self.publishStateLocked();
        self.unlock();
        const t = std.Thread.spawn(.{}, pipelineMain, .{ self, job }) catch {
            if (stream_session) |stream| stream.cancel();
            Io.Dir.deleteFileAbsolute(self.io, job.path) catch {};
            self.gpa.free(job.path);
            self.lock();
            self.state = .idle;
            self.stage = .none;
            self.publishStateLocked();
            self.unlock();
            self.recordPreSttFailure();
            self.publishError("pipeline_start_failed", "Could not start processing");
            return false;
        };
        t.detach();
        return true;
    }
};

fn protocolStage(stage: Stage) ?protocol.ProcessingStage {
    return switch (stage) {
        .none => null,
        .validating => .validating,
        .transcribing => .transcribing,
        .cleaning => .cleaning,
        .delivering => .delivering,
    };
}

fn watchdogLoop(d: *Daemon) void {
    while (true) {
        std.Io.sleep(d.io, .fromMilliseconds(250), .awake) catch return;
        d.lock();
        if (d.state == .recording) {
            const elapsed_ms = d.nowMs() - d.rec_started_ms;
            const max_ms = @as(i64, d.cfg.recording.max_seconds) * 1000;
            if (elapsed_ms >= max_ms) {
                d.state = .stopping;
                const raw = d.rec_raw;
                const session = d.session_id;
                d.publishStateLocked();
                d.unlock();
                d.event_bus.publish(d.io, session, .{ .recording_limit_reached = .{} }) catch {};
                d.inform("SayAll", "Maximum recording length reached");
                _ = d.stopAndProcess(raw);
                continue;
            }
        }
        d.unlock();
    }
}

fn meterLoop(d: *Daemon, session_id: u64, path: []u8) void {
    defer d.gpa.free(path);
    var maybe_file: ?Io.File = null;
    var attempt: usize = 0;
    while (attempt < 20 and maybe_file == null) : (attempt += 1) {
        maybe_file = Io.Dir.openFileAbsolute(d.io, path, .{}) catch null;
        if (maybe_file == null) std.Io.sleep(d.io, .fromMilliseconds(25), .awake) catch return;
    }
    const file = maybe_file orelse return;
    defer file.close(d.io);

    var offset: u64 = 0;
    while (true) {
        d.lock();
        const active = d.session_id == session_id and (d.state == .recording or d.state == .stopping);
        d.unlock();
        if (!active) return;

        var samples: [3200]u8 = undefined; // 100 ms at 16 kHz mono s16.
        const buffers = [_][]u8{samples[0..]};
        const read_len = file.readPositional(d.io, &buffers, offset) catch 0;
        if (read_len > 0) {
            const aligned_len = read_len - (read_len % 2);
            // Leave a trailing byte for the next read so S16 framing is stable
            // across concurrent short writes.
            offset += aligned_len;
            if (recorder_mod.analyzePcmS16(samples[0..aligned_len])) |levels| {
                d.event_bus.publish(d.io, session_id, .{ .audio_level = .{
                    .rms = @min(1.0, levels.rms / 32768.0),
                    .peak = @min(1.0, @as(f64, @floatFromInt(levels.peak)) / 32768.0),
                    .clipping = levels.peak >= 32760,
                    .window_ms = 100,
                } }) catch {};
            } else |_| {}
        }
        std.Io.sleep(d.io, .fromMilliseconds(50), .awake) catch return;
    }
}

fn pipelineMain(d: *Daemon, job: PipelineJob) void {
    const gpa = d.gpa;
    const io = d.io;
    var completed = false;
    var completion_phase: protocol.SessionPhase = .pre_stt;
    var completion_reason: ?[]const u8 = null;
    var stt_attempted = false;
    var stt_latency_ms: u64 = 0;
    var stream_session = job.stream;
    defer if (stream_session) |stream| stream.cancel();
    defer {
        Io.Dir.deleteFileAbsolute(io, job.path) catch {};
        gpa.free(job.path);
        d.lock();
        d.state = .idle;
        d.stage = .none;
        d.publishStateLocked();
        d.unlock();
        d.event_bus.publish(io, job.session_id, .{ .session_completed = .{
            .ok = completed,
            .phase = completion_phase,
            .reason = completion_reason,
            .stt_attempted = stt_attempted,
            .latency_ms = stt_latency_ms,
        } }) catch {};
    }

    const t_start = d.nowMs();

    // The 250 ms watchdog interval and recorder shutdown can extend a
    // limit-triggered capture slightly beyond the configured duration.
    const max_pcm_bytes = (@as(usize, d.cfg.recording.max_seconds) + 2) * 32000;
    const pcm = Io.Dir.cwd().readFileAlloc(io, job.path, gpa, .limited(max_pcm_bytes)) catch |err| {
        completion_reason = "recording_read_failed";
        d.recordPreSttFailure();
        d.publishError("recording_read_failed", "Could not read recording");
        d.inform("SayAll", "Could not read recording");
        d.log("readFileAlloc failed: {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(pcm);

    const levels = recorder_mod.analyzePcmS16(pcm) catch {
        completion_reason = "invalid_recording";
        d.recordPreSttFailure();
        d.publishError("invalid_recording", "Invalid PCM recording");
        d.inform("SayAll", "Invalid recording data");
        return;
    };
    const seconds = @as(f64, @floatFromInt(pcm.len)) / 32000.0;
    d.log("recorded {d:.2}s; peak={d}, rms={d:.1}", .{ seconds, levels.peak, levels.rms });
    if (seconds * 1000.0 < @as(f64, @floatFromInt(d.cfg.recording.min_ms))) {
        completion_reason = "clip_too_short";
        d.recordPreSttFailure();
        d.log("clip shorter than {d}ms — ignored", .{d.cfg.recording.min_ms});
        return;
    }
    if (levels.peak == 0) {
        completion_reason = "no_microphone_signal";
        d.recordPreSttFailure();
        d.publishError("no_microphone_signal", "No microphone signal detected");
        d.inform("SayAll", "No microphone signal; check the selected input, gain, and phantom power");
        return;
    }

    const wav = recorder_mod.wavFromPcm(gpa, pcm) catch {
        completion_reason = "wav_generation_failed";
        d.recordPreSttFailure();
        d.publishError("wav_generation_failed", "Could not prepare recording");
        return;
    };
    defer gpa.free(wav);

    d.setStage(.transcribing);
    completion_phase = .stt;
    stt_attempted = true;
    var maybe_transcript: ?[]u8 = null;
    if (stream_session) |stream| {
        const stream_result = stream.finish();
        stream_session = null;
        switch (stream_result) {
            .success => |success| {
                maybe_transcript = success.transcript;
                stt_latency_ms = success.stop_to_final_ms;
                metrics.recordCompletedTranscript(
                    gpa,
                    io,
                    d.metrics_store,
                    &d.cfg.stt,
                    "daemon",
                    @intFromFloat(seconds * 1000.0),
                    "stream",
                    success.transcript,
                    success.latency_ms,
                    success.stop_to_final_ms,
                    success.connect_ms,
                );
                d.log("stream finalized in {d}ms; connected in {d}ms ({d} bytes)", .{
                    success.stop_to_final_ms,
                    success.connect_ms,
                    success.transcript.len,
                });
            },
            .failed => |failure| {
                metrics.recordFailedStream(
                    gpa,
                    io,
                    d.metrics_store,
                    &d.cfg.stt,
                    "daemon",
                    @intFromFloat(seconds * 1000.0),
                    failure.reason,
                    failure.latency_ms,
                );
                d.log("stream failed after {d}ms ({s}); using REST fallback", .{ failure.latency_ms, failure.reason });
            },
        }
    }

    if (maybe_transcript == null) {
        const tracked = metrics.transcribeTracked(
            gpa,
            io,
            d.metrics_store,
            &d.cfg.stt,
            wav,
            d.cfg.verbose,
            "daemon",
            @intFromFloat(seconds * 1000.0),
            job.stopped_at_awake_ms,
        ) catch |err| {
            completion_reason = "transcription_failed";
            d.publishError("transcription_failed", "Transcription failed");
            d.inform("SayAll", "Transcription failed");
            d.log("stt failed: {s}", .{@errorName(err)});
            return;
        };
        stt_latency_ms = tracked.latency_ms;
        maybe_transcript = tracked.transcript;
        d.log("REST STT in {d}ms ({d} bytes)", .{ tracked.latency_ms, tracked.transcript.len });
    }
    const transcript = maybe_transcript.?;
    defer gpa.free(transcript);

    if (transcript.len == 0) {
        completion_reason = "no_speech";
        d.publishError("no_speech", "No speech detected");
        d.inform("SayAll", "No speech detected");
        return;
    }

    var final: []const u8 = transcript;
    completion_phase = .post_stt;
    var cleaned: ?[]u8 = null;
    defer if (cleaned) |c| gpa.free(c);

    if (!job.raw and d.cfg.llm.enabled) {
        d.setStage(.cleaning);
        const t_llm = d.nowMs();
        if (groq.cleanup(gpa, io, &d.cfg.llm, d.cfg.stt.keyterms, transcript, d.cfg.verbose)) |c| {
            cleaned = c;
            final = c;
            d.log("llm cleanup in {d}ms ({d} bytes)", .{ d.nowMs() - t_llm, c.len });
        } else |err| {
            d.log("llm cleanup failed: {s} — using raw transcript", .{@errorName(err)});
        }
    }

    var typed = final;
    var with_space: ?[]u8 = null;
    defer if (with_space) |s| gpa.free(s);
    if (d.cfg.output.trailing_space) {
        with_space = std.fmt.allocPrint(gpa, "{s} ", .{final}) catch null;
        if (with_space) |s| typed = s;
    }

    d.setStage(.delivering);
    typer.deliver(io, d.cfg.output.method, typed) catch |err| {
        completion_reason = "output_failed";
        d.publishError("output_failed", "Could not output text");
        d.inform("SayAll", "Could not output text");
        d.log("output failed: {s}", .{@errorName(err)});
        return;
    };
    completed = true;
    completion_reason = null;
    d.event_bus.publish(io, job.session_id, .{ .output_completed = .{ .method = d.cfg.output.method } }) catch {};
    d.log("total pipeline {d}ms", .{d.nowMs() - t_start});
}

test "subscription barrier snapshots state before the next event" {
    var cfg: config.Config = .{};
    var d: Daemon = .{
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .cfg = &cfg,
        .scratch_dir = "/tmp",
        .metrics_store = null,
        .event_bus = events.EventBus.init(std.testing.allocator),
    };
    defer d.event_bus.deinit();

    d.lock();
    d.state = .recording;
    d.session_id = 11;
    d.rec_started_ms = d.nowMs();
    d.publishStateLocked();
    d.unlock();

    const barrier = d.subscriptionBarrier();
    try std.testing.expectEqual(protocol.State.recording, barrier.state.state);
    try std.testing.expectEqual(@as(u64, 11), barrier.state.session_id);
    try std.testing.expectEqual(@as(u64, 2), barrier.next_seq);

    d.lock();
    d.state = .processing;
    d.stage = .validating;
    d.publishStateLocked();
    d.unlock();

    var cursor = barrier.next_seq;
    var storage: [protocol.max_frame_len]u8 = undefined;
    const frame = switch (d.event_bus.read(std.testing.io, &cursor, &storage)) {
        .event => |frame| frame,
        else => return error.MissingPostBarrierEvent,
    };
    const parsed = try std.json.parseFromSlice(
        protocol.EventFrame(protocol.StateChanged),
        std.testing.allocator,
        frame,
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(barrier.next_seq, parsed.value.seq);
    try std.testing.expectEqual(protocol.State.processing, parsed.value.data.state);
    try std.testing.expectEqual(protocol.ProcessingStage.validating, parsed.value.data.stage.?);
}
