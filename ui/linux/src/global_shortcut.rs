use crate::session;
use ashpd::desktop::CreateSessionOptions;
use ashpd::desktop::global_shortcuts::{
    BindShortcutsOptions, GlobalShortcuts, NewShortcut, Shortcut,
};
use futures_lite::{StreamExt, future};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const SHORTCUT_ID: &str = "toggle-transcription";
const APP_ID: &str = "dev.sayall.Hud";
const OP_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const CONSENT: &[u8] = b"sayall-global-shortcut-consent-v1\n";
static NONCE: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    Disabled,
    NeedsSetup,
    Initializing,
    Active,
    Unavailable,
    Failed,
}

impl Status {
    pub fn message(self) -> &'static str {
        match self {
            Self::Disabled => "Global shortcut: disabled. Enable it below to choose a shortcut.",
            Self::NeedsSetup => "Global shortcut: setup is required in this interactive session.",
            Self::Initializing => "Global shortcut: requesting desktop approval…",
            Self::Active => "Global shortcut: active.",
            Self::Unavailable => {
                "Global shortcut: unavailable. Use a desktop shortcut or the Hyprland setup."
            }
            Self::Failed => {
                "Global shortcut: not active. Try setup again or use the Hyprland setup."
            }
        }
    }
}

enum Command {
    Enable,
    Shutdown,
}

pub struct Host {
    status: Arc<Mutex<Status>>,
    command: async_channel::Sender<Command>,
    join: Option<JoinHandle<()>>,
}

impl Host {
    pub fn spawn(controller: session::Controller) -> Self {
        // Restoration is deliberately deferred: ashpd cannot promise that BindShortcuts is
        // prompt-free, even if the portal remembered a previous grant.
        let initial = if consent_present() {
            Status::NeedsSetup
        } else {
            Status::Disabled
        };
        let status = Arc::new(Mutex::new(initial));
        let (command, rx) = async_channel::unbounded();
        let worker_status = status.clone();
        let join = thread::spawn(move || async_io::block_on(run(controller, worker_status, rx)));
        Self {
            status,
            command,
            join: Some(join),
        }
    }

    pub fn status(&self) -> Status {
        *self.status.lock().unwrap()
    }
    pub fn enable(&self) {
        if !matches!(self.status(), Status::Initializing | Status::Active) {
            let _ = self.command.try_send(Command::Enable);
        }
    }
    pub fn request_stop(&self) {
        let _ = self.command.try_send(Command::Shutdown);
    }

    pub fn shutdown_and_join(&mut self) {
        self.request_stop();
        if let Some(join) = self.join.take() {
            let deadline = Instant::now() + Duration::from_secs(2);
            while !join.is_finished() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            if join.is_finished() {
                let _ = join.join();
            } // otherwise detach; shutdown must be bounded
        }
    }
}

enum Bounded<T> {
    Done(T),
    Stopped,
    TimedOut,
}

async fn bounded_or_shutdown<T>(
    rx: &async_channel::Receiver<Command>,
    operation: impl std::future::Future<Output = T>,
) -> Bounded<T> {
    future::race(async { Bounded::Done(operation.await) }, async {
        future::race(
            async {
                wait_for_shutdown(rx).await;
                Bounded::Stopped
            },
            async {
                async_io::Timer::after(OP_TIMEOUT).await;
                Bounded::TimedOut
            },
        )
        .await
    })
    .await
}

async fn wait_for_shutdown(rx: &async_channel::Receiver<Command>) {
    while let Ok(command) = rx.recv().await {
        if matches!(command, Command::Shutdown) {
            return;
        }
    }
}

async fn run(
    controller: session::Controller,
    status: Arc<Mutex<Status>>,
    rx: async_channel::Receiver<Command>,
) {
    while let Ok(command) = rx.recv().await {
        if matches!(command, Command::Shutdown) {
            return;
        }
        set_status(&status, Status::Initializing);
        match register(&controller, &status, &rx).await {
            Ok(()) => {}
            Err(RegisterError::Failed) => {
                if status.lock().unwrap().eq(&Status::Initializing) {
                    set_status(&status, Status::Failed);
                }
            }
            Err(RegisterError::Stopped) => return,
        }
    }
}

enum RegisterError {
    Failed,
    Stopped,
}

