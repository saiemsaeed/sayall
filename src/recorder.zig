const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Recording = struct {
    /// Owned by the caller.
    path: []u8,
};

pub const WavInfo = struct {
    seconds: f64,
    data_bytes: usize,
    sample_rate: u32,
    channels: u16,
};

pub const Levels = struct {
    peak: u16,
    rms: f64,
};

pub const Recorder = struct {
    child: ?std.process.Child = null,
    path: ?[]u8 = null,

    /// Spawns pw-record writing 16 kHz mono s16 raw PCM to `dir`.
    /// `source` may be empty (default source), or a PipeWire node name/serial.
    pub fn start(self: *Recorder, gpa: Allocator, io: Io, dir_path: []const u8, source: []const u8) !void {
        std.debug.assert(self.child == null);
        var nonce: u64 = undefined;
        try std.Io.randomSecure(io, std.mem.asBytes(&nonce));
        const path = try std.fmt.allocPrint(gpa, "{s}/sayall-rec-{d}-{x}.pcm", .{
            dir_path, std.os.linux.getpid(), nonce,
        });
        errdefer gpa.free(path);

        var argv_buf: [11][]const u8 = undefined;
        var argv_len: usize = 0;
        const base_args = [_][]const u8{
            "pw-record",
            "--raw",
            "--format",
            "s16",
            "--rate",
            "16000",
            "--channels",
            "1",
        };
        for (base_args) |a| {
            argv_buf[argv_len] = a;
            argv_len += 1;
        }
        if (source.len > 0) {
            argv_buf[argv_len] = "--target";
            argv_buf[argv_len + 1] = source;
            argv_len += 2;
        }
        argv_buf[argv_len] = path;
        argv_len += 1;

        const argv = try gpa.dupe([]const u8, argv_buf[0..argv_len]);
        defer gpa.free(argv);

        const child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });

        self.child = child;
        self.path = path;
    }

    pub fn currentPath(self: *const Recorder) ?[]const u8 {
        return self.path;
    }

    /// Sends SIGINT (so pw-record finalizes the WAV header), waits for exit,
    /// and returns the recording. The caller owns `path` and must delete/free it.
    pub fn stop(self: *Recorder, io: Io) !Recording {
        const child = if (self.child) |*child| child else return error.NotRecording;
        const path = self.path orelse return error.NotRecording;

        if (child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.INT) catch {};
        }
        _ = child.wait(io) catch {
            child.kill(io);
        };

        self.child = null;
        self.path = null;

        return .{ .path = path };
    }

    /// Aborts an in-progress recording, deleting the file.
    pub fn cancel(self: *Recorder, gpa: Allocator, io: Io) void {
        const rec = self.stop(io) catch return;
        Io.Dir.deleteFileAbsolute(io, rec.path) catch {};
        gpa.free(rec.path);
    }
};

/// Validates a WAV file and extracts duration. Handles arbitrary chunk layouts
/// (pw-record may emit more than a bare 44-byte header).
pub fn inspectWav(bytes: []const u8) error{InvalidWav}!WavInfo {
    return (try parseWav(bytes)).info;
}

/// Measures the signal in a 16-bit PCM WAV. A peak of zero is digital silence.
pub fn analyzeLevels(bytes: []const u8) error{InvalidWav}!Levels {
    const data = (try parseWav(bytes)).data;
    return analyzePcmS16(data) catch error.InvalidWav;
}

pub fn analyzePcmS16(data: []const u8) error{InvalidPcm}!Levels {
    if (data.len % 2 != 0) return error.InvalidPcm;
    const sample_count = data.len / 2;
    if (sample_count == 0) return .{ .peak = 0, .rms = 0 };

    var peak: u16 = 0;
    var sum_squares: f64 = 0;
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const sample = std.mem.readInt(i16, data[i * 2 ..][0..2], .little);
        const magnitude: u16 = if (sample == std.math.minInt(i16)) 32768 else @intCast(@abs(sample));
        peak = @max(peak, magnitude);
        const value: f64 = @floatFromInt(sample);
        sum_squares += value * value;
    }
    return .{
        .peak = peak,
        .rms = @sqrt(sum_squares / @as(f64, @floatFromInt(sample_count))),
    };
}

pub fn wavFromPcm(gpa: Allocator, pcm: []const u8) ![]u8 {
    if (pcm.len % 2 != 0 or pcm.len > std.math.maxInt(u32) - 36) return error.InvalidPcm;
    const wav = try gpa.alloc(u8, 44 + pcm.len);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], @intCast(36 + pcm.len), .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 16000, .little);
    std.mem.writeInt(u32, wav[28..32], 32000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], @intCast(pcm.len), .little);
    @memcpy(wav[44..], pcm);
    return wav;
}

const ParsedWav = struct {
    info: WavInfo,
    data: []const u8,
};

