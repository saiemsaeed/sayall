const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const keywords = @import("keywords.zig");
const paths = @import("paths.zig");
const provider_config = @import("provider_config.zig");
pub const processing = @import("processing.zig");

pub const SttConfig = provider_config.SttConfig;
pub const LlmConfig = provider_config.LlmConfig;

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
    /// Linux HUD palette. "omarchy" follows the active Omarchy colors.
    theme: []const u8 = "omarchy",
    /// Linux HUD corner treatment for non-Omarchy themes.
    shape: []const u8 = "rounded",
};

pub const Config = struct {
    stt: SttConfig = .{},
    llm: LlmConfig = .{},
    processing: processing.Config = .{},
    output: OutputConfig = .{},
    recording: RecordingConfig = .{},
    metrics: MetricsConfig = .{},
    hud: HudConfig = .{},
    notifications: bool = true,
    verbose: bool = false,
};

pub const ValidationError = error{InvalidConfig};

/// The single Zig-owned default template. It is serialized from Config so the
/// initializer cannot drift from runtime defaults and secrets remain empty.
pub fn defaultTemplate(gpa: Allocator) ![]u8 {
    const cfg: Config = .{ .processing = .{ .mode = .verbatim } };
    return std.json.Stringify.valueAlloc(gpa, cfg, .{ .whitespace = .indent_2 });
}

pub fn effectiveProcessingProfile(cfg: *const Config) processing.Profile {
    return processing.effective(cfg.processing, cfg.llm.enabled);
}

/// Securely creates config.json without replacing any existing filesystem
/// object. The final file is created exclusively, so readers never observe a
/// replace of their configuration; a failed write removes the partial file.
pub fn initDefault(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) ![]const u8 {
    if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos) {
        const root = try configRoot(gpa, env);
        defer gpa.free(root);
        // Validate the complete environment policy before making directories.
        const path = try std.fmt.allocPrint(gpa, "{s}/sayall/config.json", .{root});
        errdefer gpa.free(path);
        const base = try Io.Dir.cwd().createDirPathOpen(io, root, .{});
        defer base.close(io);
        base.createDir(io, "sayall", .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        // Linux needs a real readable directory descriptor (not O_PATH) for
        // fchmod; `iterate` makes Zig open one while preserving no-follow.
        const dir = try base.openDir(io, "sayall", .{ .iterate = true, .follow_symlinks = false });
        defer dir.close(io);
        const parent_stat = try dir.stat(io);
        if (parent_stat.kind != .directory) return error.UnsafeConfigDirectory;
        try validateDirectoryOwner(dir.handle);
        try dir.setPermissions(io, .fromMode(0o700));

        const template = try defaultTemplate(gpa);
        defer gpa.free(template);
        const file = try dir.createFile(io, "config.json", .{
            .exclusive = true,
            .permissions = @enumFromInt(0o600),
        });
        errdefer dir.deleteFile(io, "config.json") catch {};
        defer file.close(io);
        try file.writeStreamingAll(io, template);
        return path;
    } else {
        return error.UnsupportedPlatform;
    }
}

fn configRoot(gpa: Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len == 0 or !std.fs.path.isAbsolute(xdg)) return error.InvalidConfigHome;
        return gpa.dupe(u8, xdg);
    }
    const home = env.get("HOME") orelse return error.ConfigHomeUnavailable;
    if (home.len == 0 or !std.fs.path.isAbsolute(home)) return error.InvalidConfigHome;
    return std.fmt.allocPrint(gpa, "{s}/.config", .{home});
}

fn validateDirectoryOwner(handle: Io.File.Handle) !void {
    if (builtin.os.tag == .linux) {
        var raw: std.os.linux.Statx = undefined;
        if (std.os.linux.errno(std.os.linux.statx(handle, "", std.os.linux.AT.EMPTY_PATH, .{ .UID = true }, &raw)) != .SUCCESS)
            return error.StatFailed;
        if (raw.uid != std.os.linux.geteuid()) return error.WrongOwner;
    } else if (builtin.os.tag == .macos) {
        var raw: std.c.Stat = undefined;
        if (std.c.fstat(handle, &raw) != 0) return error.StatFailed;
        if (raw.uid != std.c.geteuid()) return error.WrongOwner;
    } else return error.UnsupportedPlatform;
}

