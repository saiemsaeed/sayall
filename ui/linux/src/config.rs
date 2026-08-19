use crate::theme::{Appearance, Shape, Theme};
use serde::{Deserialize, Serialize};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

const CONFIG_NAME: &str = "config.json";
const LOCK_NAME: &str = ".config.lock";
const CONFIG_MAX: usize = 1024 * 1024;

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
    processing: Processing,
    output: Output,
    hud: Hud,
    notifications: bool,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            recording: RecordingConfig::default(),
            stt: Stt::default(),
            llm: Llm::default(),
            processing: Processing::default(),
            output: Output::default(),
            hud: Hud::default(),
            notifications: true,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
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
    pub smart_format: bool,
    pub punctuate: bool,
    pub dictation: bool,
    pub numerals: bool,
    pub measurements: bool,
    pub streaming: bool,
    pub finalize_ms: u32,
    pub llm_api_key: String,
    pub llm_model: String,
    pub llm_base_url: String,
    pub processing_profile: ProcessingProfile,
}
#[derive(Clone, Debug)]
pub struct SessionConfig {
    pub recording: RecordingConfig,
    pub provider: ProviderConfig,
    pub output: OutputConfig,
    pub show_timer: bool,
    pub notifications: bool,
}

#[derive(Deserialize)]
#[serde(default)]
struct Hud {
    show_timer: bool,
    theme: Theme,
    shape: Shape,
}
impl Default for Hud {
    fn default() -> Self {
        Self {
            show_timer: true,
            theme: Theme::default(),
            shape: Shape::default(),
        }
    }
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
    smart_format: bool,
    punctuate: bool,
    dictation: bool,
    numerals: bool,
    measurements: bool,
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
            smart_format: false,
            punctuate: false,
            dictation: false,
            numerals: false,
            measurements: false,
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
            provider: "cerebras".into(),
            api_key: String::new(),
            model: "gpt-oss-120b".into(),
            base_url: "https://api.cerebras.ai/v1/chat/completions".into(),
            enabled: Some(false),
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingMode {
    Verbatim,
    Clean,
    Polished,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingProfile {
    Verbatim,
    Clean,
    Polished,
    LegacyV1,
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Processing {
    mode: Option<ProcessingMode>,
}

fn effective_processing_profile(
    mode: Option<ProcessingMode>,
    legacy_llm_enabled: bool,
) -> ProcessingProfile {
    match mode {
        Some(ProcessingMode::Verbatim) => ProcessingProfile::Verbatim,
        Some(ProcessingMode::Clean) => ProcessingProfile::Clean,
        Some(ProcessingMode::Polished) => ProcessingProfile::Polished,
        None if legacy_llm_enabled => ProcessingProfile::LegacyV1,
        None => ProcessingProfile::Verbatim,
    }
}

pub fn selected_processing_mode() -> io::Result<ProcessingMode> {
    let (_, bytes) = read_secure_config()?;
    let cfg: Config =
        serde_json::from_slice(&bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    Ok(
        match effective_processing_profile(cfg.processing.mode, cfg.llm.enabled.unwrap_or(false)) {
            ProcessingProfile::Verbatim => ProcessingMode::Verbatim,
            ProcessingProfile::Clean => ProcessingMode::Clean,
            ProcessingProfile::Polished | ProcessingProfile::LegacyV1 => ProcessingMode::Polished,
        },
    )
}

pub fn selected_output_method() -> io::Result<OutputMethod> {
    let (_, bytes) = read_secure_config()?;
    let cfg: Config =
        serde_json::from_slice(&bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    parse_output_method(&cfg.output.method)
}

pub fn set_processing_mode(mode: ProcessingMode) -> io::Result<()> {
    let (parent, parent_path) = open_secure_parent()?;
    set_processing_mode_at(&parent, &parent_path, mode, || {}, || {})
}

pub fn set_output_method(method: OutputMethod) -> io::Result<()> {
    let (parent, parent_path) = open_secure_parent()?;
    set_output_method_at(&parent, &parent_path, method, || {}, || {})
}

fn set_processing_mode_at<B, A>(
    parent: &File,
    parent_path: &Path,
    mode: ProcessingMode,
    before_lock: B,
    after_lock: A,
) -> io::Result<()>
where
    B: FnOnce(),
    A: FnOnce(),
{
    mutate_config_at(parent, parent_path, before_lock, after_lock, |bytes| {
        encode_processing_mode(bytes, mode)
    })
}

fn set_output_method_at<B, A>(
    parent: &File,
    parent_path: &Path,
    method: OutputMethod,
    before_lock: B,
    after_lock: A,
) -> io::Result<()>
where
    B: FnOnce(),
    A: FnOnce(),
{
    mutate_config_at(parent, parent_path, before_lock, after_lock, |bytes| {
        encode_output_method(bytes, method)
    })
}

fn mutate_config_at<B, A, E>(
    parent: &File,
    parent_path: &Path,
    before_lock: B,
    after_lock: A,
    encode: E,
) -> io::Result<()>
where
    B: FnOnce(),
    A: FnOnce(),
    E: FnOnce(&[u8]) -> io::Result<Vec<u8>>,
{
    let source = read_config_at(parent)?;
    before_lock();
    let _lock = lock_config(parent)?;
    after_lock();
    ensure_source_unchanged(parent, &source)?;
    let output = encode(&source.bytes)?;
    project_session_config(&output, parent_path)?;

    let mut temporary = None;
    for attempt in 0..100 {
        let name = format!(".config.json.tmp-{}-{attempt}", std::process::id());
        match openat_file(
            parent,
            &name,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        ) {
            Ok(file) => {
                temporary = Some((name, file));
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error),
        }
    }
    let (temporary_name, mut temporary_file) =
        temporary.ok_or_else(|| invalid("could not create temporary configuration"))?;
    let result = (|| {
        temporary_file.write_all(&output)?;
        temporary_file.sync_all()?;
        drop(temporary_file);
        ensure_source_unchanged(parent, &source)?;
        renameat(parent, &temporary_name, CONFIG_NAME)?;
        parent.sync_all()
    })();
    if result.is_err() {
        let _ = unlinkat(parent, &temporary_name);
    }
    result
}

fn encode_processing_mode(bytes: &[u8], mode: ProcessingMode) -> io::Result<Vec<u8>> {
    let mut cfg: Config =
        serde_json::from_slice(&bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    migrate_legacy_llm(&mut cfg.llm);
    let llm_api_key = resolve_secret(cfg.llm.api_key, "CEREBRAS_API_KEY");
    if !valid_processing_credentials(
        match mode {
            ProcessingMode::Verbatim => ProcessingProfile::Verbatim,
            ProcessingMode::Clean => ProcessingProfile::Clean,
            ProcessingMode::Polished => ProcessingProfile::Polished,
        },
        &llm_api_key,
        &cfg.llm.model,
    ) {
        return Err(invalid(
            "polished mode requires Cerebras credentials and a supported planner model",
        ));
    }
    let mut value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    let root = value
        .as_object_mut()
        .ok_or_else(|| invalid("config root must be an object"))?;
    let processing = root
        .entry("processing")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or_else(|| invalid("processing must be an object"))?;
    processing.insert(
        "mode".into(),
        serde_json::to_value(mode).expect("processing mode serializes"),
    );
    let mut output = serde_json::to_vec_pretty(&value)
        .map_err(|_| invalid("configuration could not be encoded"))?;
    output.push(b'\n');
    if output.len() > CONFIG_MAX {
        return Err(invalid("config exceeds 1 MiB"));
    }
    Ok(output)
}

fn encode_output_method(bytes: &[u8], method: OutputMethod) -> io::Result<Vec<u8>> {
    let mut value: serde_json::Value =
        serde_json::from_slice(bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    let root = value
        .as_object_mut()
        .ok_or_else(|| invalid("config root must be an object"))?;
    let output = root
        .entry("output")
        .or_insert_with(|| serde_json::json!({}))
        .as_object_mut()
        .ok_or_else(|| invalid("output must be an object"))?;
    output.insert(
        "method".into(),
        serde_json::to_value(method).expect("output method serializes"),
    );
    let mut encoded = serde_json::to_vec_pretty(&value)
        .map_err(|_| invalid("configuration could not be encoded"))?;
    encoded.push(b'\n');
    if encoded.len() > CONFIG_MAX {
        return Err(invalid("config exceeds 1 MiB"));
    }
    Ok(encoded)
}

pub fn load() -> io::Result<SessionConfig> {
    let (parent, bytes) = read_secure_config()?;
    project_session_config(&bytes, &parent)
}

pub fn load_hud_appearance() -> io::Result<Appearance> {
    let (_, bytes) = read_secure_config()?;
    let config: Config =
        serde_json::from_slice(&bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    Ok(Appearance::resolve(config.hud.theme, config.hud.shape))
}

fn project_session_config(bytes: &[u8], parent: &Path) -> io::Result<SessionConfig> {
    let mut cfg: Config =
        serde_json::from_slice(bytes).map_err(|e| invalid(&format!("invalid config: {e}")))?;
    migrate_legacy_llm(&mut cfg.llm);
    validate(&cfg.recording)?;
    let processing_profile =
        effective_processing_profile(cfg.processing.mode, cfg.llm.enabled.unwrap_or(false));
    let deepgram_api_key = resolve_secret(cfg.stt.api_key, "DEEPGRAM_API_KEY");
    let llm_api_key = resolve_secret(cfg.llm.api_key, "CEREBRAS_API_KEY");
    let model = cfg.stt.model;
    let language = cfg.stt.language;
    let region = cfg.stt.region;
    let llm_model = cfg.llm.model;
    let base = cfg.llm.base_url;
    let keyterms = load_keywords(parent, cfg.stt.keyterms)?;
    let method = parse_output_method(&cfg.output.method)?;
    if deepgram_api_key.is_empty()
        || !safe_secret(&deepgram_api_key)
        || !safe_secret(&llm_api_key)
        || cfg.stt.provider != "deepgram"
        || cfg.llm.provider != "cerebras"
        || !safe_value(&model)
        || !safe_value(&language)
        || !safe_llm_model(&llm_model)
        || !valid_processing_credentials(processing_profile, &llm_api_key, &llm_model)
        || !["global", "eu", "au"].contains(&region.as_str())
        || base != "https://api.cerebras.ai/v1/chat/completions"
        || cfg.stt.dictation && !cfg.stt.punctuate
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
        show_timer: cfg.hud.show_timer,
        notifications: cfg.notifications,
        provider: ProviderConfig {
            deepgram_api_key,
            deepgram_model: model,
            deepgram_language: language,
            deepgram_region: region,
            keyterms,
            smart_format: cfg.stt.smart_format,
            punctuate: cfg.stt.punctuate,
            dictation: cfg.stt.dictation,
            numerals: cfg.stt.numerals,
            measurements: cfg.stt.measurements,
            streaming: cfg.stt.streaming.unwrap_or(true),
            finalize_ms: finalize,
            llm_api_key,
            llm_model,
            llm_base_url: base,
            processing_profile,
        },
    })
}

fn valid_processing_credentials(
    profile: ProcessingProfile,
    llm_api_key: &str,
    llm_model: &str,
) -> bool {
    match profile {
        ProcessingProfile::Polished => llm_model == "gpt-oss-120b" && !llm_api_key.is_empty(),
        ProcessingProfile::LegacyV1 => llm_model == "gpt-oss-120b",
        ProcessingProfile::Verbatim | ProcessingProfile::Clean => true,
    }
}

fn migrate_legacy_llm(llm: &mut Llm) {
    if llm.provider == "groq" || llm.base_url == "https://api.groq.com/openai/v1/chat/completions" {
        llm.provider = "cerebras".into();
        llm.api_key = "$CEREBRAS_API_KEY".into();
        llm.model = "gpt-oss-120b".into();
        llm.base_url = "https://api.cerebras.ai/v1/chat/completions".into();
    }
}

fn open_secure_parent() -> io::Result<(File, PathBuf)> {
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
    let parent_path = root.join("sayall");
    let parent = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&parent_path)
        .map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                invalid("configuration missing")
            } else {
                error
            }
        })?;
    let meta = parent.metadata()?;
    if !meta.file_type().is_dir()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
    {
        return Err(invalid(
            "config parent must be a private user-owned directory",
        ));
    }
    Ok((parent, parent_path))
}

fn read_secure_config() -> io::Result<(PathBuf, Vec<u8>)> {
    let (parent, parent_path) = open_secure_parent()?;
    Ok((parent_path, read_config_at(&parent)?.bytes))
}

struct ConfigSource {
    device: u64,
    inode: u64,
    bytes: Vec<u8>,
}

fn read_config_at(parent: &File) -> io::Result<ConfigSource> {
    let mut file = match openat_file(
        parent,
        CONFIG_NAME,
        libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        0,
    ) {
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
    if meta.len() > CONFIG_MAX as u64 {
        return Err(invalid("config exceeds 1 MiB"));
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file)
        .take(CONFIG_MAX as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > CONFIG_MAX {
        return Err(invalid("config exceeds 1 MiB"));
    }
    Ok(ConfigSource {
        device: meta.dev(),
        inode: meta.ino(),
        bytes,
    })
}

fn ensure_source_unchanged(parent: &File, expected: &ConfigSource) -> io::Result<()> {
    let current = read_config_at(parent)?;
    if current.device != expected.device
        || current.inode != expected.inode
        || current.bytes != expected.bytes
    {
        return Err(invalid("configuration changed concurrently"));
    }
    Ok(())
}

fn lock_config(parent: &File) -> io::Result<File> {
    let lock = openat_file(
        parent,
        LOCK_NAME,
        libc::O_RDWR | libc::O_CREAT | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        0o600,
    )?;
    let meta = lock.metadata()?;
    if !meta.file_type().is_file()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
        || meta.nlink() != 1
    {
        return Err(invalid("invalid configuration lock"));
    }
    loop {
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == 0 {
            return Ok(lock);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn openat_file(parent: &File, name: &str, flags: i32, mode: u32) -> io::Result<File> {
    let name = CString::new(name).map_err(|_| invalid("invalid configuration filename"))?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags,
            mode as libc::c_uint,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { File::from_raw_fd(fd) })
    }
}

fn renameat(parent: &File, from: &str, to: &str) -> io::Result<()> {
    let from = CString::new(from).map_err(|_| invalid("invalid configuration filename"))?;
    let to = CString::new(to).map_err(|_| invalid("invalid configuration filename"))?;
    if unsafe {
        libc::renameat(
            parent.as_raw_fd(),
            from.as_ptr(),
            parent.as_raw_fd(),
            to.as_ptr(),
        )
    } == 0
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn unlinkat(parent: &File, name: &str) -> io::Result<()> {
    let name = CString::new(name).map_err(|_| invalid("invalid configuration filename"))?;
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
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
fn safe_llm_model(v: &str) -> bool {
    v.len() <= 64
        && match v.split('/').collect::<Vec<_>>().as_slice() {
            [one] => safe_value(one),
            [namespace, model] => safe_value(namespace) && safe_value(model),
            _ => false,
        }
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
    use std::fs;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::mpsc;

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct ConfigDir(PathBuf);
    impl ConfigDir {
        fn new(contents: &[u8]) -> Self {
            let path = std::env::temp_dir().join(format!(
                "sayall-config-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
            fs::write(path.join(CONFIG_NAME), contents).unwrap();
            fs::set_permissions(path.join(CONFIG_NAME), fs::Permissions::from_mode(0o600)).unwrap();
            Self(path)
        }

        fn open(&self) -> File {
            OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&self.0)
                .unwrap()
        }
    }
    impl Drop for ConfigDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

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
            r#"{"stt":{"provider":"deepgram"},"llm":{"enabled":true},"recording":{"max_seconds":5,"min_ms":200,"source":"node"},"output":{"method":"type"},"hud":{"show_timer":false,"theme":"gruvbox","shape":"square"}}"#,
        )
        .unwrap();
        assert_eq!(cfg.recording.max_seconds, 5);
        assert_eq!(cfg.recording.min_ms, 200);
        assert_eq!(cfg.recording.source, "node");
        assert_eq!(cfg.output.method, "type");
        assert!(cfg.output.trailing_space);
        assert!(!cfg.hud.show_timer);
        assert_eq!(cfg.hud.theme, Theme::Gruvbox);
        assert_eq!(cfg.hud.shape, Shape::Square);
    }

    #[test]
    fn processing_profile_migration_and_explicit_precedence_match_contract() {
        assert_eq!(
            effective_processing_profile(None, false),
            ProcessingProfile::Verbatim
        );
        assert_eq!(
            effective_processing_profile(None, true),
            ProcessingProfile::LegacyV1
        );
        assert_eq!(
            effective_processing_profile(Some(ProcessingMode::Verbatim), true),
            ProcessingProfile::Verbatim
        );
        assert_eq!(
            effective_processing_profile(Some(ProcessingMode::Clean), true),
            ProcessingProfile::Clean
        );
        assert_eq!(
            effective_processing_profile(Some(ProcessingMode::Polished), false),
            ProcessingProfile::Polished
        );
    }

    #[test]
    fn processing_mode_rejects_private_legacy_profile() {
        let explicit: Config =
            serde_json::from_str(r#"{"processing":{"mode":"polished"},"llm":{"enabled":true}}"#)
                .unwrap();
        assert_eq!(explicit.processing.mode, Some(ProcessingMode::Polished));
        assert!(serde_json::from_str::<Config>(r#"{"processing":{"mode":"legacy_v1"}}"#).is_err());
        assert!(serde_json::from_str::<Config>(r#"{"processing":{"mode":"ai_only"}}"#).is_err());
    }

    #[test]
    fn planner_profiles_require_the_supported_model_and_polished_requires_credentials() {
        assert!(valid_processing_credentials(
            ProcessingProfile::Polished,
            "secret",
            "gpt-oss-120b"
        ));
        assert!(!valid_processing_credentials(
            ProcessingProfile::Polished,
            "",
            "gpt-oss-120b"
        ));
        assert!(!valid_processing_credentials(
            ProcessingProfile::Polished,
            "secret",
            "other/model"
        ));
        assert!(!valid_processing_credentials(
            ProcessingProfile::LegacyV1,
            "",
            "other/model"
        ));
        assert!(valid_processing_credentials(
            ProcessingProfile::LegacyV1,
            "",
            "gpt-oss-120b"
        ));
    }

    #[test]
    fn legacy_cloud_metadata_migrates_without_reusing_its_credential() {
        let mut llm = Llm {
            provider: "groq".into(),
            api_key: "legacy-secret".into(),
            model: "openai/gpt-oss-20b".into(),
            base_url: "https://api.groq.com/openai/v1/chat/completions".into(),
            enabled: Some(true),
        };
        migrate_legacy_llm(&mut llm);
        assert_eq!(llm.provider, "cerebras");
        assert_eq!(llm.api_key, "$CEREBRAS_API_KEY");
        assert_eq!(llm.model, "gpt-oss-120b");
        assert_eq!(llm.base_url, "https://api.cerebras.ai/v1/chat/completions");
    }

    #[test]
    fn mode_mutation_rejects_present_non_object_processing() {
        assert!(encode_processing_mode(br#"{"processing":false}"#, ProcessingMode::Clean).is_err());
    }

    #[test]
    fn mode_mutation_validates_polished_before_publication_and_allows_recovery() {
        let fixture = ConfigDir::new(
            br#"{"stt":{"api_key":"deepgram"},"processing":{"mode":"clean"},"llm":{"model":"other/model"}}"#,
        );
        assert!(
            set_processing_mode_at(
                &fixture.open(),
                &fixture.0,
                ProcessingMode::Polished,
                || {},
                || {}
            )
            .is_err()
        );
        let unchanged: serde_json::Value =
            serde_json::from_slice(&fs::read(fixture.0.join(CONFIG_NAME)).unwrap()).unwrap();
        assert_eq!(unchanged["processing"]["mode"], "clean");

        fs::write(
            fixture.0.join(CONFIG_NAME),
            br#"{"stt":{"api_key":"deepgram"},"processing":{"mode":"polished"},"llm":{"model":"other/model"}}"#,
        )
        .unwrap();
        set_processing_mode_at(
            &fixture.open(),
            &fixture.0,
            ProcessingMode::Verbatim,
            || {},
            || {},
        )
        .unwrap();
        let recovered: serde_json::Value =
            serde_json::from_slice(&fs::read(fixture.0.join(CONFIG_NAME)).unwrap()).unwrap();
        assert_eq!(recovered["processing"]["mode"], "verbatim");
    }

    #[test]
    fn mode_mutation_rejects_same_inode_byte_changes() {
        let fixture = ConfigDir::new(br#"{"stt":{"api_key":"deepgram"}}"#);
        let path = fixture.0.join(CONFIG_NAME);
        let result = set_processing_mode_at(
            &fixture.open(),
            &fixture.0,
            ProcessingMode::Clean,
            || {},
            || fs::write(&path, b"{\"notifications\":false}").unwrap(),
        );
        assert!(result.is_err());
        assert_eq!(fs::read(&path).unwrap(), b"{\"notifications\":false}");
    }

    #[test]
    fn concurrent_sayall_writer_is_not_overwritten() {
        let fixture = ConfigDir::new(br#"{"stt":{"api_key":"deepgram"}}"#);
        let first_parent = fixture.open();
        let second_parent = fixture.open();
        let first_path = fixture.0.clone();
        let second_path = fixture.0.clone();
        let (locked_tx, locked_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let first = std::thread::spawn(move || {
            set_processing_mode_at(
                &first_parent,
                &first_path,
                ProcessingMode::Clean,
                || {},
                || {
                    locked_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                },
            )
        });
        locked_rx.recv().unwrap();

        let (read_tx, read_rx) = mpsc::channel();
        let second = std::thread::spawn(move || {
            set_processing_mode_at(
                &second_parent,
                &second_path,
                ProcessingMode::Polished,
                || read_tx.send(()).unwrap(),
                || {},
            )
        });
        read_rx.recv().unwrap();
        release_tx.send(()).unwrap();

        first.join().unwrap().unwrap();
        assert!(second.join().unwrap().is_err());
        let value: serde_json::Value =
            serde_json::from_slice(&fs::read(fixture.0.join(CONFIG_NAME)).unwrap()).unwrap();
        assert_eq!(value["processing"]["mode"], "clean");
    }

    #[test]
    fn provider_defaults_apply_only_to_omitted_fields() {
        let omitted: Config = serde_json::from_str("{}").unwrap();
        assert_eq!(omitted.stt.model, "nova-3");
        assert!(!omitted.stt.smart_format);
        assert!(!omitted.stt.punctuate);
        assert!(!omitted.stt.dictation);
        assert!(!omitted.stt.numerals);
        assert!(!omitted.stt.measurements);
        assert_eq!(omitted.llm.provider, "cerebras");
        assert_eq!(omitted.llm.enabled, Some(false));
        assert!(omitted.hud.show_timer);
        assert_eq!(omitted.hud.theme, Theme::Omarchy);
        assert_eq!(omitted.hud.shape, Shape::Rounded);
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
    fn llm_model_accepts_one_optional_namespace() {
        assert!(safe_llm_model("gpt-oss-120b"));
        for invalid in ["/openai", "openai/", "a/b/c"] {
            assert!(!safe_llm_model(invalid));
        }
        assert!(!safe_llm_model(&"a".repeat(65)));
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
    fn output_method_mutation_preserves_credentials_and_other_output_settings() {
        let encoded = encode_output_method(
            br#"{"stt":{"api_key":"deepgram-secret"},"llm":{"api_key":"cerebras-secret"},"output":{"method":"type","trailing_space":false},"notifications":false}"#,
            OutputMethod::Paste,
        )
        .unwrap();
        let value: serde_json::Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(value["output"]["method"], "paste");
        assert_eq!(value["output"]["trailing_space"], false);
        assert_eq!(value["stt"]["api_key"], "deepgram-secret");
        assert_eq!(value["llm"]["api_key"], "cerebras-secret");
        assert_eq!(value["notifications"], false);
    }

    #[test]
    fn output_method_mutation_rejects_present_non_object_output() {
        assert!(encode_output_method(br#"{"output":false}"#, OutputMethod::Paste).is_err());
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
