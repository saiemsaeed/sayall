const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const keywords = @import("keywords.zig");
const paths = @import("paths.zig");

pub const SttConfig = struct {
    provider: []const u8 = "deepgram",
    api_key: []const u8 = "",
    model: []const u8 = "nova-3",
    language: []const u8 = "en",
    /// Global Deepgram recognition hints, also preserved by LLM cleanup.
    keyterms: []const []const u8 = &.{},
    /// "global", "eu", or "au". Hosts are allow-listed in the provider.
    region: []const u8 = "global",
    streaming: bool = true,
    stream_finalize_timeout_ms: u32 = 2000,
};

pub const LlmConfig = struct {
    provider: []const u8 = "groq",
    api_key: []const u8 = "",
    model: []const u8 = "llama-3.1-8b-instant",
    base_url: []const u8 = "https://api.groq.com/openai/v1/chat/completions",
    enabled: bool = true,
};

pub const OutputConfig = struct {
    /// "type" (wtype), "clipboard" (wl-copy), or "paste" (wl-copy + Ctrl+V).
    method: []const u8 = "type",
    trailing_space: bool = true,
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

pub const HudConfig = struct {
    show_timer: bool = true,
};

pub const Config = struct {
    stt: SttConfig = .{},
    llm: LlmConfig = .{},
    output: OutputConfig = .{},
    recording: RecordingConfig = .{},
    metrics: MetricsConfig = .{},
    hud: HudConfig = .{},
    notifications: bool = true,
    verbose: bool = false,
};

pub const ValidationError = error{InvalidConfig};

/// Loads config from ~/.config/sayall/config.json if it exists and applies
/// environment overrides. All strings are owned by `gpa` (use an arena).
pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Config {
    var cfg: Config = .{};
    if (try paths.Config.file(gpa, env)) |path| {
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

    if (try paths.Config.keywords(gpa, env)) |keywords_path| {
        const store = keywords.Store.init(keywords_path);
        if (try store.load(gpa, io)) |stored| {
            cfg.stt.keyterms = stored;
        } else {
            // Validate the complete legacy configuration before migration has
            // any filesystem side effects.
            cfg.stt.keyterms = try keywords.normalizeLegacy(gpa, cfg.stt.keyterms);
            try validate(&cfg);
            cfg.stt.keyterms = try store.loadOrMigrate(gpa, io, cfg.stt.keyterms);
        }
    } else {
        cfg.stt.keyterms = try keywords.normalizeLegacy(gpa, cfg.stt.keyterms);
    }
    try validate(&cfg);
    return cfg;
}

const LegacySttConfig = struct {
    keyterms: []const []const u8 = &.{},
};

const LegacyConfig = struct {
    stt: LegacySttConfig = .{},
};

/// Reads only legacy stt.keyterms for the keyword CLI. This intentionally
/// avoids loading, resolving, or printing API credentials and unrelated config.
pub fn loadLegacyKeyterms(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) ![]const []const u8 {
    const config_path = try paths.Config.file(gpa, env) orelse return &.{};
    const bytes = Io.Dir.cwd().readFileAlloc(io, config_path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    const legacy = try std.json.parseFromSliceLeaky(LegacyConfig, gpa, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    return keywords.normalizeLegacy(gpa, legacy.stt.keyterms);
}

pub fn validate(cfg: *const Config) ValidationError!void {
    if (!std.mem.eql(u8, cfg.stt.provider, "deepgram")) return invalid("stt.provider must be 'deepgram'");
    if (!std.mem.eql(u8, cfg.llm.provider, "groq")) return invalid("llm.provider must be 'groq'");
    if (!std.mem.eql(u8, cfg.stt.region, "global") and !std.mem.eql(u8, cfg.stt.region, "eu") and
        !std.mem.eql(u8, cfg.stt.region, "au"))
        return invalid("stt.region must be 'global', 'eu', or 'au'");
    if (cfg.stt.stream_finalize_timeout_ms < 250 or cfg.stt.stream_finalize_timeout_ms > 10_000)
        return invalid("stt.stream_finalize_timeout_ms must be between 250 and 10000");
    if (!std.mem.eql(u8, cfg.llm.base_url, "https://api.groq.com/openai/v1/chat/completions"))
        return invalid("llm.base_url must be the Groq HTTPS endpoint");
    if (!safeToken(cfg.stt.model) or !safeToken(cfg.stt.language) or !safeToken(cfg.llm.model))
        return invalid("model and language values may contain only letters, digits, '.', '-', and '_'");
    if (!safeSecret(cfg.stt.api_key) or !safeSecret(cfg.llm.api_key))
        return invalid("API keys may not contain whitespace or control characters");
    if (cfg.stt.keyterms.len > 0 and !std.mem.eql(u8, cfg.stt.model, "nova-3") and
        !std.mem.startsWith(u8, cfg.stt.model, "nova-3-"))
        return invalid("stt.keyterms requires a Nova-3 model");
    keywords.validate(cfg.stt.keyterms) catch
        return invalid("stt.keyterms must be unique UTF-8 entries of 1-256 bytes, without controls (100 entries and 4096 bytes total maximum)");
    if (!std.mem.eql(u8, cfg.output.method, "type") and
        !std.mem.eql(u8, cfg.output.method, "clipboard") and
        !std.mem.eql(u8, cfg.output.method, "paste"))
        return invalid("output.method must be 'type', 'clipboard', or 'paste'");
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

fn resolveEnvRef(env: *const std.process.Environ.Map, value: []const u8) []const u8 {
    if (value.len > 1 and value[0] == '$') {
        // Unresolved reference → empty, which downstream treats as "missing".
        return env.get(value[1..]) orelse "";
    }
    return value;
}

test "defaults are sensible" {
    const cfg: Config = .{};
    try std.testing.expectEqualStrings("deepgram", cfg.stt.provider);
    try std.testing.expectEqualStrings("nova-3", cfg.stt.model);
    try std.testing.expectEqual(@as(usize, 0), cfg.stt.keyterms.len);
    try std.testing.expectEqualStrings("global", cfg.stt.region);
    try std.testing.expect(cfg.llm.enabled);
    try std.testing.expectEqualStrings("type", cfg.output.method);
    try std.testing.expect(cfg.output.trailing_space);
    try std.testing.expectEqual(@as(u32, 300), cfg.recording.max_seconds);
    try std.testing.expect(cfg.hud.show_timer);
}

test "HUD timer can be disabled" {
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"hud":{"show_timer":false}}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.hud.show_timer);
}

test "validation rejects unknown output methods" {
    var cfg: Config = .{};
    cfg.output.method = "typo";
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "validation accepts paste output method" {
    var cfg: Config = .{};
    cfg.output.method = "paste";
    try validate(&cfg);
}

test "validation accepts phrases and rejects invalid keyterms" {
    var cfg: Config = .{};
    cfg.stt.keyterms = &.{ "SayAll", "Model Context Protocol" };
    try validate(&cfg);

    cfg.stt.keyterms = &.{"line\nbreak"};
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));

    cfg.stt.keyterms = &.{ "SayAll", "SayAll" };
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));

    cfg.stt.keyterms = &.{"SayAll"};
    cfg.stt.model = "nova-2";
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "config load migrates legacy exact duplicates without startup failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_base = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_base);
    const absolute_base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, std.testing.allocator);
    defer std.testing.allocator.free(absolute_base);
    const config_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/sayall", .{absolute_base});
    defer std.testing.allocator.free(config_dir);
    const dir = try Io.Dir.cwd().createDirPathOpen(std.testing.io, config_dir, .{});
    dir.close(std.testing.io);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{config_dir});
    defer std.testing.allocator.free(config_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = config_path,
        .data =
        \\{"stt":{"keyterms":["SayAll","München","SayAll","sayall","München"," spaced "]}}
        ,
    });

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", absolute_base);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cfg = try load(arena, std.testing.io, &env);
    try std.testing.expectEqual(@as(usize, 4), cfg.stt.keyterms.len);
    try std.testing.expectEqualStrings("SayAll", cfg.stt.keyterms[0]);
    try std.testing.expectEqualStrings("München", cfg.stt.keyterms[1]);
    try std.testing.expectEqualStrings("sayall", cfg.stt.keyterms[2]);
    try std.testing.expectEqualStrings(" spaced ", cfg.stt.keyterms[3]);

    const keywords_path = try std.fmt.allocPrint(arena, "{s}/keywords.json", .{config_dir});
    const stored = (try keywords.Store.init(keywords_path).load(arena, std.testing.io)).?;
    try std.testing.expectEqual(@as(usize, 4), stored.len);
}
