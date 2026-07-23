/// Provider-only configuration. This module deliberately has no product,
/// platform, environment, or filesystem dependencies.
pub const SttConfig = struct {
    provider: []const u8 = "deepgram",
    api_key: []const u8 = "",
    model: []const u8 = "nova-3",
    language: []const u8 = "en",
    keyterms: []const []const u8 = &.{},
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
