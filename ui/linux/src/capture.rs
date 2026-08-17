use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
#[cfg(debug_assertions)]
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
#[cfg(debug_assertions)]
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

pub struct Capture {
    source: CaptureSource,
    dir: PathBuf,
    pcm: PathBuf,
    wav: PathBuf,
    cleanup: bool,
}
enum CaptureSource {
    Process(Child),
    #[cfg(debug_assertions)]
    Fixture {
        stop: Arc<AtomicBool>,
        thread: Option<JoinHandle<io::Result<()>>>,
    },
}
#[derive(Clone, Copy, Debug, Serialize)]
pub struct Level {
    pub rms: f64,
    pub peak: f64,
    pub clipping: bool,
}

impl Capture {
    pub fn start(root: &Path, generation: u64, source: &str) -> io::Result<Self> {
        // This entire branch, including the environment variable name, is
        // compiled out of release builds.
        #[cfg(debug_assertions)]
        if let Some(path) = std::env::var_os("SAYALL_TEST_AUDIO_FIXTURE") {
            return Self::start_fixture(root, generation, Path::new(&path));
        }
        Self::start_with_program(root, generation, source, resolve_program("pw-record"))
    }
    fn start_with_program(
        root: &Path,
        generation: u64,
        source: &str,
        program: io::Result<PathBuf>,
    ) -> io::Result<Self> {
        let dir = root.join(format!("session-{generation}"));
        fs::DirBuilder::new().mode(0o700).create(&dir)?;
        struct StartupCleanup(Option<PathBuf>);
        impl Drop for StartupCleanup {
            fn drop(&mut self) {
                if let Some(path) = self.0.take() {
                    let _ = fs::remove_dir_all(path);
                }
            }
        }
        let mut startup_cleanup = StartupCleanup(Some(dir.clone()));
        let pcm = dir.join("audio.pcm");
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&pcm)?;
        // The stream worker validates both distinct files before recording has
        // produced samples.  Create the final inode now; stop() fills it in.
        let wav = dir.join("audio.wav");
        let mut wav_file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&wav)?;
        write_wav(&mut wav_file, &[])?;
        let program = program?;
        let allowed: Vec<_> = ["XDG_RUNTIME_DIR", "PIPEWIRE_REMOTE"]
            .into_iter()
            .filter_map(|key| std::env::var_os(key).map(|v| (key, v)))
            .collect();
        let parent = unsafe { libc::getpid() };
        let mut command = Command::new(program);
        command.env_clear().envs(allowed);
        command.args([
            "--raw",
            "--format",
            "s16",
            "--rate",
            "16000",
            "--channels",
            "1",
        ]);
        if !source.is_empty() {
            command.args(["--target", source]);
        }
        command
            .arg(&pcm)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(move || {
                if libc::setpgid(0, 0) != 0 {
                    return Err(io::Error::last_os_error());
                }
                #[cfg(target_os = "linux")]
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::getppid() != parent {
                    libc::raise(libc::SIGKILL);
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        startup_cleanup.0 = None;
        Ok(Self {
            source: CaptureSource::Process(child),
            dir,
            pcm,
            wav,
            cleanup: true,
        })
    }
    #[cfg(debug_assertions)]
    fn start_fixture(root: &Path, generation: u64, fixture: &Path) -> io::Result<Self> {
        let pcm_data = read_fixture(fixture)?;
        let dir = root.join(format!("session-{generation}"));
        fs::DirBuilder::new().mode(0o700).create(&dir)?;
        let pcm = dir.join("audio.pcm");
        let wav = dir.join("audio.wav");
        let result = (|| {
            OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&pcm)?;
            let mut wav_file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&wav)?;
            write_wav(&mut wav_file, &[])
        })();
        if let Err(error) = result {
            let _ = fs::remove_dir_all(&dir);
            return Err(error);
        }

        let output = pcm.clone();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = std::thread::spawn(move || stream_fixture(&output, &pcm_data, &thread_stop));
        Ok(Self {
            source: CaptureSource::Fixture {
                stop,
                thread: Some(thread),
            },
            dir,
            pcm,
            wav,
            cleanup: true,
        })
    }
    pub fn paths(&self) -> (&Path, &Path) {
        (&self.pcm, &self.wav)
    }
    pub fn alive(&mut self) -> io::Result<bool> {
        match &mut self.source {
            CaptureSource::Process(child) => Ok(child.try_wait()?.is_none()),
            #[cfg(debug_assertions)]
            CaptureSource::Fixture { thread, .. } => {
                Ok(!thread.as_ref().is_some_and(|t| t.is_finished()))
            }
        }
    }
    pub fn level(&self) -> io::Result<Level> {
        analyze_tail(&self.pcm)
    }
    pub fn stop(mut self) -> io::Result<PathBuf> {
        let process_result = self.terminate(Duration::from_secs(2));
        // pw-record 1.6 exits with status 1 after handling SIGINT even though
        // the recording completed normally. Only accept that status when this
        // process was still alive and we successfully sent the stop signal;
        // an independently failed capture must still surface as an error.
        if let Some((status, interrupted)) = process_result? {
            if !status.success() && !(interrupted && status.code() == Some(1)) {
                return Err(io::Error::other(format!("pw-record exited with {status}")));
            }
        }
        self.finish_wav()?;
        self.cleanup = false;
        Ok(self.wav.clone())
    }
    pub fn cancel(mut self) {
        let _ = self.terminate(Duration::from_millis(500));
        let _ = fs::remove_dir_all(&self.dir);
    }
    fn terminate(
        &mut self,
        first: Duration,
    ) -> io::Result<Option<(std::process::ExitStatus, bool)>> {
        #[cfg(debug_assertions)]
        if let CaptureSource::Fixture { stop, thread } = &mut self.source {
            stop.store(true, Ordering::Release);
            let result = thread
                .take()
                .expect("fixture capture thread")
                .join()
                .map_err(|_| io::Error::other("fixture capture thread panicked"))?;
            result?;
            return Ok(None);
        }
        let CaptureSource::Process(child) = &mut self.source else {
            unreachable!()
        };
        if let Some(status) = child.try_wait().ok().flatten() {
            return Ok(Some((status, false)));
        }
        let child_id = child.id();
        let signal = |sig| unsafe { libc::kill(-(child_id as i32), sig) == 0 };
        let interrupted = signal(libc::SIGINT);
        if let Some(status) = reap_status(child, first) {
            return Ok(Some((status, interrupted)));
        }
        signal(libc::SIGTERM);
        if let Some(status) = reap_status(child, Duration::from_millis(500)) {
            return Ok(Some((status, false)));
        }
        signal(libc::SIGKILL);
        Ok(Some((child.wait()?, false)))
    }
    fn finish_wav(&mut self) -> io::Result<()> {
        let mut pcm = Vec::new();
        File::open(&self.pcm)?.read_to_end(&mut pcm)?;
        if pcm.len() % 2 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid s16 PCM",
            ));
        }
        let mut out = OpenOptions::new()
            .write(true)
            .truncate(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&self.wav)?;
        write_wav(&mut out, &pcm)?;
        out.sync_all()?;
        fs::remove_file(&self.pcm)?;
        Ok(())
    }
}
impl Drop for Capture {
    fn drop(&mut self) {
        match &mut self.source {
            CaptureSource::Process(child) => {
                if child.try_wait().ok().flatten().is_none() {
                    unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL) };
                    let _ = child.wait();
                }
            }
            #[cfg(debug_assertions)]
            CaptureSource::Fixture { stop, thread } => {
                stop.store(true, Ordering::Release);
                if let Some(thread) = thread.take() {
                    let _ = thread.join();
                }
            }
        }
        if self.cleanup {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
}
fn reap_status(child: &mut Child, timeout: Duration) -> Option<std::process::ExitStatus> {
    let end = Instant::now() + timeout;
    while Instant::now() < end {
        if let Some(status) = child.try_wait().ok().flatten() {
            return Some(status);
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    None
}

#[cfg(debug_assertions)]
const MAX_FIXTURE_PCM_BYTES: u64 = 32_000 * 300;

#[cfg(debug_assertions)]
fn read_fixture(path: &Path) -> io::Result<Vec<u8>> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "audio fixture must be an absolute canonical path",
        ));
    }
    if fs::canonicalize(path)?.as_path() != path {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "audio fixture must be an absolute canonical path",
        ));
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file()
        || metadata.len() < 44
        || metadata.len() > 44 + MAX_FIXTURE_PCM_BYTES
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "audio fixture is not a bounded regular WAV file",
        ));
    }
    let mut header = [0; 44];
    file.read_exact(&mut header)?;
    let data_len = u32::from_le_bytes(header[40..44].try_into().unwrap()) as u64;
    let canonical = &header[..4] == b"RIFF"
        && u32::from_le_bytes(header[4..8].try_into().unwrap()) as u64 == 36 + data_len
        && &header[8..12] == b"WAVE"
        && &header[12..36] == b"fmt \x10\0\0\0\x01\0\x01\0\x80>\0\0\0}\0\0\x02\0\x10\0"
        && &header[36..40] == b"data"
        && data_len <= MAX_FIXTURE_PCM_BYTES
        && data_len % 2 == 0
        && metadata.len() == 44 + data_len;
    if !canonical {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "audio fixture must be canonical 16 kHz mono S16LE WAV",
        ));
    }
    let mut pcm = Vec::with_capacity(data_len as usize);
    file.read_to_end(&mut pcm)?;
    Ok(pcm)
}

