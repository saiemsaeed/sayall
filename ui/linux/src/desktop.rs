use crate::config::{OutputConfig, OutputMethod};
use serde::Deserialize;
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const TIMEOUT: Duration = Duration::from_secs(8);
const NOTIFY_TIMEOUT: Duration = Duration::from_secs(2);
const HYPRLAND_TIMEOUT: Duration = Duration::from_secs(1);
const WTYPE: [&str; 2] = ["/usr/bin/wtype", "/bin/wtype"];
const WLCOPY: [&str; 2] = ["/usr/bin/wl-copy", "/bin/wl-copy"];
const WLPASTE: [&str; 2] = ["/usr/bin/wl-paste", "/bin/wl-paste"];
const XDOTOOL: [&str; 2] = ["/usr/bin/xdotool", "/bin/xdotool"];
const XSEL: [&str; 2] = ["/usr/bin/xsel", "/bin/xsel"];
const NOTIFY: [&str; 2] = ["/usr/bin/notify-send", "/bin/notify-send"];
const HYPRCTL: [&str; 2] = ["/usr/bin/hyprctl", "/bin/hyprctl"];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Backend {
    Wayland,
    X11,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DeliveryOutcome {
    Typed,
    Clipboard,
    Pasted,
    ClipboardFallback,
}

trait OwnedChild: Send {}

trait Runner: Send {
    fn run(&mut self, program: &[&str], args: &[&str], stdin: Option<&str>) -> io::Result<()>;
    fn start_clipboard(&mut self, backend: Backend, input: &str)
    -> io::Result<Box<dyn OwnedChild>>;
    fn paste(&mut self, backend: Backend) -> io::Result<()> {
        let (program, args) = paste_command(backend)?;
        self.run(program, args, None)
    }
}

fn paste_command(
    backend: Backend,
) -> io::Result<(&'static [&'static str], &'static [&'static str])> {
    match backend {
        Backend::Wayland => Ok((&WTYPE, &["-M", "ctrl", "-k", "v", "-m", "ctrl"])),
        Backend::X11 => Ok((&XDOTOOL, &["key", "--clearmodifiers", "ctrl+v"])),
        Backend::Unavailable => Err(io::Error::new(
            io::ErrorKind::NotFound,
            "no supported graphical session is available",
        )),
    }
}

struct Supervisor;
impl Runner for Supervisor {
    fn run(&mut self, programs: &[&str], args: &[&str], input: Option<&str>) -> io::Result<()> {
        let program = programs
            .iter()
            .map(PathBuf::from)
            .find(|p| p.is_file())
            .ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "required desktop tool unavailable")
            })?;
        supervise(&program, args, input, TIMEOUT)
    }

    fn start_clipboard(
        &mut self,
        backend: Backend,
        input: &str,
    ) -> io::Result<Box<dyn OwnedChild>> {
        let (programs, owner_args, verify_programs, verify_args): (
            &[&str],
            &[&str],
            &[&str],
            &[&str],
        ) = match backend {
            Backend::Wayland => (&WLCOPY, &["--foreground"], &WLPASTE, &["--no-newline"]),
            Backend::X11 => (
                &XSEL,
                &["--clipboard", "--input", "--nodetach"],
                &XSEL,
                &["--clipboard", "--output"],
            ),
            Backend::Unavailable => {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "no supported graphical session is available",
                ));
            }
        };
        let program = find_program(programs)?;
        let paste = find_program(verify_programs)?;
        let deadline = Instant::now() + TIMEOUT;
        let mut child = spawn(&program, owner_args, Some(input), deadline)?;
        let verified = verify_clipboard(
            input.as_bytes(),
            deadline,
            || owner_state(&mut child),
            || capture_bounded(&paste, verify_args, input.len() + 64, deadline),
        );
        match verified {
            Ok(true) => Ok(Box::new(ManagedChild(Some(child)))),
            Ok(false) => Ok(Box::new(ManagedChild(None))),
            Err(error) => {
                terminate(&mut child);
                Err(error)
            }
        }
    }

    fn paste(&mut self, backend: Backend) -> io::Result<()> {
        if backend == Backend::Wayland
            && let Some((hyprctl, target)) = hyprland_paste_target()?
        {
            let script = hyprland_paste_script(&target);
            return supervise(&hyprctl, &["eval", &script], None, HYPRLAND_TIMEOUT);
        }
        let (program, args) = paste_command(backend)?;
        self.run(program, args, None)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PasteChord {
    CtrlV,
    ShiftInsert,
}

struct HyprlandPasteTarget {
    address: String,
    chord: PasteChord,
}

#[derive(Deserialize)]
struct HyprlandActiveWindow {
    address: String,
    #[serde(default)]
    tags: Vec<String>,
}

fn hyprland_paste_target() -> io::Result<Option<(PathBuf, HyprlandPasteTarget)>> {
    if std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_none() {
        return Ok(None);
    }
    let hyprctl = find_program(&HYPRCTL)?;
    let output = capture_bounded(
        &hyprctl,
        &["-j", "activewindow"],
        16 * 1024,
        Instant::now() + HYPRLAND_TIMEOUT,
    )?;
    let target = parse_hyprland_paste_target(&output).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "Hyprland returned invalid active-window metadata",
        )
    })?;
    Ok(Some((hyprctl, target)))
}

