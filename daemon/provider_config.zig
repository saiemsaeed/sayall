/// Provider-only configuration. This module deliberately has no product,
/// platform, environment, or filesystem dependencies.
pub const SttConfig = struct {
    provider: []const u8 = "deepgram",
    api_key: []const u8 = "",
    model: []const u8 = "nova-3",
    language: []const u8 = "en",
    keyterms: []const []const u8 = &.{},
    region: []const u8 = "global",
    smart_format: bool = false,
    punctuate: bool = false,
    dictation: bool = false,
    numerals: bool = false,
    measurements: bool = false,
    streaming: bool = true,
    stream_finalize_timeout_ms: u32 = 2000,
};

pub const LlmConfig = struct {
    provider: []const u8 = "cerebras",
    api_key: []const u8 = "",
    model: []const u8 = "gpt-oss-120b",
    base_url: []const u8 = "https://api.cerebras.ai/v1/chat/completions",
    enabled: bool = false,
};