/// Loads config from ~/.config/sayall/config.json if it exists and applies
/// environment overrides. All strings are owned by `gpa` (use an arena).
pub fn load(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Config {
    return loadWithPolicy(gpa, io, env, true);
}

/// Loads and validates configuration without performing legacy keyword
/// migration or any other filesystem write.
pub fn loadReadOnly(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !Config {
    return (try loadReadOnlyWithPresence(gpa, io, env)).config;
}

pub const ReadOnlyResult = struct {
    config: Config,
    present: bool,
};

/// Reads config and keywords through no-follow descriptors rooted in one
/// pinned, private directory, so validation cannot race a second pathname open.
pub fn loadReadOnlyWithPresence(gpa: Allocator, io: Io, env: *const std.process.Environ.Map) !ReadOnlyResult {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos)
        return error.UnsupportedPlatform;
    const path = try paths.Config.file(gpa, env) orelse return readOnlyDefaults(gpa, env);
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;
    var parent = Io.Dir.openDirAbsolute(io, parent_path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return readOnlyDefaults(gpa, env),
        else => return err,
    };
    defer parent.close(io);
    const parent_stat = try parent.stat(io);
    if (parent_stat.kind != .directory or parent_stat.permissions.toMode() & 0o077 != 0)
        return error.UnsafeConfigDirectory;
    try validateDirectoryOwner(parent.handle);

    const config_bytes = try readPrivateFile(gpa, io, parent, std.fs.path.basename(path), 1024 * 1024);
    var cfg: Config = if (config_bytes) |bytes|
        try std.json.parseFromSliceLeaky(Config, gpa, bytes, .{ .allocate = .alloc_always })
    else
        .{};
    applyEnvironment(&cfg, env);

    if (try readPrivateFile(gpa, io, parent, "keywords.json", 64 * 1024)) |bytes|
        cfg.stt.keyterms = try keywords.parseFileContents(gpa, bytes)
    else
        cfg.stt.keyterms = try keywords.normalizeLegacy(gpa, cfg.stt.keyterms);
    try validate(&cfg);
    return .{ .config = cfg, .present = config_bytes != null };
}

fn readOnlyDefaults(gpa: Allocator, env: *const std.process.Environ.Map) !ReadOnlyResult {
    var cfg: Config = .{};
    applyEnvironment(&cfg, env);
    cfg.stt.keyterms = try keywords.normalizeLegacy(gpa, cfg.stt.keyterms);
    try validate(&cfg);
    return .{ .config = cfg, .present = false };
}

fn applyEnvironment(cfg: *Config, env: *const std.process.Environ.Map) void {
    // One-cycle upgrade bridge: never reinterpret the legacy credential as a
    // Cerebras key. Only migrate provider metadata in memory so Polished can
    // surface the normal missing-Cerebras-key guidance.
    if (std.mem.eql(u8, cfg.llm.provider, "groq") or
        std.mem.eql(u8, cfg.llm.base_url, "https://api.groq.com/openai/v1/chat/completions"))
    {
        cfg.llm.provider = "cerebras";
        cfg.llm.api_key = "";
        cfg.llm.model = "gpt-oss-120b";
        cfg.llm.base_url = "https://api.cerebras.ai/v1/chat/completions";
    }
    cfg.stt.api_key = resolveEnvRef(env, cfg.stt.api_key);
    cfg.llm.api_key = resolveEnvRef(env, cfg.llm.api_key);
    if (env.get("DEEPGRAM_API_KEY")) |key| cfg.stt.api_key = key;
    if (env.get("CEREBRAS_API_KEY")) |key| cfg.llm.api_key = key;
    if (env.get("SAYALL_STT_MODEL")) |model| cfg.stt.model = model;
    if (env.get("SAYALL_LLM_MODEL")) |model| cfg.llm.model = model;
    if (env.get("SAYALL_VERBOSE")) |value|
        if (value.len > 0 and value[0] != '0') {
            cfg.verbose = true;
        };
}

fn readPrivateFile(gpa: Allocator, io: Io, parent: Io.Dir, name: []const u8, limit: usize) !?[]u8 {
    if (comptime builtin.os.tag != .linux and builtin.os.tag != .macos)
        return error.UnsupportedPlatform;
    const handle = std.posix.openat(parent.handle, name, .{
        .NONBLOCK = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    }, 0) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    var file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.permissions.toMode() & 0o077 != 0)
        return error.UnsafeConfigFile;
    try validateDirectoryOwner(file.handle);
    var storage: [4096]u8 = undefined;
    var reader = file.reader(io, &storage);
    const bytes = try reader.interface.allocRemaining(gpa, .limited(limit + 1));
    if (bytes.len > limit) return error.ConfigFileTooLarge;
    return bytes;
}

