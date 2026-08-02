use crate::session::{Controller, Snapshot, State};
use serde::Serialize;
use serde_json::Value;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
#[cfg(target_os = "linux")]
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

const MAX: usize = 64 * 1024;
#[derive(Serialize)]
struct ErrorBody {
    code: String,
    message: String,
}
#[derive(Serialize)]
struct Response {
    version: u32,
    ok: bool,
    state: State,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorBody>,
}

pub struct Server {
    stop: Arc<AtomicBool>,
    join: Option<JoinHandle<io::Result<()>>>,
}
impl Server {
    pub fn bind(path: &Path, controller: Controller) -> io::Result<Self> {
        let old_umask = unsafe { libc::umask(0o077) };
        let listener_result = UnixListener::bind(path);
        unsafe { libc::umask(old_umask) };
        let listener = listener_result?;
        if let Err(e) = fs::set_permissions(path, fs::Permissions::from_mode(0o600)) {
            let _ = fs::remove_file(path);
            return Err(e);
        }
        let meta = fs::symlink_metadata(path)?;
        if !meta.file_type().is_socket()
            || meta.uid() != unsafe { libc::geteuid() }
            || meta.mode() & 0o077 != 0
        {
            let _ = fs::remove_file(path);
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "unsafe public control socket",
            ));
        }
        listener.set_nonblocking(true)?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let join = std::thread::spawn(move || {
            let mut connections: Vec<JoinHandle<()>> = Vec::new();
            loop {
                if stopped.load(Ordering::Acquire) {
                    for connection in connections {
                        let _ = connection.join();
                    }
                    return Ok(());
                }
                match listener.accept() {
                    Ok((stream, _)) => {
                        if peer_uid(&stream).is_err() {
                            continue;
                        }
                        let c = controller.clone();
                        connections.push(std::thread::spawn(move || {
                            let _ = exchange(stream, &c);
                        }));
                    }
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(20))
                    }
                    Err(e) => return Err(e),
                }
                let mut index = 0;
                while index < connections.len() {
                    if connections[index].is_finished() {
                        let finished = connections.swap_remove(index);
                        let _ = finished.join();
                    } else {
                        index += 1;
                    }
                }
            }
        });
        Ok(Self {
            stop,
            join: Some(join),
        })
    }
    pub fn shutdown_and_join(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(j) = self.join.take() {
            let _ = j.join();
        }
    }
}
fn exchange(mut stream: UnixStream, c: &Controller) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let request = match read_frame(&mut stream) {
        Ok(frame) => decode(&frame),
        Err(e) => Err(e.to_string()),
    };
    let response = match request {
        Ok((version, _)) if version != 2 => error(
            c.status(),
            "incompatible_version",
            "unsupported host control version",
        ),
        Ok((_, method)) if method == "status" => success(c.status()),
        Ok((_, method)) if method == "toggle" => match c.toggle() {
            Ok(s) => success(s),
            Err(crate::session::ToggleError::Busy) => {
                error(c.status(), "busy", "SayAll is processing")
            }
            Err(crate::session::ToggleError::Failed(e)) => error(c.status(), "failed", &e),
            Err(crate::session::ToggleError::Unavailable) => {
                error(c.status(), "unavailable", "host unavailable")
            }
        },
        Ok(_) => error(c.status(), "invalid_request", "unsupported method"),
        Err(e) => error(c.status(), "invalid_request", &e),
    };
    serde_json::to_writer(&mut stream, &response).map_err(io::Error::other)?;
    stream.write_all(b"\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixtures_and_additive_fields_decode() {
        for fixture in [
            include_bytes!("../../../tests/contracts-0.2/host-status-request.json").as_slice(),
            include_bytes!("../../../tests/contracts-0.2/host-toggle-request.json").as_slice(),
        ] {
            assert_eq!(decode(fixture).unwrap().0, 2);
        }
        assert_eq!(
            decode(br#"{"version":2,"method":"status","future":true}"#)
                .unwrap()
                .1,
            "status"
        );
    }

    #[test]
    fn malformed_and_closed_request_values_fail() {
        assert!(decode(b"{}").is_err());
        assert!(decode(br#"{"version":"2","method":"status"}"#).is_err());
        assert!(reject_duplicates(br#"{"version":2,"version":2,"method":"status"}"#).is_err());
    }

    #[test]
    fn framing_rejects_unterminated_and_oversize() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        writer.write_all(b"{}").unwrap();
        writer.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(
            read_frame(&mut reader).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        let writer = std::thread::spawn(move || {
            writer.write_all(&vec![b'x'; MAX]).unwrap();
            writer.write_all(b"\n").unwrap();
        });
        assert_eq!(
            read_frame(&mut reader).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        writer.join().unwrap();
    }

    #[test]
    fn framing_accepts_largest_newline_inclusive_frame() {
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        let padding = "x".repeat(MAX - 9);
        let frame = format!(r#"{{"x":"{padding}"}}"#);
        assert_eq!(frame.len(), MAX - 1);
        let writer = std::thread::spawn(move || {
            writer.write_all(frame.as_bytes()).unwrap();
            writer.write_all(b"\n").unwrap();
        });
        assert_eq!(read_frame(&mut reader).unwrap().len(), MAX - 1);
        writer.join().unwrap();
    }

    #[test]
    fn peer_uid_accepts_same_uid_and_rejects_other_uid() {
        let (stream, _) = UnixStream::pair().unwrap();
        let uid = peer_uid(&stream).unwrap();
        assert!(uid_matches(uid, uid));
        assert!(!uid_matches(uid, uid.wrapping_add(1)));
    }

    #[test]
    fn generated_busy_response_matches_contract() {
        let mut snapshot = Snapshot::default();
        snapshot.state = State::Processing;
        let actual = serde_json::to_value(error(snapshot, "busy", "SayAll is processing")).unwrap();
        let expected: Value = serde_json::from_slice(include_bytes!(
            "../../../tests/contracts-0.2/host-busy-response.json"
        ))
        .unwrap();
        assert_eq!(actual, expected);
    }
}

#[cfg(target_os = "linux")]
fn peer_uid(stream: &UnixStream) -> io::Result<libc::uid_t> {
    let mut credentials = std::mem::MaybeUninit::<libc::ucred>::uninit();
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            credentials.as_mut_ptr().cast(),
            &mut length,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    if length as usize != std::mem::size_of::<libc::ucred>() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid control peer credentials",
        ));
    }
    let uid = unsafe { credentials.assume_init() }.uid;
    if !uid_matches(uid, unsafe { libc::geteuid() }) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "control peer belongs to another user",
        ));
    }
    Ok(uid)
}

