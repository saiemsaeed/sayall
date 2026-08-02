use serde::Deserialize;
use std::fs::OpenOptions;
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Deserialize)]
#[serde(default)]
pub struct RecordingConfig {
    pub max_seconds: u32,
    pub min_ms: u32,
    pub source: String,
}

impl Default for RecordingConfig {
    fn default() -> Self {
        Self {
            max_seconds: 300,
            min_ms: 300,
            source: String::new(),
        }
    }
}

#[derive(Deserialize)]
#[serde(default)]
struct Config {
    recording: RecordingConfig,
    stt: Stt,
    llm: Llm,
    output: Output,
    notifications: bool,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            recording: RecordingConfig::default(),
            stt: Stt::default(),
            llm: Llm::default(),
            output: Output::default(),
            notifications: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputMethod {
    Type,
    Clipboard,
    Paste,
}
#[derive(Clone, Debug)]
pub struct OutputConfig {
    pub method: OutputMethod,
    pub trailing_space: bool,
}
#[derive(Deserialize)]
#[serde(default)]
struct Output {
    method: String,
    trailing_space: bool,
}
impl Default for Output {
    fn default() -> Self {
        Self {
            method: "type".into(),
            trailing_space: true,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ProviderConfig {
    pub deepgram_api_key: String,
    pub deepgram_model: String,
    pub deepgram_language: String,
    pub deepgram_region: String,
    pub keyterms: Vec<String>,
    pub streaming: bool,
    pub finalize_ms: u32,
    pub groq_api_key: String,
    pub groq_model: String,
    pub groq_base_url: String,
    pub cleanup: bool,
}
#[derive(Clone, Debug)]
pub struct SessionConfig {
    pub recording: RecordingConfig,
    pub provider: ProviderConfig,
    pub output: OutputConfig,
    pub notifications: bool,
}
#[derive(Deserialize)]
#[serde(default)]
struct Stt {
    provider: String,
    api_key: String,
    model: String,
    language: String,
    region: String,
    keyterms: Vec<String>,
    streaming: Option<bool>,
    stream_finalize_timeout_ms: Option<u32>,
}
impl Default for Stt {
    fn default() -> Self {
        Self {
            provider: "deepgram".into(),
            api_key: String::new(),
            model: "nova-3".into(),
            language: "en".into(),
            region: "global".into(),
            keyterms: Vec::new(),
            streaming: Some(true),
            stream_finalize_timeout_ms: Some(2000),
        }
    }
}
#[derive(Deserialize)]
#[serde(default)]
struct Llm {
    provider: String,
    api_key: String,
    model: String,
    base_url: String,
    enabled: Option<bool>,
}
impl Default for Llm {
    fn default() -> Self {
        Self {
            provider: "groq".into(),
            api_key: String::new(),
            model: "llama-3.1-8b-instant".into(),
            base_url: "https://api.groq.com/openai/v1/chat/completions".into(),
            enabled: Some(true),
        }
    }
}

pub fn load() -> io::Result<SessionConfig> {
    let root =
        if let Some(value) = std::env::var_os("XDG_CONFIG_HOME") {
            PathBuf::from(value)
        } else {
            PathBuf::from(std::env::var_os("HOME").ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "config home unavailable")
            })?)
            .join(".config")
        };
    if !root.is_absolute() {
        return Err(invalid("config home must be absolute"));
    }
    let path = root.join("sayall/config.json");
    let parent = path.parent().expect("config parent");
    match std::fs::symlink_metadata(parent) {
        Ok(meta)
            if meta.file_type().is_dir()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.mode() & 0o077 == 0 => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Err(invalid("configuration missing"));
        }
        _ => {
            return Err(invalid(
                "config parent must be a private user-owned directory",
            ));
        }
    }
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
    {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Err(invalid("configuration missing"));
        }
        Err(e) => return Err(e),
    };
    let meta = file.metadata()?;
    if !meta.file_type().is_file()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
    {
        return Err(invalid(
            "config must be a private regular file owned by this user",
        ));
    }
    if meta.len() > 1024 * 1024 {
        return Err(invalid("config exceeds 1 MiB"));
    }
    let mut bytes = Vec::new();
    file.by_ref()
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err(invalid("config exceeds 1 MiB"));
    }
    let cfg: Config =
        serde_json::from_slice(&bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    validate(&cfg.recording)?;
    let deepgram_api_key = resolve_secret(cfg.stt.api_key, "DEEPGRAM_API_KEY");
    let groq_api_key = resolve_secret(cfg.llm.api_key, "GROQ_API_KEY");
    let model = cfg.stt.model;
    let language = cfg.stt.language;
    let region = cfg.stt.region;
    let groq_model = cfg.llm.model;
    let base = cfg.llm.base_url;
    let keyterms = load_keywords(parent, cfg.stt.keyterms)?;
    let method = parse_output_method(&cfg.output.method)?;
    if deepgram_api_key.is_empty()
        || !safe_secret(&deepgram_api_key)
        || !safe_secret(&groq_api_key)
        || cfg.stt.provider != "deepgram"
        || cfg.llm.provider != "groq"
        || !safe_value(&model)
        || !safe_value(&language)
        || !safe_value(&groq_model)
        || !["global", "eu", "au"].contains(&region.as_str())
        || base != "https://api.groq.com/openai/v1/chat/completions"
        || keyterms.len() > 0 && model != "nova-3" && !model.starts_with("nova-3-")
    {
        return Err(invalid("invalid provider configuration"));
    }
    let finalize = cfg.stt.stream_finalize_timeout_ms.unwrap_or(2000);
    if !(250..=10_000).contains(&finalize) {
        return Err(invalid("invalid stream finalize timeout"));
    }
    Ok(SessionConfig {
        recording: cfg.recording,
        output: OutputConfig {
            method,
            trailing_space: cfg.output.trailing_space,
        },
        notifications: cfg.notifications,
        provider: ProviderConfig {
            deepgram_api_key,
            deepgram_model: model,
            deepgram_language: language,
            deepgram_region: region,
            keyterms,
            streaming: cfg.stt.streaming.unwrap_or(true),
            finalize_ms: finalize,
            groq_api_key: groq_api_key.clone(),
            groq_model,
            groq_base_url: base,
            cleanup: cfg.llm.enabled.unwrap_or(true) && !groq_api_key.is_empty(),
        },
    })
}