fn parse_hyprland_paste_target(output: &[u8]) -> Option<HyprlandPasteTarget> {
    let active: HyprlandActiveWindow = serde_json::from_slice(output).ok()?;
    let digits = active.address.strip_prefix("0x")?;
    if digits.is_empty()
        || digits.len() > 16
        || !digits.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return None;
    }
    let terminal = active
        .tags
        .iter()
        .any(|tag| tag.trim_end_matches('*') == "terminal");
    Some(HyprlandPasteTarget {
        address: active.address,
        chord: if terminal {
            PasteChord::ShiftInsert
        } else {
            PasteChord::CtrlV
        },
    })
}

fn hyprland_paste_script(target: &HyprlandPasteTarget) -> String {
    let (mods, key) = match target.chord {
        PasteChord::CtrlV => ("CTRL", "V"),
        PasteChord::ShiftInsert => ("SHIFT", "Insert"),
    };
    format!(
        "local w = hl.get_active_window(); if not w or tostring(w.address) ~= '{}' then error('active window changed') end; hl.dispatch(hl.dsp.send_key_state({{ mods = '{mods}', key = '{key}', state = 'down' }})); hl.timer(function() hl.dispatch(hl.dsp.send_key_state({{ mods = '{mods}', key = '{key}', state = 'up' }})) end, {{ timeout = 50, type = 'oneshot' }}); return 'ok'",
        target.address
    )
}

pub struct NativeDelivery {
    backend: Backend,
    runner: Box<dyn Runner>,
    clipboard_owner: Option<Box<dyn OwnedChild>>,
}
impl NativeDelivery {
    pub fn new() -> Self {
        Self {
            backend: detect_backend(),
            runner: Box::new(Supervisor),
            clipboard_owner: None,
        }
    }
}
impl NativeDelivery {
    pub fn deliver(
        &mut self,
        transcript: &str,
        output: &OutputConfig,
    ) -> Result<DeliveryOutcome, String> {
        let mut text = transcript.to_owned();
        if !text.is_empty() && output.trailing_space {
            text.push(' ');
        }
        match output.method {
            OutputMethod::Clipboard => self.copy(&text).map(|_| DeliveryOutcome::Clipboard),
            OutputMethod::Paste => {
                self.copy(&text)?;
                Ok(match self.runner.paste(self.backend) {
                    Ok(()) => DeliveryOutcome::Pasted,
                    Err(_) => DeliveryOutcome::ClipboardFallback,
                })
            }
            OutputMethod::Type => match self.type_text(&text) {
                Ok(()) => Ok(DeliveryOutcome::Typed),
                Err(_) => {
                    self.copy(&text)?;
                    Ok(DeliveryOutcome::ClipboardFallback)
                }
            },
        }
    }
    fn copy(&mut self, text: &str) -> Result<(), String> {
        // The selected backend stays in the foreground so ownership remains supervised.
        let owner = self
            .runner
            .start_clipboard(self.backend, text)
            .map_err(err)?;
        self.clipboard_owner = Some(owner);
        Ok(())
    }
    fn type_text(&mut self, text: &str) -> io::Result<()> {
        match self.backend {
            Backend::Wayland => self.runner.run(&WTYPE, &["--", text], None),
            Backend::X11 => self.runner.run(
                &XDOTOOL,
                &["type", "--clearmodifiers", "--delay", "0", "--", text],
                None,
            ),
            Backend::Unavailable => Err(io::Error::new(
                io::ErrorKind::NotFound,
                "no supported graphical session is available",
            )),
        }
    }
}
fn err(e: io::Error) -> String {
    format!("desktop delivery failed: {e}")
}