fn loadWithPolicy(gpa: Allocator, io: Io, env: *const std.process.Environ.Map, migrate_keywords: bool) !Config {
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

    applyEnvironment(&cfg, env);

    if (try paths.Config.keywords(gpa, env)) |keywords_path| {
        const store = keywords.Store.init(keywords_path);
        if (try store.load(gpa, io)) |stored| {
            cfg.stt.keyterms = stored;
        } else {
            // Validate the complete legacy configuration before migration has
            // any filesystem side effects.
            cfg.stt.keyterms = try keywords.normalizeLegacy(gpa, cfg.stt.keyterms);
            try validate(&cfg);
            if (migrate_keywords)
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
    if (!std.mem.eql(u8, cfg.llm.provider, "cerebras")) return invalid("llm.provider must be 'cerebras'");
    if (!std.mem.eql(u8, cfg.stt.region, "global") and !std.mem.eql(u8, cfg.stt.region, "eu") and
        !std.mem.eql(u8, cfg.stt.region, "au"))
        return invalid("stt.region must be 'global', 'eu', or 'au'");
    if (cfg.stt.stream_finalize_timeout_ms < 250 or cfg.stt.stream_finalize_timeout_ms > 10_000)
        return invalid("stt.stream_finalize_timeout_ms must be between 250 and 10000");
    if (cfg.stt.dictation and !cfg.stt.punctuate)
        return invalid("stt.dictation requires stt.punctuate");
    if (!std.mem.eql(u8, cfg.llm.base_url, "https://api.cerebras.ai/v1/chat/completions"))
        return invalid("llm.base_url must be the Cerebras HTTPS endpoint");
    if (!safeToken(cfg.stt.model) or !safeToken(cfg.stt.language))
        return invalid("STT model and language values may contain only letters, digits, '.', '-', and '_'");
    if (!safeLlmModel(cfg.llm.model))
        return invalid("llm.model must be one or two '/'-separated segments containing only letters, digits, '.', '-', and '_'");
    if (!std.mem.eql(u8, cfg.llm.model, "gpt-oss-120b"))
        return invalid("llm.model must be 'gpt-oss-120b'");
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
    if (!allowedValue(cfg.hud.theme, &.{
        "omarchy",
        "catppuccin",
        "gruvbox",
        "nord",
        "tokyo-night",
        "rose-pine",
        "kanagawa",
        "everforest",
        "ethereal",
        "ristretto",
        "matte-black",
        "dark",
    })) return invalid("hud.theme is not a supported preconfigured theme");
    if (!allowedValue(cfg.hud.shape, &.{ "rounded", "soft", "square" }))
        return invalid("hud.shape must be 'rounded', 'soft', or 'square'");
}

fn allowedValue(value: []const u8, allowed: []const []const u8) bool {
    for (allowed) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn safeSecret(value: []const u8) bool {
    for (value) |c| if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
    return true;
}

fn safeToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '-' and c != '_') return false;
    return true;
}

fn safeLlmModel(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    const slash = std.mem.indexOfScalar(u8, value, '/');
    if (slash) |at| {
        if (at == 0 or at + 1 == value.len or std.mem.indexOfScalar(u8, value[at + 1 ..], '/') != null) return false;
        return safeToken(value[0..at]) and safeToken(value[at + 1 ..]);
    }
    return safeToken(value);
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
    try std.testing.expect(!cfg.stt.smart_format);
    try std.testing.expect(!cfg.stt.punctuate);
    try std.testing.expect(!cfg.stt.dictation);
    try std.testing.expect(!cfg.stt.numerals);
    try std.testing.expect(!cfg.stt.measurements);
    try std.testing.expect(!cfg.llm.enabled);
    try std.testing.expectEqual(processing.Profile.verbatim, effectiveProcessingProfile(&cfg));
    try std.testing.expectEqualStrings("type", cfg.output.method);
    try std.testing.expect(cfg.output.trailing_space);
    try std.testing.expectEqual(@as(u32, 300), cfg.recording.max_seconds);
    try std.testing.expect(cfg.hud.show_timer);
    try std.testing.expectEqualStrings("omarchy", cfg.hud.theme);
    try std.testing.expectEqualStrings("rounded", cfg.hud.shape);
}

test "default template parses validates and keeps API keys empty" {
    const template = try defaultTemplate(std.testing.allocator);
    defer std.testing.allocator.free(template);
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, template, .{});
    defer parsed.deinit();
    try validate(&parsed.value);
    try std.testing.expectEqualStrings("", parsed.value.stt.api_key);
    try std.testing.expectEqualStrings("", parsed.value.llm.api_key);
    try std.testing.expectEqual(processing.Mode.verbatim, parsed.value.processing.mode.?);
}

