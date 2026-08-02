use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub struct Ownership {
    pub socket: PathBuf,
    _lock: File,
}

impl Ownership {
    pub fn acquire(socket: PathBuf) -> io::Result<Self> {
        super::validate_socket_path(&socket)?;
        validate_parent(socket.parent().unwrap())?;
        let mut lock_name: OsString = socket.as_os_str().to_owned();
        lock_name.push(".lock");
        let lock_path = PathBuf::from(lock_name);
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path)?;
        let meta = lock.metadata()?;
        if !meta.file_type().is_file()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & 0o077 != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unsafe endpoint lock",
            ));
        }
        let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc != 0 {
            return Err(io::Error::new(
                io::ErrorKind::AddrInUse,
                "another SayAll owner holds the public endpoint lock",
            ));
        }
        if let Ok(meta) = fs::symlink_metadata(&socket) {
            if !meta.file_type().is_socket() || meta.uid() != unsafe { libc::geteuid() } {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "unsafe stale public endpoint",
                ));
            }
            fs::remove_file(&socket)?;
        }
        Ok(Self {
            socket,
            _lock: lock,
        })
    }
}

fn validate_parent(path: &Path) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.file_type().is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "unsafe endpoint parent",
        ));
    }
    if path == Path::new("/tmp") {
        if meta.uid() != 0 || meta.mode() & 0o1777 != 0o1777 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unsafe /tmp",
            ));
        }
    } else if meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "runtime directory is not private",
        ));
    }
    Ok(())
}

impl Drop for Ownership {
    fn drop(&mut self) {
        if let Ok(meta) = fs::symlink_metadata(&self.socket)
            && meta.file_type().is_socket()
            && meta.uid() == unsafe { libc::geteuid() }
        {
            let _ = fs::remove_file(&self.socket);
        }
    }
}

pub fn session_root() -> io::Result<PathBuf> {
    let base = if let Some(value) = std::env::var_os("XDG_RUNTIME_DIR") {
        let path = PathBuf::from(value);
        if !path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "XDG_RUNTIME_DIR is not absolute",
            ));
        }
        validate_parent(&path)?;
        path
    } else {
        PathBuf::from("/tmp")
    };
    let root = base.join(format!("sayall-native-{}", unsafe { libc::geteuid() }));
    if root.exists() {
        let meta = fs::symlink_metadata(&root)?;
        if !meta.file_type().is_dir() || meta.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unsafe session root",
            ));
        }
        if meta.mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unsafe session root mode",
            ));
        }
        fs::remove_dir_all(&root)?;
    }
    fs::DirBuilder::new().mode(0o700).create(&root)?;
    Ok(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn private_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "sayall-rust-test-{}-{}-{name}",
            std::process::id(),
            std::thread::current().name().unwrap_or("thread")
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    #[test]
    fn endpoint_lock_is_mutually_exclusive() {
        let dir = private_dir("lock");
        let socket = dir.join("sayall.sock");
        let owner = Ownership::acquire(socket.clone()).unwrap();
        let error = match Ownership::acquire(socket) {
            Ok(_) => panic!("second owner acquired the endpoint lock"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::AddrInUse);
        drop(owner);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn never_removes_non_socket_stale_endpoint() {
        let dir = private_dir("stale");
        let socket = dir.join("sayall.sock");
        fs::File::create(&socket)
            .unwrap()
            .write_all(b"keep")
            .unwrap();
        assert!(Ownership::acquire(socket.clone()).is_err());
        assert_eq!(fs::read(socket).unwrap(), b"keep");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn system_tmp_uses_shared_sticky_policy() {
        validate_parent(Path::new("/tmp")).unwrap();
    }
}
