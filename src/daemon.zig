const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const config = @import("config.zig");
const events = @import("events.zig");
const ipc = @import("ipc.zig");
const metrics = @import("metrics.zig");
const protocol = @import("protocol.zig");
const recorder_mod = @import("recorder.zig");
const deepgram_stream = @import("stt/deepgram_stream.zig");
const groq = @import("llm/groq.zig");
const typer = @import("typer.zig");
const notify = @import("notify.zig");

pub const State = enum { idle, recording, stopping, processing };
const Stage = enum { none, validating, transcribing, cleaning, delivering };

const PipelineJob = struct {
    path: []u8,
    raw: bool,
    session_id: u64,
    stopped_at_awake_ms: i64,
    stream: ?*deepgram_stream.Session,
};

const StateSnapshot = struct {
    state: []const u8,
    stage: ?[]const u8,
    session_id: u64,
    elapsed_ms: i64,
    cleanup: bool,
};

pub fn run(gpa: Allocator, io: Io, cfg: *config.Config, socket_path: []const u8, metrics_path: []const u8) !void {
    const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{socket_path});
    defer gpa.free(lock_path);
    const lock_file = try Io.Dir.createFileAbsolute(io, lock_path, .{ .truncate = false });
    defer lock_file.close(io);
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
        .scratch_dir = std.fs.path.dirname(socket_path) orelse "/tmp",
        .metrics_store = metrics_store,
    };

    var server = try ipc.listen(io, socket_path);
    defer server.deinit(io);
    defer Io.Dir.deleteFileAbsolute(io, socket_path) catch {};
    d.log("listening on {s}", .{socket_path});

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
    rec: recorder_mod.Recorder = .{},
    rec_raw: bool = false,
    rec_started_ms: i64 = 0,
    session_id: u64 = 0,
    stage: Stage = .none,
    event_bus: events.EventBus = .{},
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
        if (self.cfg.notifications) notify.send(self.io, title, body);
    }

    fn handle(self: *Daemon, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        var buf: [ipc.max_command_len]u8 = undefined;
        const cmd = ipc.readCommand(stream, self.io, &buf) catch {
            ipc.writeReply(stream, self.io, "error: malformed command") catch {};
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
            protocol.writeResponse(stream, self.io, request.id, .{
                .protocol_version = protocol.version,
                .platform = "linux",
                .live_levels = true,
                .text_injection = true,
                .clipboard_fallback = true,
                .stats = self.metrics_store != null and self.cfg.metrics.expose_api,
                .streaming_stt = self.cfg.stt.streaming,
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
            var cursor = self.event_bus.cursor(self.io);
            protocol.writeResponse(stream, self.io, request.id, .{
                .state = self.snapshot(),
                .next_seq = cursor,
            }) catch return;
            self.subscriptionLoop(stream, &cursor);
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

    fn subscriptionLoop(self: *Daemon, stream: Io.net.Stream, cursor: *u64) void {
        var frame: [events.max_frame_len]u8 = undefined;
        while (true) {
            if (self.event_bus.read(self.io, cursor, &frame)) |event_frame| {
                ipc.writeFrame(stream, self.io, event_frame) catch return;
            } else {
                std.Io.sleep(self.io, .fromMilliseconds(20), .awake) catch return;
            }
        }
    }

    fn snapshot(self: *Daemon) StateSnapshot {
        self.lock();
        defer self.unlock();
        return .{
            .state = @tagName(self.state),
            .stage = if (self.stage == .none) null else @tagName(self.stage),
            .session_id = self.session_id,
            .elapsed_ms = if (self.state == .recording) @max(0, self.nowMs() - self.rec_started_ms) else 0,
            .cleanup = !self.rec_raw,
        };
    }

    fn publishState(self: *Daemon) void {
        const value = self.snapshot();
        self.event_bus.publish(self.io, "state.changed", value.session_id, value);
    }

    fn setStage(self: *Daemon, stage: Stage) void {
        self.lock();
        self.stage = stage;
        const session = self.session_id;
        self.unlock();
        self.event_bus.publish(self.io, "processing.stage_changed", session, .{
            .stage = if (stage == .none) null else @tagName(stage),
        });
    }

    fn publishError(self: *Daemon, code: []const u8, message: []const u8) void {
        self.lock();
        const session = self.session_id;
        self.unlock();
        self.event_bus.publish(self.io, "operation.error", session, .{ .code = code, .message = message });
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
        self.rec.start(self.gpa, self.io, self.scratch_dir, self.cfg.recording.source) catch |err| {
            self.log("recorder start failed: {s}", .{@errorName(err)});
            self.unlock();
            self.recordPreSttFailure();
            self.publishError("recorder_start_failed", "Could not start recording");
            self.inform("SayAll", "Could not start recording (is pw-record installed?)");
            return "error: could not start recording";
        };
        self.session_id +%= 1;
        const session = self.session_id;
        const meter_path = self.gpa.dupe(u8, self.rec.currentPath().?) catch null;
        self.state = .recording;
        self.stage = .none;
        self.rec_raw = raw;
        self.rec_started_ms = self.nowMs();
        if (self.cfg.stt.streaming) {
            self.stream_session = deepgram_stream.Session.start(
                self.gpa,
                self.io,
                &self.cfg.stt,
                self.rec.currentPath().?,
            ) catch |err| blk: {
                self.log("streaming setup failed: {s}; REST fallback armed", .{@errorName(err)});
                break :blk null;
            };
        }
        self.unlock();
        self.publishState();
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
        self.unlock();
        self.publishState();
        return if (self.stopAndProcess(recording_raw)) "processing" else "error: could not stop recording";
    }

    fn onStop(self: *Daemon) []const u8 {
        self.lock();
        switch (self.state) {
            .recording => {
                self.state = .stopping;
                const stream_session = self.stream_session;
                self.stream_session = null;
                self.unlock();
                self.publishState();
                self.rec.cancel(self.gpa, self.io);
                if (stream_session) |stream| stream.cancel();
                self.lock();
                self.state = .idle;
                self.unlock();
                self.publishState();
                self.event_bus.publish(self.io, "session.completed", self.session_id, .{
                    .ok = false,
                    .reason = "cancelled",
                });
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
            self.unlock();
            if (stream_session) |stream| stream.cancel();
            self.publishState();
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
        self.unlock();
        self.publishState();
        const t = std.Thread.spawn(.{}, pipelineMain, .{ self, job }) catch {
            if (stream_session) |stream| stream.cancel();
            Io.Dir.deleteFileAbsolute(self.io, job.path) catch {};
            self.gpa.free(job.path);
            self.lock();
            self.state = .idle;
            self.unlock();
            self.publishState();
            self.recordPreSttFailure();
            self.publishError("pipeline_start_failed", "Could not start processing");
            return false;
        };
        t.detach();
        return true;
    }
};

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
                d.unlock();
                d.publishState();
                d.event_bus.publish(d.io, "recording.limit_reached", d.session_id, .{});
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
                d.event_bus.publish(d.io, "audio.level", session_id, .{
                    .rms = @min(1.0, levels.rms / 32768.0),
                    .peak = @min(1.0, @as(f64, @floatFromInt(levels.peak)) / 32768.0),
                    .clipping = levels.peak >= 32760,
                    .window_ms = 100,
                });
            } else |_| {}
        }
        std.Io.sleep(d.io, .fromMilliseconds(50), .awake) catch return;
    }
}

fn pipelineMain(d: *Daemon, job: PipelineJob) void {
    const gpa = d.gpa;
    const io = d.io;
    var completed = false;
    var completion_phase: []const u8 = "pre_stt";
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
        d.unlock();
        d.publishState();
        d.event_bus.publish(io, "session.completed", job.session_id, .{
            .ok = completed,
            .phase = completion_phase,
            .reason = completion_reason,
            .stt_attempted = stt_attempted,
            .latency_ms = stt_latency_ms,
        });
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
    completion_phase = "stt";
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
    completion_phase = "post_stt";
    var cleaned: ?[]u8 = null;
    defer if (cleaned) |c| gpa.free(c);

    if (!job.raw and d.cfg.llm.enabled) {
        d.setStage(.cleaning);
        const t_llm = d.nowMs();
        if (groq.cleanup(gpa, io, &d.cfg.llm, transcript, d.cfg.verbose)) |c| {
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
    d.event_bus.publish(io, "output.completed", job.session_id, .{ .method = d.cfg.output.method });
    d.log("total pipeline {d}ms", .{d.nowMs() - t_start});
}