test "processing migration matrix and explicit mode precedence" {
    for ([_]struct { json: []const u8, expected: processing.Profile }{
        .{ .json = "{}", .expected = .verbatim },
        .{ .json = "{\"llm\":{\"enabled\":false}}", .expected = .verbatim },
        .{ .json = "{\"llm\":{\"enabled\":true}}", .expected = .legacy_v1 },
        .{ .json = "{\"processing\":{\"mode\":\"verbatim\"},\"llm\":{\"enabled\":true}}", .expected = .verbatim },
        .{ .json = "{\"processing\":{\"mode\":\"clean\"},\"llm\":{\"enabled\":true}}", .expected = .clean },
        .{ .json = "{\"processing\":{\"mode\":\"polished\"},\"llm\":{\"enabled\":false}}", .expected = .polished },
    }) |case| {
        const parsed = try std.json.parseFromSlice(Config, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.expected, effectiveProcessingProfile(&parsed.value));
    }
}

test "removed AI-only mode is rejected" {
    try std.testing.expectError(
        error.InvalidEnumTag,
        std.json.parseFromSlice(
            Config,
            std.testing.allocator,
            "{\"processing\":{\"mode\":\"ai_only\"}}",
            .{},
        ),
    );
}

test "config init honors XDG permissions and never overwrites" {
    if (@import("builtin").os.tag != .linux and @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);
    const root = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(root);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);
    const path = try initDefault(std.testing.allocator, std.testing.io, &env);
    defer std.testing.allocator.free(path);
    const parent = std.fs.path.dirname(path).?;
    const parent_stat = try Io.Dir.cwd().statFile(std.testing.io, parent, .{});
    const file_stat = try Io.Dir.cwd().statFile(std.testing.io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o700), parent_stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(u32, 0o600), file_stat.permissions.toMode() & 0o777);
    try Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "preserve" });
    try std.testing.expectError(error.PathAlreadyExists, initDefault(std.testing.allocator, std.testing.io, &env));
    const preserved = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(preserved);
    try std.testing.expectEqualStrings("preserve", preserved);
}

test "config init validates XDG and falls back to HOME before mutation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);
    const home = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(home);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", home);
    const path = try initDefault(std.testing.allocator, std.testing.io, &env);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/.config/sayall/config.json"));
    try env.put("XDG_CONFIG_HOME", "");
    try std.testing.expectError(error.InvalidConfigHome, initDefault(std.testing.allocator, std.testing.io, &env));
    try env.put("XDG_CONFIG_HOME", "relative");
    try std.testing.expectError(error.InvalidConfigHome, initDefault(std.testing.allocator, std.testing.io, &env));
}

test "config init rejects symlink parent without chmodding target" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "target", .fromMode(0o755));
    try tmp.dir.symLink(std.testing.io, "target", "sayall", .{ .is_directory = true });
    const relative = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative);
    const root = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, std.testing.allocator);
    defer std.testing.allocator.free(root);
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", root);
    if (initDefault(std.testing.allocator, std.testing.io, &env)) |unexpected| {
        std.testing.allocator.free(unexpected);
        return error.TestUnexpectedResult;
    } else |_| {}
    const stat = try tmp.dir.statFile(std.testing.io, "target", .{});
    try std.testing.expectEqual(@as(u32, 0o755), stat.permissions.toMode() & 0o777);
}

test "HUD timer can be disabled" {
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"hud":{"show_timer":false}}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.hud.show_timer);
}

