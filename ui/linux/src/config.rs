use serde::Deserialize;
use std::fs::OpenOptions;
use std::io::{self, Read};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::PathBuf;

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

#[derive(Default, Deserialize)]
#[serde(default)]
struct Config {
    recording: RecordingConfig,
}

pub fn load() -> io::Result<RecordingConfig> {
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
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(RecordingConfig::default()),
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
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(RecordingConfig::default()),
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
    Ok(cfg.recording)
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
        value.max_seconds = 1;
        value.min_ms = 1001;
        assert!(validate(&value).is_err());
        value.min_ms = 1000;
        value.source = "bad\nsource".into();
        assert!(validate(&value).is_err());
    }

    #[test]
    fn full_config_ignores_unrelated_canonical_fields() {
        let cfg: Config = serde_json::from_str(
            r#"{"stt":{"provider":"deepgram"},"llm":{"enabled":true},"recording":{"max_seconds":5,"min_ms":200,"source":"node"},"output":{"method":"type"}}"#,
        )
        .unwrap();
        assert_eq!(cfg.recording.max_seconds, 5);
        assert_eq!(cfg.recording.min_ms, 200);
        assert_eq!(cfg.recording.source, "node");
    }
}