fn detect_backend() -> Backend {
    select_backend(
        std::env::var("XDG_SESSION_TYPE").ok().as_deref(),
        std::env::var_os("WAYLAND_DISPLAY").is_some(),
        std::env::var_os("DISPLAY").is_some(),
    )
}

fn select_backend(session_type: Option<&str>, wayland: bool, x11: bool) -> Backend {
    match session_type {
        Some(value) if value.eq_ignore_ascii_case("wayland") && wayland => Backend::Wayland,
        Some(value) if value.eq_ignore_ascii_case("x11") && x11 => Backend::X11,
        _ if wayland => Backend::Wayland,
        _ if x11 => Backend::X11,
        _ => Backend::Unavailable,
    }
}

pub fn notify(enabled: bool, title: &str, body: &str) {
    if !enabled {
        return;
    }
    // Callers supply fixed, non-sensitive text; failures are deliberately discarded.
    if let Ok(program) = find_program(&NOTIFY) {
        let _ = supervise(
            &program,
            &["--app-name=SayAll", title, body],
            None,
            NOTIFY_TIMEOUT,
        );
    }
}

fn supervise(
    program: &Path,
    args: &[&str],
    input: Option<&str>,
    timeout: Duration,
) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    let mut child = spawn(program, args, input, deadline)?;
    wait_bounded(&mut child, deadline)
}

fn find_program(programs: &[&str]) -> io::Result<PathBuf> {
    programs
        .iter()
        .map(PathBuf::from)
        .find(|p| p.is_file())
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "required desktop tool unavailable"))
}

fn spawn(
    program: &Path,
    args: &[&str],
    input: Option<&str>,
    deadline: Instant,
) -> io::Result<Child> {
    let mut command = base_command(program, args);
    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = command.spawn()?;
    if let Some(text) = input {
        if let Some(pipe) = child.stdin.take() {
            if let Err(error) = write_bounded(pipe, text.as_bytes(), deadline) {
                terminate(&mut child);
                return Err(error);
            }
        }
    }
    Ok(child)
}

fn base_command(program: &Path, args: &[&str]) -> Command {
    let mut command = Command::new(program);
    command.args(args).env_clear().stderr(Stdio::null());
    for name in [
        "HOME",
        "XDG_RUNTIME_DIR",
        "WAYLAND_DISPLAY",
        "DISPLAY",
        "XAUTHORITY",
        "DBUS_SESSION_BUS_ADDRESS",
        "HYPRLAND_INSTANCE_SIGNATURE",
    ] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    let parent_pid = unsafe { libc::getpid() };
    unsafe {
        command.pre_exec(move || {
            #[cfg(target_os = "linux")]
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::setpgid(0, 0) != 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::getppid() != parent_pid {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "parent exited"));
            }
            Ok(())
        });
    }
    command
}

fn write_bounded(pipe: ChildStdin, bytes: &[u8], deadline: Instant) -> io::Result<()> {
    let fd = pipe.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut written = 0;
    while written < bytes.len() {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "desktop tool stdin timed out",
            ));
        }
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLOUT,
            revents: 0,
        };
        let millis = remaining.as_millis().min(i32::MAX as u128) as i32;
        let ready = unsafe { libc::poll(&mut pfd, 1, millis.max(1)) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if ready == 0 {
            continue;
        }
        let count =
            unsafe { libc::write(fd, bytes[written..].as_ptr().cast(), bytes.len() - written) };
        if count > 0 {
            written += count as usize;
        } else if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::WouldBlock
                && error.kind() != io::ErrorKind::Interrupted
            {
                return Err(error);
            }
        }
    }
    drop(pipe); // EOF is part of the fixed tool protocol.
    Ok(())
}