#[cfg(debug_assertions)]
fn stream_fixture(path: &Path, pcm: &[u8], stop: &AtomicBool) -> io::Result<()> {
    let mut output = OpenOptions::new()
        .append(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let started = Instant::now();
    for (index, chunk) in pcm.chunks(320).enumerate() {
        if stop.load(Ordering::Acquire) {
            return Ok(());
        }
        output.write_all(chunk)?;
        let deadline = started + Duration::from_millis(10 * (index as u64 + 1));
        if let Some(delay) = deadline.checked_duration_since(Instant::now()) {
            std::thread::sleep(delay);
        }
    }
    while !stop.load(Ordering::Acquire) {
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

pub fn cleanup(path: &Path) {
    if let Some(dir) = path.parent() {
        let _ = fs::remove_dir_all(dir);
    }
}
fn analyze_tail(path: &Path) -> io::Result<Level> {
    let mut file = File::open(path)?;
    let len = file.metadata()?.len();
    let count = len.min(3200) & !1;
    file.seek(SeekFrom::Start(len - count))?;
    let mut b = vec![0; count as usize];
    file.read_exact(&mut b)?;
    let mut sum = 0f64;
    let mut peak = 0i32;
    let mut n = 0;
    for x in b.chunks_exact(2) {
        let v = i16::from_le_bytes([x[0], x[1]]) as i32;
        peak = peak.max(v.abs());
        sum += (v as f64) * (v as f64);
        n += 1;
    }
    Ok(Level {
        rms: if n == 0 {
            0.0
        } else {
            (sum / n as f64).sqrt() / 32768.0
        },
        peak: peak as f64 / 32768.0,
        clipping: peak >= 32760,
    })
}

fn resolve_program(name: &str) -> io::Result<PathBuf> {
    resolve_program_in(name, &[Path::new("/usr/bin"), Path::new("/bin")], 0)
}
fn resolve_program_in(name: &str, dirs: &[&Path], trusted_uid: u32) -> io::Result<PathBuf> {
    let trusted_roots: Vec<_> = dirs
        .iter()
        .filter_map(|dir| fs::canonicalize(dir).ok())
        .collect();
    for dir in dirs {
        let path = dir.join(name);
        let Ok(entry) = fs::symlink_metadata(&path) else {
            continue;
        };
        let Ok(target) = fs::canonicalize(&path) else {
            continue;
        };
        let Ok(meta) = fs::metadata(&target) else {
            continue;
        };
        if (entry.file_type().is_file() || entry.file_type().is_symlink())
            && entry.uid() == trusted_uid
            && trusted_roots
                .iter()
                .any(|root| target.parent() == Some(root.as_path()))
            && meta.file_type().is_file()
            && meta.uid() == trusted_uid
            && meta.mode() & 0o022 == 0
            && meta.mode() & 0o111 != 0
        {
            return Ok(path);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "pw-record not found in trusted paths",
    ))
}
fn write_wav(w: &mut impl Write, pcm: &[u8]) -> io::Result<()> {
    w.write_all(b"RIFF")?;
    w.write_all(&(36 + pcm.len() as u32).to_le_bytes())?;
    w.write_all(b"WAVEfmt \x10\0\0\0\x01\0\x01\0\x80>\0\0\0}\0\0\x02\0\x10\0data")?;
    w.write_all(&(pcm.len() as u32).to_le_bytes())?;
    w.write_all(pcm)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ops::Deref;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt, symlink};

    struct TestRoot(PathBuf);

    impl Deref for TestRoot {
        type Target = Path;

        fn deref(&self) -> &Self::Target {
            &self.0
        }
    }

    impl AsRef<Path> for TestRoot {
        fn as_ref(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn private_root(name: &str) -> TestRoot {
        let root =
            std::env::temp_dir().join(format!("sayall-capture-test-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        TestRoot(root)
    }

    #[test]
    fn wav_is_canonical_mono_16khz_s16le() {
        let mut wav = Vec::new();
        write_wav(&mut wav, &[1, 0, 255, 127]).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[36..40], b"data");
        assert_eq!(u32::from_le_bytes(wav[40..44].try_into().unwrap()), 4);
        assert_eq!(&wav[44..], &[1, 0, 255, 127]);
    }

    #[test]
    fn fixture_rejects_noncanonical_and_unsafe_inputs() {
        let root = private_root("fixture-invalid");
        let malformed = root.join("malformed.wav");
        fs::write(&malformed, b"not a wav").unwrap();
        let malformed = fs::canonicalize(malformed).unwrap();
        assert_eq!(
            read_fixture(&malformed).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            read_fixture(Path::new("relative.wav")).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );

        let valid = root.join("valid.wav");
        let mut bytes = Vec::new();
        write_wav(&mut bytes, &[0, 0]).unwrap();
        fs::write(&valid, bytes).unwrap();
        let link = root.join("link.wav");
        symlink(&valid, &link).unwrap();
        assert_eq!(
            read_fixture(&link).unwrap_err().kind(),
            io::ErrorKind::InvalidInput
        );
    }

    #[test]
    fn fixture_is_paced_and_stop_preserves_levels_and_partial_audio() {
        let root = private_root("fixture-paced");
        let fixture = root.join("fixture.wav");
        let pcm = vec![0x7f; 3200]; // 100 ms
        let mut bytes = Vec::new();
        write_wav(&mut bytes, &pcm).unwrap();
        fs::write(&fixture, bytes).unwrap();
        let fixture = fs::canonicalize(fixture).unwrap();

        let capture = Capture::start_fixture(&root, 20, &fixture).unwrap();
        std::thread::sleep(Duration::from_millis(35));
        let captured = fs::metadata(capture.paths().0).unwrap().len();
        assert!(
            (640..=1600).contains(&captured),
            "unexpected paced byte count: {captured}"
        );
        assert!(capture.level().unwrap().peak > 0.0);
        let wav = capture.stop().unwrap();
        let output = fs::read(&wav).unwrap();
        assert_eq!(output.len() as u64, 44 + captured);
        assert!(output.len() < 44 + pcm.len());
        cleanup(&wav);
    }

    #[test]
    fn fixture_cancel_stops_promptly_and_removes_session() {
        let root = private_root("fixture-cancel");
        let fixture = root.join("fixture.wav");
        let mut bytes = Vec::new();
        write_wav(&mut bytes, &vec![0; 32_000]).unwrap();
        fs::write(&fixture, bytes).unwrap();
        let fixture = fs::canonicalize(fixture).unwrap();
        let capture = Capture::start_fixture(&root, 21, &fixture).unwrap();
        let started = Instant::now();
        capture.cancel();
        assert!(started.elapsed() < Duration::from_millis(200));
        assert!(!root.join("session-21").exists());
    }

    #[test]
    fn startup_failure_removes_session_artifacts() {
        let root = private_root("startup-cleanup");
        let error = match Capture::start_with_program(
            &root,
            7,
            "",
            Err(io::Error::new(io::ErrorKind::NotFound, "missing")),
        ) {
            Ok(_) => panic!("capture unexpectedly started"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        assert!(!root.join("session-7").exists());
        fs::remove_dir(root).unwrap();
    }

    #[test]
    fn trusted_program_accepts_packaged_symlink() {
        let root = private_root("trusted-program-symlink");
        let bin = root.join("bin");
        fs::create_dir(&bin).unwrap();
        let target = bin.join("pw-cat");
        fs::write(&target, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o755)).unwrap();
        symlink("pw-cat", bin.join("pw-record")).unwrap();

        let uid = fs::metadata(&target).unwrap().uid();
        assert_eq!(
            resolve_program_in("pw-record", &[&bin], uid).unwrap(),
            bin.join("pw-record")
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn trusted_program_rejects_escaping_or_writable_symlink_target() {
        let root = private_root("untrusted-program-symlink");
        let bin = root.join("bin");
        fs::create_dir(&bin).unwrap();
        let outside = root.join("outside");
        fs::write(&outside, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o755)).unwrap();
        symlink(&outside, bin.join("pw-record")).unwrap();
        let uid = fs::metadata(&outside).unwrap().uid();
        assert!(resolve_program_in("pw-record", &[&bin], uid).is_err());

        fs::remove_file(bin.join("pw-record")).unwrap();
        let target = bin.join("pw-cat");
        fs::write(&target, b"#!/bin/sh\n").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o775)).unwrap();
        symlink("pw-cat", bin.join("pw-record")).unwrap();
        assert!(resolve_program_in("pw-record", &[&bin], uid).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn capture_child_does_not_inherit_general_environment() {
        let root = private_root("environment");
        let script = root.join("fake-pw-record");
        fs::write(
            &script,
            b"#!/bin/sh\nlast=\nfor arg do last=$arg; done\n/usr/bin/env > \"$last.env\"\ntrap 'exit 0' INT TERM\nwhile :; do /bin/sleep 1; done\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let capture = Capture::start_with_program(&root, 8, "", Ok(script)).unwrap();
        let environment = root.join("session-8/audio.pcm.env");
        for _ in 0..100 {
            if environment.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let contents = fs::read_to_string(environment).unwrap();
        assert!(!contents.lines().any(|line| line.starts_with("HOME=")));
        assert!(
            !contents
                .lines()
                .any(|line| line.starts_with("DEEPGRAM_API_KEY="))
        );
        capture.cancel();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stop_wraps_fake_pcm_byte_exactly_and_preserves_private_permissions() {
        let root = private_root("stop-wav");
        let script = root.join("fake-pw-record");
        fs::write(
            &script,
            b"#!/bin/sh\nfor last do :; done\nprintf '\\001\\000\\377\\177\\000\\200' > \"$last\"\ntrap 'exit 0' INT TERM\n: > \"$last.ready\"\nwhile :; do /bin/sleep 1; done\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let capture = Capture::start_with_program(&root, 9, "", Ok(script)).unwrap();
        let pcm = root.join("session-9/audio.pcm");
        let ready = root.join("session-9/audio.pcm.ready");
        let mut pcm_ready = false;
        for _ in 0..100 {
            if ready.exists() && fs::metadata(&pcm).map_or(false, |m| m.len() == 6) {
                pcm_ready = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(pcm_ready, "fake capture did not write PCM before deadline");
        assert_eq!(
            fs::metadata(root.join("session-9")).unwrap().mode() & 0o777,
            0o700
        );
        assert_eq!(fs::metadata(&pcm).unwrap().mode() & 0o777, 0o600);

        let wav = capture.stop().unwrap();
        let mut expected = Vec::new();
        write_wav(&mut expected, &[1, 0, 255, 127, 0, 128]).unwrap();
        assert_eq!(fs::read(&wav).unwrap(), expected);
        assert!(!pcm.exists());
        assert_eq!(fs::metadata(&wav).unwrap().mode() & 0o777, 0o600);
        cleanup(&wav);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn stop_accepts_pw_record_sigint_exit_status() {
        let root = private_root("sigint-status");
        let script = root.join("fake-pw-record");
        fs::write(
            &script,
            b"#!/bin/sh\nfor last do :; done\nprintf '\\001\\000' > \"$last\"\ntrap 'exit 1' INT\n: > \"$last.ready\"\nwhile :; do /bin/sleep 1; done\n",
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
        let capture = Capture::start_with_program(&root, 12, "", Ok(script)).unwrap();
        let ready = root.join("session-12/audio.pcm.ready");
        for _ in 0..100 {
            if ready.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(ready.exists(), "fake capture did not become ready");

        let wav = capture.stop().unwrap();
        assert_eq!(&fs::read(&wav).unwrap()[44..], &[1, 0]);
        cleanup(&wav);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn cancel_and_nonzero_exit_remove_all_session_artifacts() {
        let root = private_root("terminal-cleanup");
        let sleeper = root.join("sleeper");
        fs::write(
            &sleeper,
            b"#!/bin/sh\ntrap 'exit 0' INT TERM\nwhile :; do /bin/sleep 1; done\n",
        )
        .unwrap();
        fs::set_permissions(&sleeper, fs::Permissions::from_mode(0o700)).unwrap();
        Capture::start_with_program(&root, 10, "", Ok(sleeper))
            .unwrap()
            .cancel();
        assert!(!root.join("session-10").exists());

        let failing = root.join("failing");
        fs::write(&failing, b"#!/bin/sh\nexit 23\n").unwrap();
        fs::set_permissions(&failing, fs::Permissions::from_mode(0o700)).unwrap();
        let mut capture = Capture::start_with_program(&root, 11, "", Ok(failing)).unwrap();
        let mut exited = false;
        for _ in 0..100 {
            if !capture.alive().unwrap() {
                exited = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert!(exited, "fake capture did not exit before deadline");
        let error = capture.stop().unwrap_err();
        assert!(error.to_string().contains("23"));
        assert!(!root.join("session-11").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