fn parseWav(bytes: []const u8) error{InvalidWav}!ParsedWav {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or
        !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;
    const riff_size = std.mem.readInt(u32, bytes[4..8], .little);
    const riff_end = @as(usize, riff_size) + 8;
    if (riff_end < 12 or riff_end > bytes.len) return error.InvalidWav;

    var sample_rate: u32 = 0;
    var num_channels: u16 = 0;
    var found_fmt = false;
    var data: ?[]const u8 = null;
    var offset: usize = 12;
    while (offset + 8 <= riff_end) {
        const chunk_size = @as(usize, std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little));
        const body_start = offset + 8;
        if (chunk_size > riff_end - body_start) return error.InvalidWav;
        const chunk_data = bytes[body_start .. body_start + chunk_size];

        if (std.mem.eql(u8, bytes[offset..][0..4], "fmt ")) {
            if (found_fmt or chunk_data.len < 16) return error.InvalidWav;
            const audio_format = std.mem.readInt(u16, chunk_data[0..2], .little);
            num_channels = std.mem.readInt(u16, chunk_data[2..4], .little);
            sample_rate = std.mem.readInt(u32, chunk_data[4..8], .little);
            const byte_rate = std.mem.readInt(u32, chunk_data[8..12], .little);
            const block_align = std.mem.readInt(u16, chunk_data[12..14], .little);
            const bits_per_sample = std.mem.readInt(u16, chunk_data[14..16], .little);
            if (audio_format != 1 or num_channels == 0 or sample_rate == 0 or bits_per_sample != 16)
                return error.InvalidWav;
            const expected_align = @as(u32, num_channels) * 2;
            if (block_align != expected_align or byte_rate != sample_rate * expected_align)
                return error.InvalidWav;
            found_fmt = true;
        } else if (std.mem.eql(u8, bytes[offset..][0..4], "data")) {
            if (data != null or chunk_data.len % 2 != 0) return error.InvalidWav;
            data = chunk_data;
        }

        const padded_size = chunk_size + (chunk_size & 1);
        if (padded_size > riff_end - body_start) return error.InvalidWav;
        offset = body_start + padded_size;
    }

    if (!found_fmt or data == null) return error.InvalidWav;
    const audio = data.?;
    const bytes_per_sec = @as(f64, @floatFromInt(sample_rate)) * @as(f64, @floatFromInt(num_channels)) * 2.0;
    return .{
        .info = .{
            .seconds = @as(f64, @floatFromInt(audio.len)) / bytes_per_sec,
            .data_bytes = audio.len,
            .sample_rate = sample_rate,
            .channels = num_channels,
        },
        .data = audio,
    };
}

test "inspectWav parses a standard 44-byte header" {
    var wav: [44 + 32000]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 36 + 32000, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, wav[22..24], 1, .little); // mono
    std.mem.writeInt(u32, wav[24..28], 16000, .little);
    std.mem.writeInt(u32, wav[28..32], 32000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 32000, .little);
    @memset(wav[44..], 0);

    const info = try inspectWav(&wav);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), info.seconds, 0.001);
    try std.testing.expectEqual(@as(usize, 32000), info.data_bytes);
    try std.testing.expectEqual(@as(u32, 16000), info.sample_rate);
}

test "inspectWav skips unknown chunks" {
    var wav: [12 + 8 + 10 + 8 + 16 + 8 + 6400]u8 = undefined;
    @memset(&wav, 0);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], @intCast(wav.len - 8), .little);
    @memcpy(wav[8..12], "WAVE");
    var off: usize = 12;
    // JUNK chunk of 10 bytes (odd pad not needed, 10 is even)
    @memcpy(wav[off..][0..4], "JUNK");
    std.mem.writeInt(u32, wav[off + 4 ..][0..4], 10, .little);
    off += 8 + 10;
    // fmt chunk
    @memcpy(wav[off..][0..4], "fmt ");
    std.mem.writeInt(u32, wav[off + 4 ..][0..4], 16, .little);
    std.mem.writeInt(u16, wav[off + 8 ..][0..2], 1, .little);
    std.mem.writeInt(u16, wav[off + 10 ..][0..2], 1, .little);
    std.mem.writeInt(u32, wav[off + 12 ..][0..4], 16000, .little);
    std.mem.writeInt(u32, wav[off + 16 ..][0..4], 32000, .little);
    std.mem.writeInt(u16, wav[off + 20 ..][0..2], 2, .little);
    std.mem.writeInt(u16, wav[off + 22 ..][0..2], 16, .little);
    off += 8 + 16;
    // data chunk: 6400 bytes @32kB/s = 0.2s
    @memcpy(wav[off..][0..4], "data");
    std.mem.writeInt(u32, wav[off + 4 ..][0..4], 6400, .little);

    const info = try inspectWav(&wav);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), info.seconds, 0.001);
}

test "inspectWav rejects garbage" {
    try std.testing.expectError(error.InvalidWav, inspectWav("not a wav"));
    try std.testing.expectError(error.InvalidWav, inspectWav("RIFF\x00\x00\x00\x00NOPE"));
}

test "inspectWav rejects a truncated data chunk" {
    var wav: [46]u8 = undefined;
    @memset(&wav, 0);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 42, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 16000, .little);
    std.mem.writeInt(u32, wav[28..32], 32000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 100, .little);
    try std.testing.expectError(error.InvalidWav, inspectWav(&wav));
}

test "analyzeLevels identifies digital silence" {
    var wav: [48]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 40, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 16000, .little);
    std.mem.writeInt(u32, wav[28..32], 32000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 4, .little);
    @memset(wav[44..48], 0);
    const levels = try analyzeLevels(&wav);
    try std.testing.expectEqual(@as(u16, 0), levels.peak);
    try std.testing.expectEqual(@as(f64, 0), levels.rms);
}

test "raw PCM can be analyzed and wrapped as WAV" {
    const pcm = [_]u8{ 0xe8, 0x03, 0x18, 0xfc }; // +1000, -1000
    const levels = try analyzePcmS16(&pcm);
    try std.testing.expectEqual(@as(u16, 1000), levels.peak);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), levels.rms, 0.01);
    const wav = try wavFromPcm(std.testing.allocator, &pcm);
    defer std.testing.allocator.free(wav);
    const info = try inspectWav(wav);
    try std.testing.expectEqual(@as(usize, pcm.len), info.data_bytes);
}
