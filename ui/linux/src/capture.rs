use serde::Serialize;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

pub struct Capture {
    child: Child,
    dir: PathBuf,
    pcm: PathBuf,
    wav: PathBuf,
    cleanup: bool,
}
#[derive(Clone, Copy, Debug, Serialize)]
pub struct Level {
    pub rms: f64,
    pub peak: f64,
    pub clipping: bool,
}

impl Capture {
    pub fn start(root: &Path, generation: u64, source: &str) -> io::Result<Self> {
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
            child,
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
        Ok(self.child.try_wait()?.is_none())
    }
    pub fn level(&self) -> io::Result<Level> {
        analyze_tail(&self.pcm)
    }
    pub fn stop(mut self) -> io::Result<PathBuf> {
        let (status, interrupted) = self.terminate(Duration::from_secs(2));
        // pw-record 1.6 exits with status 1 after handling SIGINT even though
        // the recording completed normally. Only accept that status when this
        // process was still alive and we successfully sent the stop signal;
        // an independently failed capture must still surface as an error.
        if !status.success() && !(interrupted && status.code() == Some(1)) {
            return Err(io::Error::other(format!("pw-record exited with {status}")));
        }
        self.finish_wav()?;
        self.cleanup = false;
        Ok(self.wav.clone())
    }
    pub fn cancel(mut self) {
        let _ = self.terminate(Duration::from_millis(500));
        let _ = fs::remove_dir_all(&self.dir);
    }
    fn terminate(&mut self, first: Duration) -> (std::process::ExitStatus, bool) {
        if let Some(status) = self.child.try_wait().ok().flatten() {
            return (status, false);
        }
        let interrupted = self.signal(libc::SIGINT);
        if let Some(status) = self.reap_status(first) {
            return (status, interrupted);
        }
        self.signal(libc::SIGTERM);
        if let Some(status) = self.reap_status(Duration::from_millis(500)) {
            return (status, false);
        }
        self.signal(libc::SIGKILL);
        (self.child.wait().expect("capture child wait"), false)
    }
    fn signal(&self, sig: i32) -> bool {
        unsafe { libc::kill(-(self.child.id() as i32), sig) == 0 }
    }
    fn reap(&mut self, timeout: Duration) -> bool {
        self.reap_status(timeout).is_some()
    }
    fn reap_status(&mut self, timeout: Duration) -> Option<std::process::ExitStatus> {
        let end = Instant::now() + timeout;
        while Instant::now() < end {
            if let Some(status) = self.child.try_wait().ok().flatten() {
                return Some(status);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
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
        if self.child.try_wait().ok().flatten().is_none() {
            self.signal(libc::SIGKILL);
            let _ = self.child.wait();
        }
        if self.cleanup {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }
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