fn resolve_secret(value: String, override_name: &str) -> String {
    resolve_secret_with(value, std::env::var(override_name).ok(), |name| {
        std::env::var(name).ok()
    })
}

fn resolve_secret_with<F>(value: String, override_value: Option<String>, lookup: F) -> String
where
    F: FnOnce(&str) -> Option<String>,
{
    if let Some(value) = override_value.filter(|value| !value.is_empty()) {
        return value;
    }
    match value.strip_prefix('$') {
        Some(name) if !name.is_empty() => lookup(name).unwrap_or_default(),
        _ => value,
    }
}

fn parse_output_method(value: &str) -> io::Result<OutputMethod> {
    match value {
        "type" => Ok(OutputMethod::Type),
        "clipboard" => Ok(OutputMethod::Clipboard),
        "paste" => Ok(OutputMethod::Paste),
        _ => Err(invalid(
            "output.method must be 'type', 'clipboard', or 'paste'",
        )),
    }
}
fn safe_secret(v: &str) -> bool {
    v.chars().all(|c| !c.is_whitespace() && !c.is_control())
}
fn safe_value(v: &str) -> bool {
    !v.is_empty()
        && v.len() <= 64
        && v.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"-._".contains(&b))
}
fn load_keywords(dir: &Path, fallback: Vec<String>) -> io::Result<Vec<String>> {
    let p = dir.join("keywords.json");
    let values = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(p)
    {
        Ok(f) => {
            #[derive(Deserialize)]
            struct K {
                version: u32,
                keywords: Vec<String>,
            }
            let m = f.metadata()?;
            if !m.file_type().is_file()
                || m.len() > 65536
                || m.uid() != unsafe { libc::geteuid() }
                || m.mode() & 0o077 != 0
            {
                return Err(invalid("invalid keywords file"));
            }
            let mut b = Vec::new();
            f.take(65537).read_to_end(&mut b)?;
            if b.len() > 65536 {
                return Err(invalid("invalid keywords file"));
            }
            let k: K = serde_json::from_slice(&b).map_err(|_| invalid("invalid keywords file"))?;
            if k.version != 1 {
                return Err(invalid("invalid keywords version"));
            }
            k.keywords
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => fallback,
        Err(e) => return Err(e),
    };
    let mut unique = std::collections::HashSet::new();
    if values.len() > 100
        || values.iter().map(|x| x.len()).sum::<usize>() > 4096
        || values.iter().any(|x| {
            x.is_empty() || x.len() > 256 || x.chars().any(|c| c.is_control()) || !unique.insert(x)
        })
    {
        return Err(invalid("invalid keywords"));
    }
    Ok(values)
}

fn validate(value: &RecordingConfig) -> io::Result<()> {
    if value.max_seconds == 0 || value.max_seconds > 3600 {
        return Err(invalid("recording.max_seconds must be between 1 and 3600"));
    }
    if value.min_ms > value.max_seconds * 1000 {
        return Err(invalid("recording.min_ms exceeds max_seconds"));
    }
    if value
        .source
        .chars()
        .any(|c| c == '\0' || c == '\r' || c == '\n')
    {
        return Err(invalid("recording.source contains invalid characters"));
    }
    Ok(())
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recording_boundaries_match_canonical_config() {
        validate(&RecordingConfig::default()).unwrap();
        let mut value = RecordingConfig::default();
        value.max_seconds = 0;
        assert!(validate(&value).is_err());
        value.max_seconds = 3601;
        assert!(validate(&value).is_err());
        value.max_seconds = 3600;
        validate(&value).unwrap();
        value.max_seconds = 1;
        value.min_ms = 1001;
        assert!(validate(&value).is_err());
        value.min_ms = 1000;
        value.source = "bad\nsource".into();
        assert!(validate(&value).is_err());
    }

    #[test]
    fn full_config_loads_output_fields() {
        let cfg: Config = serde_json::from_str(
            r#"{"stt":{"provider":"deepgram"},"llm":{"enabled":true},"recording":{"max_seconds":5,"min_ms":200,"source":"node"},"output":{"method":"type"}}"#,
        )
        .unwrap();
        assert_eq!(cfg.recording.max_seconds, 5);
        assert_eq!(cfg.recording.min_ms, 200);
        assert_eq!(cfg.recording.source, "node");
        assert_eq!(cfg.output.method, "type");
        assert!(cfg.output.trailing_space);
    }

    #[test]
    fn provider_defaults_apply_only_to_omitted_fields() {
        let omitted: Config = serde_json::from_str("{}").unwrap();
        assert_eq!(omitted.stt.model, "nova-3");
        assert_eq!(omitted.llm.provider, "groq");
        let explicit: Config = serde_json::from_str(
            r#"{"stt":{"model":"","provider":""},"llm":{"provider":"","model":""}}"#,
        )
        .unwrap();
        assert!(explicit.stt.model.is_empty());
        assert!(explicit.stt.provider.is_empty());
        assert!(explicit.llm.provider.is_empty());
        assert!(explicit.llm.model.is_empty());
    }

    #[test]
    fn output_method_validation_accepts_defaults_and_rejects_unknown_values() {
        let default: Config = serde_json::from_str("{}").unwrap();
        assert_eq!(
            parse_output_method(&default.output.method).unwrap(),
            OutputMethod::Type
        );
        assert_eq!(parse_output_method("type").unwrap(), OutputMethod::Type);
        assert_eq!(
            parse_output_method("clipboard").unwrap(),
            OutputMethod::Clipboard
        );
        assert_eq!(parse_output_method("paste").unwrap(), OutputMethod::Paste);
        assert!(parse_output_method("other").is_err());
    }

    #[test]
    fn secret_resolution_matches_canonical_environment_rules() {
        assert_eq!(
            resolve_secret_with("file".into(), Some("override".into()), |_| None),
            "override"
        );
        assert_eq!(
            resolve_secret_with("$TOKEN".into(), None, |name| {
                (name == "TOKEN").then(|| "resolved".into())
            }),
            "resolved"
        );
        assert_eq!(resolve_secret_with("$MISSING".into(), None, |_| None), "");
        assert_eq!(
            resolve_secret_with("literal".into(), None, |_| None),
            "literal"
        );
    }
}