test "HUD accepts preconfigured themes and shape variants" {
    const parsed = try std.json.parseFromSlice(Config, std.testing.allocator,
        \\{"hud":{"theme":"catppuccin","shape":"square"}}
    , .{});
    defer parsed.deinit();
    try validate(&parsed.value);
    try std.testing.expectEqualStrings("catppuccin", parsed.value.hud.theme);
    try std.testing.expectEqualStrings("square", parsed.value.hud.shape);

    var invalid_theme: Config = .{};
    invalid_theme.hud.theme = "custom";
    try std.testing.expectError(error.InvalidConfig, validate(&invalid_theme));
    var invalid_shape: Config = .{};
    invalid_shape.hud.shape = "pill-ish";
    try std.testing.expectError(error.InvalidConfig, validate(&invalid_shape));
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

test "dictation requires punctuation" {
    var cfg: Config = .{};
    cfg.stt.dictation = true;
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
    cfg.stt.punctuate = true;
    try validate(&cfg);
}

test "provider tokens are bounded consistently with worker protocol" {
    var cfg: Config = .{};
    var accepted: [64]u8 = @splat('a');
    cfg.stt.model = &accepted;
    try validate(&cfg);
    var rejected: [65]u8 = @splat('a');
    cfg.stt.model = &rejected;
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "LLM model accepts one optional namespace and conservative length" {
    var cfg: Config = .{};
    cfg.llm.model = "gpt-oss-120b";
    try validate(&cfg);
    for ([_][]const u8{ "/openai", "openai/", "a/b/c" }) |model| {
        cfg.llm.model = model;
        try std.testing.expectError(error.InvalidConfig, validate(&cfg));
    }
    var overlong: [65]u8 = @splat('a');
    cfg.llm.model = &overlong;
    try std.testing.expectError(error.InvalidConfig, validate(&cfg));
}

test "legacy cloud provider metadata migrates without reusing its credential" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var cfg: Config = .{};
    cfg.llm.provider = "groq";
    cfg.llm.api_key = "legacy-secret";
    cfg.llm.model = "openai/gpt-oss-20b";
    cfg.llm.base_url = "https://api.groq.com/openai/v1/chat/completions";
    applyEnvironment(&cfg, &env);
    try std.testing.expectEqualStrings("cerebras", cfg.llm.provider);
    try std.testing.expectEqualStrings("", cfg.llm.api_key);
    try std.testing.expectEqualStrings("gpt-oss-120b", cfg.llm.model);
    try std.testing.expectEqualStrings("https://api.cerebras.ai/v1/chat/completions", cfg.llm.base_url);
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
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const relative_base = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer std.testing.allocator.free(relative_base);
    const absolute_base = try Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative_base, std.testing.allocator);
    defer std.testing.allocator.free(absolute_base);
    const config_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/sayall", .{absolute_base});
    defer std.testing.allocator.free(config_dir);
    const dir = try Io.Dir.cwd().createDirPathOpen(std.testing.io, config_dir, .{
        .open_options = .{ .iterate = true },
        .permissions = .fromMode(0o700),
    });
    try dir.setPermissions(std.testing.io, .fromMode(0o700));
    dir.close(std.testing.io);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.json", .{config_dir});
    defer std.testing.allocator.free(config_path);
    try Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = config_path,
        .data =
        \\{"stt":{"keyterms":["SayAll","München","SayAll","sayall","München"," spaced "]}}
        ,
    });
    const config_file = try Io.Dir.cwd().openFile(std.testing.io, config_path, .{ .mode = .read_write });
    try config_file.setPermissions(std.testing.io, .fromMode(0o600));
    config_file.close(std.testing.io);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_CONFIG_HOME", absolute_base);
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const read_only = try loadReadOnly(arena, std.testing.io, &env);
    try std.testing.expectEqual(@as(usize, 4), read_only.stt.keyterms.len);
    const keywords_path = try std.fmt.allocPrint(arena, "{s}/keywords.json", .{config_dir});
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(std.testing.io, keywords_path, .{}));

    const cfg = try load(arena, std.testing.io, &env);
    try std.testing.expectEqual(@as(usize, 4), cfg.stt.keyterms.len);
    try std.testing.expectEqualStrings("SayAll", cfg.stt.keyterms[0]);
    try std.testing.expectEqualStrings("München", cfg.stt.keyterms[1]);
    try std.testing.expectEqualStrings("sayall", cfg.stt.keyterms[2]);
    try std.testing.expectEqualStrings(" spaced ", cfg.stt.keyterms[3]);

    const stored = (try keywords.Store.init(keywords_path).load(arena, std.testing.io)).?;
    try std.testing.expectEqual(@as(usize, 4), stored.len);
}
