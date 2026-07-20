const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const SttConfig = struct {
    provider: []const u8 = "deepgram",
    api_key: []const u8 = "",
    model: []const u8 = "nova-3",
    language: []const u8 = "en",
    /// "global", "eu", or "au". Hosts are allow-listed in the provider.
    region: []const u8 = "global",
};

pub const LlmConfig = struct {
    provider: []const u8 = "groq",
    api_key: []const u8 = "",
    model: []const u8 = "llama-3.1-8b-instant",
    base_url: []const u8 = "https://api.groq.com/openai/v1/chat/completions",
    enabled: bool = true,
};

pub const OutputConfig = struct {
    /// "type" (wtype) or "clipboard" (wl-copy).
    method: []const u8 = "type",
    trailing_space: bool = false,
};

pub const RecordingConfig = struct {
    max_seconds: u32 = 300,
    min_ms: u32 = 300,
    /// PipeWire node name/serial to record from (empty = default source).
    source: []const u8 = "",
};

pub const MetricsConfig = struct {
    enabled: bool = true,
    history_max_entries: u32 = 1000,
    expose_api: bool = true,
};

pub const Config = struct {
    stt: SttConfig = .{},
    llm: LlmConfig = .{},
    output: OutputConfig = .{},
    recording: RecordingConfig = .{},
    metrics: MetricsConfig = .{},
    notifications: bool = true,
    verbose: bool = false,
};

pub const ValidationError = error{InvalidConfig};

/// Loads config from ~/.config/sayall/config.json if it exists and applies
/// environment overrides. All strings are owned by `gpa` (use an arena).
pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Config {
    var cfg: Config = .{};
    if (try configPath(gpa, env)) |path| {
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (bytes) |b| {
            cfg = try std.json.parseFromSliceLeaky(Config, gpa, b, .{ .allocate = .alloc_always });
        }
    }

    // Resolve "$ENV_VAR" references for secrets.
    cfg.stt.api_key = resolveEnvRef(env, cfg.stt.api_key);
    cfg.llm.api_key = resolveEnvRef(env, cfg.llm.api_key);

    // Explicit environment variables win over the config file.
    if (env.get("DEEPGRAM_API_KEY")) |k| cfg.stt.api_key = k;
    if (env.get("GROQ_API_KEY")) |k| cfg.llm.api_key = k;
    if (env.get("SAYALL_STT_MODEL")) |m| cfg.stt.model = m;
    if (env.get("SAYALL_LLM_MODEL")) |m| cfg.llm.model = m;
    if (env.get("SAYALL_VERBOSE")) |v| {
        if (v.len > 0 and v[0] != '0') cfg.verbose = true;
    }

    try validate(&cfg);
    return cfg;
}

pub fn validate(cfg: *const Config) ValidationError!void {
    if (!std.mem.eql(u8, cfg.stt.provider, "deepgram")) return invalid("stt.provider must be 'deepgram'");
    if (!std.mem.eql(u8, cfg.llm.provider, "groq")) return invalid("llm.provider must be 'groq'");
    if (!std.mem.eql(u8, cfg.stt.region, "global") and !std.mem.eql(u8, cfg.stt.region, "eu") and
        !std.mem.eql(u8, cfg.stt.region, "au"))
        return invalid("stt.region must be 'global', 'eu', or 'au'");
    if (!std.mem.eql(u8, cfg.llm.base_url, "https://api.groq.com/openai/v1/chat/completions"))
        return invalid("llm.base_url must be the Groq HTTPS endpoint");
    if (!safeToken(cfg.stt.model) or !safeToken(cfg.stt.language) or !safeToken(cfg.llm.model))
        return invalid("model and language values may contain only letters, digits, '.', '-', and '_'");
    if (!safeSecret(cfg.stt.api_key) or !safeSecret(cfg.llm.api_key))
        return invalid("API keys may not contain whitespace or control characters");
    if (!std.mem.eql(u8, cfg.output.method, "type") and !std.mem.eql(u8, cfg.output.method, "clipboard"))
        return invalid("output.method must be 'type' or 'clipboard'");
    if (cfg.recording.max_seconds == 0 or cfg.recording.max_seconds > 3600)
        return invalid("recording.max_seconds must be between 1 and 3600");
    if (cfg.recording.min_ms > cfg.recording.max_seconds * 1000)
        return invalid("recording.min_ms must not exceed max_seconds");
    if (std.mem.findAny(u8, cfg.recording.source, &.{ 0, '\r', '\n' }) != null)
        return invalid("recording.source contains invalid characters");
    if (cfg.metrics.history_max_entries > 100_000)
        return invalid("metrics.history_max_entries must not exceed 100000");
}

fn safeSecret(value: []const u8) bool {
    for (value) |c| if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    return true;
}

fn safeToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    return true;
}

fn invalid(message: []const u8) ValidationError {
    if (!builtin.is_test) std.debug.print("sayall: invalid config: {s}\n", .{message});
    return error.InvalidConfig;
}

fn configPath(gpa: Allocator, env: *const std.process.Environ.Map) !?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |dir| {
        return try std.fmt.allocPrint(gpa, "{s}/sayall/config.json", .{dir});
    }
    if (env.get("HOME")) |home| {
        return try std.fmt.allocPrint(gpa, "{s}/.config/sayall/config.json", .{home});
    }
    return null;
}

fn resolveEnvRef(env: *const std.process.Environ.Map, value: []const u8) []const u8 {
    if (value.len > 1 and value[0] == '$') {
        // Unresolved reference → empty, which downstream treats as "missing".
        return env.get(value[1..]) orelse "";
    }
    return value;
}

/// Path of the unix socket. The scratch WAV file lives next to it.
pub fn socketPath(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_RUNTIME_DIR")) |dir| {
        return std.fmt.allocPrint(gpa, "{s}/sayall.sock", .{dir});
    }
    return std.fmt.allocPrint(gpa, "/tmp/sayall-{d}.sock", .{std.os.linux.getuid()});
}

pub fn metricsPath(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_STATE_HOME")) |dir| {
        if (dir.len == 0 or dir[0] != '/') return error.InvalidStateHome;
        return std.fmt.allocPrint(gpa, "{s}/sayall/metrics-v2.json", .{dir});
    }
    if (env.get("HOME")) |home| {
        if (home.len == 0 or home[0] != '/') return error.InvalidStateHome;
        return std.fmt.allocPrint(gpa, "{s}/.local/state/sayall/metrics-v2.json", .{home});
    }
    return error.StateHomeUnavailable;
}

test "defaults are sensible" {
    const cfg: Config = .{};
    try std.testing.expectEqualStrings("deepgram", cfg.stt.provider);
    try std.testing.expectEqualStrings("nova-3", cfg.stt.model);
    try std.testing.expectEqualStrings("global", cfg.stt.region);
    try std.testing.expect(cfg.llm.enabled);
    try std.testing.expectEqualStrings("type", cfg.output.method);
    try std.testing.expectEqual(@as(u32, 300), cfg.recording.max_seconds);
}

test "validation rejects unknown output methods" {
    var cfg: Config = .{};
    cfg.output.method = "typo";
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}