fn wait_bounded(child: &mut Child, deadline: Instant) -> io::Result<()> {
    loop {
        if let Some(status) = child.try_wait()? {
            return if status.success() {
                Ok(())
            } else {
                Err(io::Error::other("desktop tool failed"))
            };
        }
        if Instant::now() >= deadline {
            terminate(child);
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "desktop tool timed out",
            ));
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn owner_state(child: &mut Child) -> io::Result<Option<bool>> {
    Ok(child.try_wait()?.map(|status| status.success()))
}

// Returns whether wl-copy is still the owner. A clean exit is acceptable only after the
// effective selection has been verified (a clipboard manager may have taken ownership).
fn verify_clipboard<O, V>(
    expected: &[u8],
    deadline: Instant,
    mut owner: O,
    mut verify: V,
) -> io::Result<bool>
where
    O: FnMut() -> io::Result<Option<bool>>,
    V: FnMut() -> io::Result<Vec<u8>>,
{
    loop {
        let state = owner()?;
        if state == Some(false) {
            return Err(io::Error::other("clipboard tool failed"));
        }
        let actual = match verify() {
            Ok(actual) => actual,
            Err(_) if state.is_none() && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(10));
                continue;
            }
            Err(error) => return Err(error),
        };
        if actual == expected {
            let final_state = owner()?;
            if final_state == Some(false) {
                return Err(io::Error::other("clipboard tool failed"));
            }
            return Ok(final_state.is_none());
        }
        if state == Some(true) {
            return Err(io::Error::other(
                "clipboard owner exited before selection was ready",
            ));
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "clipboard verification timed out",
            ));
        }
        thread::sleep(Duration::from_millis(10));
    }
}

fn capture_bounded(
    program: &Path,
    args: &[&str],
    limit: usize,
    deadline: Instant,
) -> io::Result<Vec<u8>> {
    let mut command = base_command(program, args);
    command.stdin(Stdio::null()).stdout(Stdio::piped());
    let mut child = command.spawn()?;
    let pipe = child.stdout.take().expect("piped stdout");
    let fd = pipe.as_raw_fd();
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        terminate(&mut child);
        return Err(io::Error::last_os_error());
    }
    let mut output = Vec::with_capacity(limit.min(4096));
    loop {
        let mut buffer = [0u8; 4096];
        let count = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
        if count > 0 {
            if output.len() + count as usize > limit {
                terminate(&mut child);
                return Err(io::Error::other(
                    "clipboard verification output exceeded bound",
                ));
            }
            output.extend_from_slice(&buffer[..count as usize]);
            continue;
        }
        if count < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::WouldBlock
                && error.kind() != io::ErrorKind::Interrupted
            {
                terminate(&mut child);
                return Err(error);
            }
        }
        if let Some(status) = child.try_wait()? {
            return if status.success() {
                Ok(output)
            } else {
                Err(io::Error::other("clipboard verification failed"))
            };
        }
        if Instant::now() >= deadline {
            terminate(&mut child);
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "clipboard verification timed out",
            ));
        }
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let remaining = deadline.saturating_duration_since(Instant::now());
        let millis = remaining.as_millis().min(10).max(1) as i32;
        let ready = unsafe { libc::poll(&mut pfd, 1, millis) };
        if ready < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            terminate(&mut child);
            return Err(io::Error::last_os_error());
        }
    }
}

fn terminate(child: &mut Child) {
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGTERM);
    }
    let deadline = Instant::now() + Duration::from_millis(100);
    while Instant::now() < deadline {
        if child.try_wait().ok().flatten().is_some() {
            return;
        }
        thread::sleep(Duration::from_millis(5));
    }
    unsafe {
        libc::kill(-(child.id() as i32), libc::SIGKILL);
    }
    let _ = child.wait();
}