#[cfg(not(target_os = "linux"))]
fn peer_uid(_: &UnixStream) -> io::Result<libc::uid_t> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "Linux peer credentials unavailable",
    ))
}

fn uid_matches(peer: libc::uid_t, effective: libc::uid_t) -> bool {
    peer == effective
}

fn decode(bytes: &[u8]) -> Result<(u32, String), String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    let object = value.as_object().ok_or("request must be an object")?;
    let version = object
        .get("version")
        .and_then(Value::as_u64)
        .ok_or("version must be an integer")?;
    let method = object
        .get("method")
        .and_then(Value::as_str)
        .ok_or("method must be a string")?;
    Ok((
        u32::try_from(version).map_err(|_| "invalid version")?,
        method.to_owned(),
    ))
}
fn read_frame(stream: &mut UnixStream) -> io::Result<Vec<u8>> {
    let mut reader = BufReader::new(stream);
    let mut b = Vec::new();
    let n = reader
        .by_ref()
        .take((MAX + 1) as u64)
        .read_until(b'\n', &mut b)?;
    if n == 0 || b.last() != Some(&b'\n') {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "unterminated request",
        ));
    }
    if n > MAX {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "request exceeds 64 KiB",
        ));
    }
    b.pop();
    reject_duplicates(&b)?;
    Ok(b)
}
fn reject_duplicates(bytes: &[u8]) -> io::Result<()> {
    struct V;
    impl<'de> serde::de::Visitor<'de> for V {
        type Value = ();
        fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
            write!(f, "object")
        }
        fn visit_map<A: serde::de::MapAccess<'de>>(self, mut a: A) -> Result<(), A::Error> {
            let mut keys = std::collections::HashSet::new();
            while let Some(k) = a.next_key::<String>()? {
                if !keys.insert(k) {
                    return Err(serde::de::Error::custom("duplicate key"));
                }
                let _: Value = a.next_value()?;
            }
            Ok(())
        }
    }
    let mut d = serde_json::Deserializer::from_slice(bytes);
    serde::de::Deserializer::deserialize_map(&mut d, V)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
}
fn success(s: Snapshot) -> Response {
    Response {
        version: 2,
        ok: true,
        state: s.state,
        error: None,
    }
}
fn error(s: Snapshot, code: &str, message: &str) -> Response {
    Response {
        version: 2,
        ok: false,
        state: s.state,
        error: Some(ErrorBody {
            code: code.to_owned(),
            message: message.to_owned(),
        }),
    }
}