async fn register(
    controller: &session::Controller,
    status: &Mutex<Status>,
    rx: &async_channel::Receiver<Command>,
) -> Result<(), RegisterError> {
    let setup = async {
        let connection = ashpd::zbus::Connection::session().await.map_err(|_| ())?;
        let app_id = ashpd::AppID::try_from(APP_ID).map_err(|_| ())?;
        ashpd::register_host_app_with_connection(connection.clone(), app_id)
            .await
            .map_err(|_| ())?;
        let portal = GlobalShortcuts::with_connection(connection.clone())
            .await
            .map_err(|_| ())?;
        if portal.version() < 1 {
            set_status(status, Status::Unavailable);
            return Err(());
        }
        let activated = portal.receive_activated().await.map_err(|_| ())?;
        let changed = portal.receive_shortcuts_changed().await.map_err(|_| ())?;
        let session = portal
            .create_session(CreateSessionOptions::default())
            .await
            .map_err(|_| ())?;
        Ok((connection, portal, activated, changed, session))
    };
    let (connection, portal, mut activated, mut changed, session) =
        match bounded_or_shutdown(rx, setup).await {
            Bounded::Done(Ok(value)) => value,
            Bounded::Done(Err(())) | Bounded::TimedOut => return Err(RegisterError::Failed),
            Bounded::Stopped => return Err(RegisterError::Stopped),
        };
    let mut closed = match bounded_or_shutdown(rx, session.receive_closed()).await {
        Bounded::Done(Ok(stream)) => stream,
        Bounded::Done(Err(_)) | Bounded::TimedOut => {
            close_bounded(&session).await;
            return Err(RegisterError::Failed);
        }
        Bounded::Stopped => {
            close_bounded(&session).await;
            return Err(RegisterError::Stopped);
        }
    };

    let shortcut =
        NewShortcut::new(SHORTCUT_ID, "Toggle transcription").preferred_trigger("<Control>slash");
    let response = match bounded_or_shutdown(
        rx,
        portal.bind_shortcuts(&session, &[shortcut], None, BindShortcutsOptions::default()),
    )
    .await
    {
        Bounded::Done(Ok(request)) => match request.response() {
            Ok(response) => response,
            Err(_) => {
                close_bounded(&session).await;
                return Err(RegisterError::Failed);
            }
        },
        Bounded::Done(Err(_)) | Bounded::TimedOut => {
            close_bounded(&session).await;
            return Err(RegisterError::Failed);
        }
        Bounded::Stopped => {
            close_bounded(&session).await;
            return Err(RegisterError::Stopped);
        }
    };
    if !accepted(response.shortcuts()) || persist_consent().is_err() {
        close_bounded(&session).await;
        return Err(RegisterError::Failed);
    }
    let session_path = match serde_json::to_value(&session)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
    {
        Some(path) => path,
        None => {
            close_bounded(&session).await;
            return Err(RegisterError::Failed);
        }
    };
    set_status(status, Status::Active);
    loop {
        enum Event<A, C> {
            Activation(Option<A>),
            Changed(Option<C>),
            Closed,
            Command(Option<Command>),
        }
        let event = future::race(
            future::race(async { Event::Activation(activated.next().await) }, async {
                Event::Changed(changed.next().await)
            }),
            future::race(
                async {
                    let _ = closed.next().await;
                    Event::Closed
                },
                async { Event::Command(rx.recv().await.ok()) },
            ),
        )
        .await;
        match event {
            Event::Activation(Some(event))
                if activation_matches(
                    event.session_handle().as_str(),
                    event.shortcut_id(),
                    &session_path,
                ) =>
            {
                let c = controller.clone();
                thread::spawn(move || {
                    let _ = c.toggle();
                });
            }
            Event::Changed(Some(event)) if event.session_handle().as_str() == session_path => {
                if !accepted(event.shortcuts()) {
                    set_status(status, Status::NeedsSetup);
                    break;
                }
            }
            Event::Command(Some(Command::Enable)) => continue,
            Event::Activation(None) | Event::Changed(None) | Event::Closed => {
                set_status(status, Status::NeedsSetup);
                break;
            }
            Event::Command(Some(Command::Shutdown) | None) => {
                close_bounded(&session).await;
                drop(portal);
                drop(connection);
                return Err(RegisterError::Stopped);
            }
            _ => {}
        }
    }
    close_bounded(&session).await;
    Ok(())
}

