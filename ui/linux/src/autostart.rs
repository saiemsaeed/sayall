use crate::worker;
use std::ffi::OsString;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

const ENTRY: &str = "[Desktop Entry]\nType=Application\nName=SayAll Native Host Preview\nComment=Start the experimental SayAll native Linux host\nExec=/usr/bin/sayall-hud --native-host-preview --autostart\nTryExec=/usr/bin/sayall-hud\nTerminal=false\nX-GNOME-Autostart-enabled=true\n";
static NONCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Disabled,
    Enabled,
    Conflict,
}

fn path(root: &Path) -> PathBuf {
    root.join("autostart/sayall.desktop")
}

pub fn config_home() -> io::Result<PathBuf> {
    let root = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|p| PathBuf::from(p).join(".config")))
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "configuration home unavailable"))?;
    if !root.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "configuration home must be absolute",
        ));
    }
    Ok(root)
}

pub fn state(root: &Path) -> io::Result<State> {
    let p = path(root);
    match fs::symlink_metadata(&p) {
        Ok(_) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(State::Disabled),
        Err(e) => return Err(e),
    }
    validate_dir(root)?;
    validate_dir(&root.join("autostart"))?;
    Ok(if state_file(&p)? {
        State::Enabled
    } else {
        State::Conflict
    })
}

pub fn legacy_service_present() -> Result<bool, String> {
    let environment: Vec<(&str, OsString)> =
        ["HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]
            .into_iter()
            .filter_map(|key| std::env::var_os(key).map(|value| (key, value)))
            .collect();
    let refs: Vec<(&str, &std::ffi::OsStr)> = environment
        .iter()
        .map(|(key, value)| (*key, value.as_os_str()))
        .collect();
    for unit in ["sayall.service", "sayall-hud.service"] {
        for verb in ["is-active", "is-enabled"] {
            let output = worker::supervised(
                Path::new("/usr/bin/systemctl"),
                &["--user", verb, unit],
                &refs,
                Duration::from_secs(2),
            )?;
            let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            let safe = match verb {
                "is-active" => matches!(text.as_str(), "inactive" | "failed" | "unknown"),
                _ => matches!(text.as_str(), "disabled" | "not-found" | "masked"),
            };
            if output.status.success() {
                return Ok(true);
            }
            if !safe {
                return Err(format!(
                    "could not safely determine legacy state for {unit}"
                ));
            }
        }
    }
    Ok(false)
}

pub fn enable(root: &Path, legacy: bool) -> io::Result<()> {
    if legacy {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "disable the legacy sayall.service before enabling preview login start",
        ));
    }
    match state(root)? {
        State::Enabled => return Ok(()),
        State::Conflict => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "an unrelated sayall.desktop autostart entry already exists",
            ));
        }
        State::Disabled => {}
    }
    let dir = root.join("autostart");
    if !root.exists() {
        fs::DirBuilder::new().mode(0o700).create(root)?;
    }
    validate_dir(root)?;
    if !dir.exists() {
        fs::DirBuilder::new().mode(0o700).create(&dir)?;
    }
    validate_dir(&dir)?;
    let tmp = dir.join(format!(
        ".sayall.desktop.{}.{}.tmp",
        std::process::id(),
        NONCE.fetch_add(1, Ordering::Relaxed)
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    let result = (|| {
        file.write_all(ENTRY.as_bytes())?;
        file.sync_all()?;
        drop(file);
        rename_noreplace(&tmp, &path(root))
    })();
    result
}

#[cfg(target_os = "linux")]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let from = CString::new(from.as_os_str().as_bytes()).unwrap();
    let to = CString::new(to.as_os_str().as_bytes()).unwrap();
    let rc = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(not(target_os = "linux"))]
fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    if to.exists() {
        Err(io::ErrorKind::AlreadyExists.into())
    } else {
        fs::rename(from, to)
    }
}

pub fn disable(root: &Path) -> io::Result<()> {
    let parent = root.join("autostart");
    if parent.exists() {
        validate_dir(root)?;
        validate_dir(&parent)?;
    }
    match state(root)? {
        State::Disabled => Ok(()),
        State::Conflict => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "refusing to remove an unrelated autostart entry",
        )),
        State::Enabled => {
            let original = path(root);
            let quarantine = original.with_file_name(format!(
                ".sayall.desktop.{}.{}.quarantine",
                std::process::id(),
                NONCE.fetch_add(1, Ordering::Relaxed)
            ));
            rename_noreplace(&original, &quarantine)?;
            match state_file(&quarantine) {
                Ok(true) => Ok(()),
                _ => {
                    let _ = rename_noreplace(&quarantine, &original);
                    Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        "autostart entry changed while disabling; it was preserved",
                    ))
                }
            }
        }
    }
}

fn state_file(p: &Path) -> io::Result<bool> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(p)?;
    let meta = file.metadata()?;
    if !meta.file_type().is_file()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o077 != 0
        || meta.len() > 4096
    {
        return Ok(false);
    }
    let mut bytes = Vec::new();
    Read::by_ref(&mut file).take(4097).read_to_end(&mut bytes)?;
    Ok(bytes == ENTRY.as_bytes())
}

fn validate_dir(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.file_type().is_dir()
        || meta.uid() != unsafe { libc::geteuid() }
        || meta.mode() & 0o022 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "directory must be user-owned and not group/other writable",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temp() -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "sayall-autostart-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir(&p).unwrap();
        p
    }
    #[test]
    fn lifecycle_is_idempotent_and_exact() {
        let p = temp();
        assert_eq!(state(&p).unwrap(), State::Disabled);
        enable(&p, false).unwrap();
        enable(&p, false).unwrap();
        assert_eq!(fs::read_to_string(path(&p)).unwrap(), ENTRY);
        disable(&p).unwrap();
        disable(&p).unwrap();
        fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn conflicts_are_preserved() {
        let p = temp();
        fs::create_dir(p.join("autostart")).unwrap();
        fs::write(path(&p), "other").unwrap();
        assert_eq!(state(&p).unwrap(), State::Conflict);
        assert!(enable(&p, false).is_err());
        assert!(disable(&p).is_err());
        assert_eq!(fs::read_to_string(path(&p)).unwrap(), "other");
        fs::remove_dir_all(p).unwrap();
    }
    #[test]
    fn legacy_owner_blocks_enable() {
        let p = temp();
        assert!(enable(&p, true).is_err());
        assert_eq!(state(&p).unwrap(), State::Disabled);
        fs::remove_dir_all(p).unwrap();
    }
}