struct ManagedChild(Option<Child>);
impl OwnedChild for ManagedChild {}
impl Drop for ManagedChild {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            terminate(&mut child);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    struct FakeOwner(Arc<AtomicUsize>);
    impl OwnedChild for FakeOwner {}
    impl Drop for FakeOwner {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    #[derive(Clone)]
    struct Fake(
        Arc<Mutex<Vec<(String, Vec<String>, Option<String>)>>>,
        bool,
        Arc<AtomicUsize>,
    );
    impl Runner for Fake {
        fn run(&mut self, p: &[&str], a: &[&str], s: Option<&str>) -> io::Result<()> {
            self.0.lock().unwrap().push((
                p[0].into(),
                a.iter().map(|x| x.to_string()).collect(),
                s.map(str::to_owned),
            ));
            if self.1 && (p == WTYPE || (p == XDOTOOL && a.first() == Some(&"type"))) {
                Err(io::Error::other("crash"))
            } else {
                Ok(())
            }
        }
        fn start_clipboard(
            &mut self,
            backend: Backend,
            input: &str,
        ) -> io::Result<Box<dyn OwnedChild>> {
            let (program, args) = match backend {
                Backend::Wayland => (WLCOPY[0], vec!["--foreground".into()]),
                Backend::X11 => (
                    XSEL[0],
                    vec!["--clipboard".into(), "--input".into(), "--nodetach".into()],
                ),
                Backend::Unavailable => {
                    return Err(io::Error::new(io::ErrorKind::NotFound, "unavailable"));
                }
            };
            self.0
                .lock()
                .unwrap()
                .push((program.into(), args, Some(input.into())));
            Ok(Box::new(FakeOwner(self.2.clone())))
        }
    }
    #[test]
    fn type_falls_back_once_and_appends_once() {
        let calls = Arc::new(Mutex::new(vec![]));
        let drops = Arc::new(AtomicUsize::new(0));
        let mut d = NativeDelivery {
            backend: Backend::Wayland,
            runner: Box::new(Fake(calls.clone(), true, drops)),
            clipboard_owner: None,
        };
        assert_eq!(
            d.deliver(
                "hello",
                &OutputConfig {
                    method: OutputMethod::Type,
                    trailing_space: true
                }
            )
            .unwrap(),
            DeliveryOutcome::ClipboardFallback
        );
        let c = calls.lock().unwrap();
        assert_eq!(c.len(), 2);
        assert_eq!(c[0].1, ["--", "hello "]);
        assert_eq!(c[1].2.as_deref(), Some("hello "));
    }
    #[test]
    fn clipboard_and_paste_are_exactly_once() {
        for (method, n) in [(OutputMethod::Clipboard, 1), (OutputMethod::Paste, 2)] {
            let calls = Arc::new(Mutex::new(vec![]));
            let drops = Arc::new(AtomicUsize::new(0));
            let mut d = NativeDelivery {
                backend: Backend::Wayland,
                runner: Box::new(Fake(calls.clone(), false, drops)),
                clipboard_owner: None,
            };
            d.deliver(
                "x",
                &OutputConfig {
                    method,
                    trailing_space: false,
                },
            )
            .unwrap();
            let calls = calls.lock().unwrap();
            assert_eq!(calls.len(), n);
            assert_eq!(calls[0].0, WLCOPY[0]);
            assert_eq!(calls[0].1, ["--foreground"]);
            if method == OutputMethod::Paste {
                assert_eq!(calls[1].0, WTYPE[0]);
                assert_eq!(calls[1].1, ["-M", "ctrl", "-k", "v", "-m", "ctrl"]);
            }
        }
    }