async fn close_bounded(session: &ashpd::desktop::Session<GlobalShortcuts>) {
    let _ = future::race(async { session.close().await.ok() }, async {
        async_io::Timer::after(Duration::from_secs(1)).await;
        None
    })
    .await;
}

fn accepted(shortcuts: &[Shortcut]) -> bool {
    accepted_ids(shortcuts.iter().map(Shortcut::id))
}
fn accepted_ids<'a>(ids: impl IntoIterator<Item = &'a str>) -> bool {
    ids.into_iter().any(|id| id == SHORTCUT_ID)
}
fn set_status(status: &Mutex<Status>, next: Status) {
    *status.lock().unwrap() = next;
}
fn activation_matches(session: &str, shortcut: &str, expected: &str) -> bool {
    session == expected && shortcut == SHORTCUT_ID
}

fn consent_path() -> io::Result<PathBuf> {
    let root = std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .ok_or_else(|| io::Error::other("no state directory"))?;
    if !root.is_absolute() {
        return Err(io::Error::other("state directory is not absolute"));
    }
    Ok(root.join("sayall/global-shortcut-consent-v1"))
}
fn safe_metadata(path: &std::path::Path, directory: bool) -> io::Result<bool> {
    let m = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(e),
    };
    let kind_ok = if directory { m.is_dir() } else { m.is_file() };
    Ok(kind_ok && m.uid() == unsafe { libc::geteuid() } && m.mode() & 0o077 == 0)
}
fn consent_present() -> bool {
    let Ok(path) = consent_path() else {
        return false;
    };
    if !safe_metadata(&path, false).unwrap_or(false) {
        return false;
    }
    let Ok(mut file) = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
    else {
        return false;
    };
    let mut value = Vec::new();
    Read::by_ref(&mut file)
        .take((CONSENT.len() + 1) as u64)
        .read_to_end(&mut value)
        .is_ok()
        && value == CONSENT
}
fn persist_consent() -> io::Result<()> {
    let path = consent_path()?;
    let dir = path.parent().unwrap();
    let state = dir.parent().and_then(std::path::Path::parent).unwrap();
    fs::create_dir_all(state)?;
    for private in [state.join("sayall"), dir.to_path_buf()] {
        match fs::DirBuilder::new().mode(0o700).create(&private) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(e),
        }
        if !safe_metadata(&private, true)? {
            return Err(io::Error::other("unsafe state directory"));
        }
    }
    if consent_present() {
        return Ok(());
    }
    if fs::symlink_metadata(&path).is_ok() {
        return Err(io::Error::other("invalid consent marker"));
    }
    let temp = dir.join(format!(
        ".consent-{}-{}",
        std::process::id(),
        NONCE.fetch_add(1, Ordering::Relaxed)
    ));
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&temp)?;
    f.write_all(CONSENT)?;
    f.sync_all()?;
    drop(f);
    rename_noreplace(&temp, &path)
}

fn rename_noreplace(from: &std::path::Path, to: &std::path::Path) -> io::Result<()> {
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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn filters_activation_by_session_and_id() {
        assert!(activation_matches("/s/1", SHORTCUT_ID, "/s/1"));
        assert!(!activation_matches("/s/2", SHORTCUT_ID, "/s/1"));
        assert!(!activation_matches("/s/1", "other", "/s/1"));
    }
    #[test]
    fn active_message_does_not_claim_trigger() {
        assert_eq!(Status::Active.message(), "Global shortcut: active.");
    }
    #[test]
    fn accepted_response_requires_toggle_id() {
        assert!(accepted_ids(["other", SHORTCUT_ID]));
        assert!(!accepted_ids(["other"]));
        assert!(!accepted_ids(std::iter::empty()));
    }
    #[test]
    fn statuses_hide_transport_details() {
        for s in [
            Status::Disabled,
            Status::NeedsSetup,
            Status::Initializing,
            Status::Active,
            Status::Unavailable,
            Status::Failed,
        ] {
            assert!(!s.message().contains("D-Bus"));
            assert!(!s.message().contains("/org/"));
        }
    }
}