    #[test]
    fn failed_paste_injection_retains_verified_clipboard() {
        let calls = Arc::new(Mutex::new(vec![]));
        let drops = Arc::new(AtomicUsize::new(0));
        let mut delivery = NativeDelivery {
            backend: Backend::Wayland,
            runner: Box::new(Fake(calls.clone(), true, drops.clone())),
            clipboard_owner: None,
        };
        assert_eq!(
            delivery
                .deliver(
                    "list\n- one\n- two",
                    &OutputConfig {
                        method: OutputMethod::Paste,
                        trailing_space: false,
                    },
                )
                .unwrap(),
            DeliveryOutcome::ClipboardFallback
        );
        assert_eq!(calls.lock().unwrap().len(), 2);
        assert_eq!(drops.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn hyprland_target_uses_ctrl_v_for_untagged_amp_window() {
        let target = parse_hyprland_paste_target(
            br#"{"address":"0x55cbc3bbf920","class":"dev.herdr.Terminal","title":"sensitive","tags":["default-opacity*"]}"#,
        )
        .unwrap();
        assert_eq!(target.address, "0x55cbc3bbf920");
        assert_eq!(target.chord, PasteChord::CtrlV);
    }

    #[test]
    fn hyprland_target_uses_shift_insert_for_terminal_tags() {
        for tag in ["terminal", "terminal*"] {
            let json = format!(r#"{{"address":"0xabc123","tags":["{tag}"]}}"#);
            let target = parse_hyprland_paste_target(json.as_bytes()).unwrap();
            assert_eq!(target.chord, PasteChord::ShiftInsert);
        }
    }

    #[test]
    fn hyprland_target_rejects_malformed_or_untrusted_addresses() {
        for json in [
            br#"{}"#.as_slice(),
            br#"{"address":"55","tags":[]}"#,
            br#"{"address":"0x1;exec","tags":[]}"#,
            br#"{"address":"0x1234567890abcdef0","tags":[]}"#,
        ] {
            assert!(parse_hyprland_paste_target(json).is_none());
        }
    }

    #[test]
    fn hyprland_script_checks_focus_and_sends_ctrl_v_down_then_up() {
        let target = HyprlandPasteTarget {
            address: "0xabc123".into(),
            chord: PasteChord::CtrlV,
        };
        let script = hyprland_paste_script(&target);
        assert!(script.contains("tostring(w.address) ~= '0xabc123'"));
        assert!(script.contains("mods = 'CTRL', key = 'V', state = 'down'"));
        assert!(script.contains("mods = 'CTRL', key = 'V', state = 'up'"));
        assert!(script.contains("timeout = 50, type = 'oneshot'"));
    }

    #[test]
    fn hyprland_script_uses_shift_insert_for_tagged_terminals() {
        let target = HyprlandPasteTarget {
            address: "0xabc123".into(),
            chord: PasteChord::ShiftInsert,
        };
        let script = hyprland_paste_script(&target);
        assert!(script.contains("mods = 'SHIFT', key = 'Insert', state = 'down'"));
        assert!(script.contains("mods = 'SHIFT', key = 'Insert', state = 'up'"));
    }

    #[test]
    fn clipboard_owner_is_retained_replaced_and_dropped() {
        let calls = Arc::new(Mutex::new(vec![]));
        let drops = Arc::new(AtomicUsize::new(0));
        let mut delivery = NativeDelivery {
            backend: Backend::Wayland,
            runner: Box::new(Fake(calls, false, drops.clone())),
            clipboard_owner: None,
        };
        delivery.copy("first").unwrap();
        assert_eq!(drops.load(Ordering::SeqCst), 0);
        delivery.copy("second").unwrap();
        assert_eq!(drops.load(Ordering::SeqCst), 1);
        drop(delivery);
        assert_eq!(drops.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn session_type_selects_native_delivery_backend() {
        assert_eq!(
            select_backend(Some("wayland"), true, true),
            Backend::Wayland
        );
        assert_eq!(select_backend(Some("x11"), true, true), Backend::X11);
        assert_eq!(select_backend(None, true, true), Backend::Wayland);
        assert_eq!(select_backend(None, false, true), Backend::X11);
        assert_eq!(
            select_backend(Some("tty"), false, false),
            Backend::Unavailable
        );
    }

    #[test]
    fn x11_uses_xdotool_and_xsel() {
        let calls = Arc::new(Mutex::new(vec![]));
        let drops = Arc::new(AtomicUsize::new(0));
        let mut delivery = NativeDelivery {
            backend: Backend::X11,
            runner: Box::new(Fake(calls.clone(), false, drops)),
            clipboard_owner: None,
        };
        delivery
            .deliver(
                "hello",
                &OutputConfig {
                    method: OutputMethod::Type,
                    trailing_space: false,
                },
            )
            .unwrap();
        delivery
            .deliver(
                "world",
                &OutputConfig {
                    method: OutputMethod::Paste,
                    trailing_space: false,
                },
            )
            .unwrap();
        let calls = calls.lock().unwrap();
        assert_eq!(calls[0].0, XDOTOOL[0]);
        assert_eq!(calls[0].1[0], "type");
        assert_eq!(calls[1].0, XSEL[0]);
        assert_eq!(calls[2].0, XDOTOOL[0]);
        assert_eq!(calls[2].1, ["key", "--clearmodifiers", "ctrl+v"]);
    }

    #[test]
    fn x11_type_failure_falls_back_to_clipboard_once() {
        let calls = Arc::new(Mutex::new(vec![]));
        let drops = Arc::new(AtomicUsize::new(0));
        let mut delivery = NativeDelivery {
            backend: Backend::X11,
            runner: Box::new(Fake(calls.clone(), true, drops)),
            clipboard_owner: None,
        };
        assert_eq!(
            delivery
                .deliver(
                    "hello",
                    &OutputConfig {
                        method: OutputMethod::Type,
                        trailing_space: false,
                    },
                )
                .unwrap(),
            DeliveryOutcome::ClipboardFallback
        );
        let calls = calls.lock().unwrap();
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[0].0, XDOTOOL[0]);
        assert_eq!(calls[1].0, XSEL[0]);
        assert_eq!(calls[1].2.as_deref(), Some("hello"));
    }

    #[test]
    fn supervisor_reports_crash_timeout_and_clears_environment() {
        assert!(
            supervise(
                Path::new("/bin/sh"),
                &["-c", "exit 9"],
                None,
                Duration::from_secs(1)
            )
            .is_err()
        );
        let start = Instant::now();
        let error = supervise(
            Path::new("/bin/sh"),
            &["-c", "/bin/sleep 10"],
            None,
            Duration::from_millis(30),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
        let previous_xauthority = std::env::var_os("XAUTHORITY");
        let previous_hyprland = std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE");
        unsafe {
            std::env::set_var("SAYALL_ENV_CLEAR_TEST", "present");
            std::env::set_var("XAUTHORITY", "/tmp/sayall-test-xauthority");
            std::env::set_var("HYPRLAND_INSTANCE_SIGNATURE", "sayall-test-instance");
        }
        let result = supervise(
            Path::new("/bin/sh"),
            &[
                "-c",
                "test -z \"$SAYALL_ENV_CLEAR_TEST\" && test -n \"$HOME\" && test \"$XAUTHORITY\" = /tmp/sayall-test-xauthority && test \"$HYPRLAND_INSTANCE_SIGNATURE\" = sayall-test-instance",
            ],
            None,
            Duration::from_secs(1),
        );
        unsafe {
            std::env::remove_var("SAYALL_ENV_CLEAR_TEST");
            if let Some(value) = previous_xauthority {
                std::env::set_var("XAUTHORITY", value);
            } else {
                std::env::remove_var("XAUTHORITY");
            }
            if let Some(value) = previous_hyprland {
                std::env::set_var("HYPRLAND_INSTANCE_SIGNATURE", value);
            } else {
                std::env::remove_var("HYPRLAND_INSTANCE_SIGNATURE");
            }
        }
        result.unwrap();
    }

    #[test]
    fn blocked_stdin_write_obeys_deadline() {
        let input = "x".repeat(2 * 1024 * 1024);
        let start = Instant::now();
        let error = supervise(
            Path::new("/bin/sh"),
            &["-c", "/bin/sleep 10"],
            Some(&input),
            Duration::from_millis(30),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[test]
    fn clipboard_verifier_waits_through_delayed_and_stale_content() {
        let mut attempts = 0;
        let alive = verify_clipboard(
            b"new",
            Instant::now() + Duration::from_secs(1),
            || Ok(None),
            || {
                attempts += 1;
                Ok(if attempts < 3 { b"old" } else { b"new" }.to_vec())
            },
        )
        .unwrap();
        assert!(alive);
        assert_eq!(attempts, 3);
    }

    #[test]
    fn clipboard_verifier_retries_empty_selection_while_owner_is_alive() {
        let mut attempts = 0;
        let alive = verify_clipboard(
            b"new",
            Instant::now() + Duration::from_secs(1),
            || Ok(None),
            || {
                attempts += 1;
                if attempts == 1 {
                    Err(io::Error::other("nothing copied"))
                } else {
                    Ok(b"new".to_vec())
                }
            },
        )
        .unwrap();
        assert!(alive);
        assert_eq!(attempts, 2);
    }

    #[test]
    fn clipboard_verifier_accepts_clean_immediate_takeover_after_verification() {
        assert!(
            !verify_clipboard(
                b"new",
                Instant::now() + Duration::from_secs(1),
                || Ok(Some(true)),
                || Ok(b"new".to_vec()),
            )
            .unwrap()
        );
    }

    #[test]
    fn clipboard_verifier_rejects_owner_failure_and_stale_timeout() {
        assert!(
            verify_clipboard(
                b"new",
                Instant::now() + Duration::from_secs(1),
                || Ok(Some(false)),
                || Ok(b"new".to_vec()),
            )
            .is_err()
        );
        let error = verify_clipboard(b"new", Instant::now(), || Ok(None), || Ok(b"old".to_vec()))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }
}
