use crate::{capture, config, desktop, worker};
use serde::Serialize;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Starting,
    Recording,
    Stopping,
    Processing,
    Delivering,
    Success,
    Error,
    Cancelled,
}

#[derive(Clone, Debug, Serialize)]
pub struct Snapshot {
    pub state: State,
    pub generation: u64,
    pub elapsed_ms: u64,
    pub show_timer: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub level: Option<capture::Level>,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            state: State::Idle,
            generation: 0,
            elapsed_ms: 0,
            show_timer: true,
            message: None,
            level: None,
        }
    }
}

pub trait Delivery: Send + 'static {
    fn deliver(
        &mut self,
        text: &str,
        output: &config::OutputConfig,
    ) -> Result<desktop::DeliveryOutcome, String>;
}
impl Delivery for desktop::NativeDelivery {
    fn deliver(
        &mut self,
        text: &str,
        output: &config::OutputConfig,
    ) -> Result<desktop::DeliveryOutcome, String> {
        self.deliver(text, output)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ToggleError {
    Busy,
    Failed(String),
    Unavailable,
}
impl fmt::Display for ToggleError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Busy => f.write_str("SayAll is busy"),
            Self::Failed(s) => f.write_str(s),
            Self::Unavailable => f.write_str("host unavailable"),
        }
    }
}

enum Command {
    Toggle(State, mpsc::Sender<Result<Snapshot, ToggleError>>),
    RestartReady,
    Reload(mpsc::Sender<Result<Snapshot, ToggleError>>),
    SetProcessingMode(
        config::ProcessingMode,
        mpsc::Sender<Result<Snapshot, ToggleError>>,
    ),
    SetOutputMethod(
        config::OutputMethod,
        mpsc::Sender<Result<Snapshot, ToggleError>>,
    ),
    Shutdown,
}
const ADMISSION_NONE: u64 = 0;
const ADMISSION_FINISH_BIT: u64 = 1;
const FIRST_ADMISSION: u64 = 2;
const RESTART_READY_BIT: u64 = 1;

fn is_finish_admission(owner: u64) -> bool {
    owner != ADMISSION_NONE && owner & ADMISSION_FINISH_BIT != 0
}

struct Inner {
    tx: mpsc::Sender<Command>,
    snapshot: Arc<Mutex<Snapshot>>,
    admitted: Arc<AtomicU64>,
    next_admission: Arc<AtomicU64>,
    restart_requested: Arc<AtomicU64>,
    shutdown: Arc<AtomicBool>,
    join: Mutex<Option<JoinHandle<()>>>,
}
struct RunSignals {
    admitted: Arc<AtomicU64>,
    next_admission: Arc<AtomicU64>,
    restart_requested: Arc<AtomicU64>,
    shutdown: Arc<AtomicBool>,
}
#[derive(Clone)]
pub struct Controller(Arc<Inner>);
impl Controller {
    pub fn spawn(root: PathBuf, delivery: impl Delivery, updates: mpsc::Sender<Snapshot>) -> Self {
        let (tx, rx) = mpsc::channel();
        let snapshot = Arc::new(Mutex::new(Snapshot::default()));
        let shared = snapshot.clone();
        let admitted = Arc::new(AtomicU64::new(ADMISSION_NONE));
        let next_admission = Arc::new(AtomicU64::new(FIRST_ADMISSION));
        let restart_requested = Arc::new(AtomicU64::new(0));
        let shutdown = Arc::new(AtomicBool::new(false));
        let signals = RunSignals {
            admitted: admitted.clone(),
            next_admission: next_admission.clone(),
            restart_requested: restart_requested.clone(),
            shutdown: shutdown.clone(),
        };
        let join =
            std::thread::spawn(move || run(rx, shared, signals, root, Box::new(delivery), updates));
        Self(Arc::new(Inner {
            tx,
            snapshot,
            admitted,
            next_admission,
            restart_requested,
            shutdown,
            join: Mutex::new(Some(join)),
        }))
    }
    pub fn status(&self) -> Snapshot {
        self.0.snapshot.lock().unwrap().clone()
    }
    pub fn toggle(&self) -> Result<Snapshot, ToggleError> {
        let expected = self.status();
        if matches!(
            expected.state,
            State::Stopping
                | State::Processing
                | State::Delivering
                | State::Success
                | State::Error
                | State::Cancelled
        ) || (expected.state == State::Recording
            && is_finish_admission(self.0.admitted.load(Ordering::Acquire)))
        {
            return self.queue_restart(expected.generation);
        }
        if !matches!(expected.state, State::Idle | State::Recording) {
            return Err(ToggleError::Busy);
        }
        let admission = self.next_admission(expected.state == State::Recording);
        if let Err(current) = self.0.admitted.compare_exchange(
            ADMISSION_NONE,
            admission,
            Ordering::AcqRel,
            Ordering::Acquire,
        ) {
            if expected.state == State::Recording && is_finish_admission(current) {
                return self.queue_restart(expected.generation);
            }
            return Err(ToggleError::Busy);
        }
        let current = self.status();
        if current.state != expected.state || current.generation != expected.generation {
            let _ = self.0.admitted.compare_exchange(
                admission,
                ADMISSION_NONE,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            return Err(ToggleError::Busy);
        }
        let (tx, rx) = mpsc::channel();
        if self.0.tx.send(Command::Toggle(expected.state, tx)).is_err() {
            let _ = self.0.admitted.compare_exchange(
                admission,
                ADMISSION_NONE,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            return Err(ToggleError::Unavailable);
        }
        let result = rx.recv().unwrap_or(Err(ToggleError::Unavailable));
        let _ = self.0.admitted.compare_exchange(
            admission,
            ADMISSION_NONE,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        result
    }
    fn next_admission(&self, finishing: bool) -> u64 {
        self.0.next_admission.fetch_add(2, Ordering::AcqRel)
            | if finishing { ADMISSION_FINISH_BIT } else { 0 }
    }
    fn queue_restart(&self, generation: u64) -> Result<Snapshot, ToggleError> {
        let pending = (generation + 1) << 1;
        if self
            .0
            .restart_requested
            .compare_exchange(0, pending, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(ToggleError::Busy);
        }
        let current = self.status();
        let queueable = matches!(
            current.state,
            State::Stopping
                | State::Processing
                | State::Delivering
                | State::Success
                | State::Error
                | State::Cancelled
        ) || (current.state == State::Recording
            && is_finish_admission(self.0.admitted.load(Ordering::Acquire)));
        if current.generation == generation && current.state == State::Idle {
            if self
                .0
                .restart_requested
                .compare_exchange(pending, 0, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                return self.toggle();
            }
            return Err(ToggleError::Busy);
        }
        if current.generation == generation && queueable {
            if self
                .0
                .restart_requested
                .compare_exchange(
                    pending,
                    pending | RESTART_READY_BIT,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                )
                .is_ok()
            {
                if self.0.tx.send(Command::RestartReady).is_err() {
                    let _ = self.0.restart_requested.compare_exchange(
                        pending | RESTART_READY_BIT,
                        0,
                        Ordering::AcqRel,
                        Ordering::Acquire,
                    );
                    return Err(ToggleError::Unavailable);
                }
                return Ok(current);
            }
        }
        let _ = self.0.restart_requested.compare_exchange(
            pending,
            0,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        Err(ToggleError::Busy)
    }
    pub fn reload(&self) -> Result<Snapshot, ToggleError> {
        if self.status().state != State::Idle {
            return Err(ToggleError::Busy);
        }
        let admission = self.next_admission(false);
        if self
            .0
            .admitted
            .compare_exchange(
                ADMISSION_NONE,
                admission,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return Err(ToggleError::Busy);
        }
        let (tx, rx) = mpsc::channel();
        if self.0.tx.send(Command::Reload(tx)).is_err() {
            let _ = self.0.admitted.compare_exchange(
                admission,
                ADMISSION_NONE,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            return Err(ToggleError::Unavailable);
        }
        let result = rx.recv().unwrap_or(Err(ToggleError::Unavailable));
        let _ = self.0.admitted.compare_exchange(
            admission,
            ADMISSION_NONE,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        result
    }
    pub fn set_processing_mode(
        &self,
        mode: config::ProcessingMode,
    ) -> Result<Snapshot, ToggleError> {
        if self.status().state != State::Idle {
            return Err(ToggleError::Busy);
        }
        let admission = self.next_admission(false);
        if self
            .0
            .admitted
            .compare_exchange(
                ADMISSION_NONE,
                admission,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return Err(ToggleError::Busy);
        }
        let (tx, rx) = mpsc::channel();
        if self
            .0
            .tx
            .send(Command::SetProcessingMode(mode, tx))
            .is_err()
        {
            let _ = self.0.admitted.compare_exchange(
                admission,
                ADMISSION_NONE,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            return Err(ToggleError::Unavailable);
        }
        let result = rx.recv().unwrap_or(Err(ToggleError::Unavailable));
        let _ = self.0.admitted.compare_exchange(
            admission,
            ADMISSION_NONE,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        result
    }
    pub fn set_output_method(&self, method: config::OutputMethod) -> Result<Snapshot, ToggleError> {
        if self.status().state != State::Idle {
            return Err(ToggleError::Busy);
        }
        let admission = self.next_admission(false);
        if self
            .0
            .admitted
            .compare_exchange(
                ADMISSION_NONE,
                admission,
                Ordering::AcqRel,
                Ordering::Acquire,
            )
            .is_err()
        {
            return Err(ToggleError::Busy);
        }
        let (tx, rx) = mpsc::channel();
        if self
            .0
            .tx
            .send(Command::SetOutputMethod(method, tx))
            .is_err()
        {
            let _ = self.0.admitted.compare_exchange(
                admission,
                ADMISSION_NONE,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            return Err(ToggleError::Unavailable);
        }
        let result = rx.recv().unwrap_or(Err(ToggleError::Unavailable));
        let _ = self.0.admitted.compare_exchange(
            admission,
            ADMISSION_NONE,
            Ordering::AcqRel,
            Ordering::Acquire,
        );
        result
    }
    pub fn shutdown_and_join(&self) {
        self.0.shutdown.store(true, Ordering::Release);
        let _ = self.0.tx.send(Command::Shutdown);
        if let Some(j) = self.0.join.lock().unwrap().take() {
            let _ = j.join();
        }
    }
}

type ActiveSession = (
    capture::Capture,
    worker::Worker,
    Instant,
    config::RecordingConfig,
    config::OutputConfig,
    bool,
    bool,
);

fn run(
    rx: mpsc::Receiver<Command>,
    shared: Arc<Mutex<Snapshot>>,
    signals: RunSignals,
    root: PathBuf,
    mut delivery: Box<dyn Delivery>,
    updates: mpsc::Sender<Snapshot>,
) {
    let mut generation = 0;
    let mut active: Option<ActiveSession> = None;
    let mut terminal_until: Option<Instant> = None;
    let publish = |state, g, started: Option<Instant>, message, show_timer| {
        let s = Snapshot {
            state,
            generation: g,
            elapsed_ms: started.map_or(0, |x| x.elapsed().as_millis() as u64),
            show_timer,
            message,
            level: None,
        };
        *shared.lock().unwrap() = s.clone();
        let _ = updates.send(s.clone());
        s
    };
    loop {
        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(Command::Shutdown) => {
                if let Some((c, w, _, _, _, _, _)) = active.take() {
                    w.cancel();
                    c.cancel();
                }
                break;
            }
            Ok(Command::Reload(reply)) => {
                let result = if shared.lock().unwrap().state != State::Idle || active.is_some() {
                    Err(ToggleError::Busy)
                } else {
                    validate_reload(config::load).map(|()| shared.lock().unwrap().clone())
                };
                let _ = reply.send(result);
            }
            Ok(Command::SetProcessingMode(mode, reply)) => {
                let result = if shared.lock().unwrap().state != State::Idle || active.is_some() {
                    Err(ToggleError::Busy)
                } else {
                    config::set_processing_mode(mode)
                        .map_err(|error| ToggleError::Failed(error.to_string()))
                        .and_then(|_| validate_reload(config::load))
                        .map(|()| shared.lock().unwrap().clone())
                };
                let _ = reply.send(result);
            }
            Ok(Command::SetOutputMethod(method, reply)) => {
                let result = if shared.lock().unwrap().state != State::Idle || active.is_some() {
                    Err(ToggleError::Busy)
                } else {
                    config::set_output_method(method)
                        .map_err(|error| ToggleError::Failed(error.to_string()))
                        .and_then(|_| validate_reload(config::load))
                        .map(|()| shared.lock().unwrap().clone())
                };
                let _ = reply.send(result);
            }
            Ok(Command::Toggle(expected, reply)) => {
                let current = shared.lock().unwrap().state;
                let result = if current != expected {
                    Err(ToggleError::Busy)
                } else if expected == State::Idle && active.is_none() {
                    let result = start_active(
                        &mut active,
                        &mut generation,
                        &root,
                        signals.shutdown.clone(),
                        &publish,
                    );
                    if result.is_err() {
                        terminal_until = Some(Instant::now() + Duration::from_secs(2));
                    }
                    result
                } else if expected == State::Recording && active.is_some() {
                    let result = finish_active(&mut active, generation, &publish, &mut *delivery);
                    terminal_until = Some(Instant::now() + Duration::from_secs(2));
                    result
                } else {
                    Err(ToggleError::Busy)
                };
                let _ = reply.send(result); // accepted work is completed even if the client left
            }
            Ok(Command::RestartReady) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let restart_request = signals.restart_requested.load(Ordering::Acquire);
                if active.is_none()
                    && restart_request >> 1 != generation + 1
                    && terminal_until.is_some_and(|until| Instant::now() >= until)
                {
                    terminal_until = None;
                    let show_timer = shared.lock().unwrap().show_timer;
                    publish(State::Idle, generation, None, None, show_timer);
                }
                if let Some((c, _, started, cfg, _, show_timer, _)) = active.as_mut() {
                    if !c.alive().unwrap_or(false) {
                        let (c, w, _, _, _, show_timer, notifications) = active.take().unwrap();
                        w.cancel();
                        c.cancel();
                        publish(
                            State::Error,
                            generation,
                            None,
                            Some("capture process exited early".into()),
                            show_timer,
                        );
                        desktop::notify(
                            notifications,
                            "SayAll capture error",
                            "Audio capture stopped unexpectedly",
                        );
                        terminal_until = Some(Instant::now() + Duration::from_secs(2));
                    } else if started.elapsed() >= Duration::from_secs(cfg.max_seconds as u64) {
                        let admission = signals.next_admission.fetch_add(2, Ordering::AcqRel)
                            | ADMISSION_FINISH_BIT;
                        if signals
                            .admitted
                            .compare_exchange(
                                ADMISSION_NONE,
                                admission,
                                Ordering::AcqRel,
                                Ordering::Acquire,
                            )
                            .is_ok()
                        {
                            let _ =
                                finish_active(&mut active, generation, &publish, &mut *delivery);
                            terminal_until = Some(Instant::now() + Duration::from_secs(2));
                            let _ = signals.admitted.compare_exchange(
                                admission,
                                ADMISSION_NONE,
                                Ordering::AcqRel,
                                Ordering::Acquire,
                            );
                        }
                    } else if let Ok(level) = c.level() {
                        let mut s = publish(
                            State::Recording,
                            generation,
                            Some(*started),
                            None,
                            *show_timer,
                        );
                        s.level = Some(level);
                        *shared.lock().unwrap() = s.clone();
                        let _ = updates.send(s);
                    }
                }
            }
        }
        let restart_request = signals.restart_requested.load(Ordering::Acquire);
        if active.is_none() && restart_request != 0 {
            if signals.shutdown.load(Ordering::Acquire) {
                continue;
            }
            if restart_request & RESTART_READY_BIT == 0 {
                continue;
            }
            if restart_request >> 1 != generation + 1 {
                let _ = signals.restart_requested.compare_exchange(
                    restart_request,
                    0,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                );
                continue;
            }
            let owner = signals.admitted.load(Ordering::Acquire);
            if owner != ADMISSION_NONE && !is_finish_admission(owner) {
                continue;
            }
            let admission = signals.next_admission.fetch_add(2, Ordering::AcqRel);
            if signals
                .admitted
                .compare_exchange(owner, admission, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
            {
                continue;
            }
            terminal_until = None;
            let show_timer = shared.lock().unwrap().show_timer;
            publish(State::Idle, generation, None, None, show_timer);
            if start_active(
                &mut active,
                &mut generation,
                &root,
                signals.shutdown.clone(),
                &publish,
            )
            .is_err()
            {
                terminal_until = Some(Instant::now() + Duration::from_secs(2));
            }
            let _ = signals.restart_requested.compare_exchange(
                restart_request,
                0,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
            let _ = signals.admitted.compare_exchange(
                admission,
                ADMISSION_NONE,
                Ordering::AcqRel,
                Ordering::Acquire,
            );
        }
    }
}

fn start_active<F>(
    active: &mut Option<ActiveSession>,
    generation: &mut u64,
    root: &Path,
    shutdown: Arc<AtomicBool>,
    publish: &F,
) -> Result<Snapshot, ToggleError>
where
    F: Fn(State, u64, Option<Instant>, Option<String>, bool) -> Snapshot,
{
    *generation += 1;
    let mut loaded_notifications = None;
    let started = config::load().map_err(|e| e.to_string()).and_then(|cfg| {
        loaded_notifications = Some(cfg.notifications);
        let capture = capture::Capture::start(root, *generation, &cfg.recording.source)
            .map_err(|e| e.to_string())?;
        publish(State::Starting, *generation, None, None, cfg.show_timer);
        let (pcm, wav) = capture.paths();
        let path = worker::resolve().map_err(|e| e.to_string())?;
        let worker = worker::Worker::start(&path, wav, pcm, &cfg.provider, shutdown)?;
        Ok((
            capture,
            worker,
            cfg.recording,
            cfg.output,
            cfg.show_timer,
            cfg.notifications,
        ))
    });
    match started {
        Ok((capture, worker, cfg, output, show_timer, notifications)) => {
            let now = Instant::now();
            *active = Some((capture, worker, now, cfg, output, show_timer, notifications));
            Ok(publish(
                State::Recording,
                *generation,
                Some(now),
                None,
                show_timer,
            ))
        }
        Err(error) => {
            let message = format!("capture failed: {error}");
            if let Some(enabled) = loaded_notifications {
                desktop::notify(
                    enabled,
                    "SayAll startup error",
                    "Speech session could not start; see the SayAll HUD for details",
                );
            }
            publish(State::Error, *generation, None, Some(message.clone()), true);
            Err(ToggleError::Failed(message))
        }
    }
}

enum DeliveryCompletion {
    NoSpeech,
    Delivered {
        outcome: desktop::DeliveryOutcome,
        warning: Option<worker::Warning>,
    },
    Failed {
        error: String,
        warning: Option<worker::Warning>,
    },
}

fn finish_active<F>(
    active: &mut Option<ActiveSession>,
    generation: u64,
    publish: &F,
    delivery: &mut dyn Delivery,
) -> Result<Snapshot, ToggleError>
where
    F: Fn(State, u64, Option<Instant>, Option<String>, bool) -> Snapshot,
{
    let (capture, worker, started, cfg, output, show_timer, notifications) =
        active.take().expect("active capture");
    publish(State::Stopping, generation, Some(started), None, show_timer);
    let outcome = (|| -> Result<DeliveryCompletion, String> {
        let wav = capture
            .stop()
            .map_err(|e| format!("capture stop failed: {e}"))?;
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                capture::cleanup(&self.0);
            }
        }
        let cleanup = Cleanup(wav);
        if started.elapsed() < Duration::from_millis(cfg.min_ms as u64) {
            return Err("recording is too short".into());
        }
        if no_signal(&cleanup.0) {
            return Err("no audio signal detected".into());
        }
        publish(
            State::Processing,
            generation,
            Some(started),
            None,
            show_timer,
        );
        Ok(deliver_outcome(
            worker.finish(Duration::from_secs(45))?,
            delivery,
            &output,
            || {
                publish(
                    State::Delivering,
                    generation,
                    Some(started),
                    None,
                    show_timer,
                )
            },
        ))
    })();
    match outcome {
        Ok(DeliveryCompletion::NoSpeech) => Ok(publish(
            State::Success,
            generation,
            None,
            Some("No speech detected".into()),
            show_timer,
        )),
        Ok(DeliveryCompletion::Delivered { outcome, warning }) => {
            if warning == Some(worker::Warning::TransformationFailed) {
                desktop::notify(
                    notifications,
                    "SayAll processing warning",
                    terminal_message(outcome, warning),
                );
            }
            Ok(publish(
                State::Success,
                generation,
                None,
                Some(terminal_message(outcome, warning).into()),
                show_timer,
            ))
        }
        Ok(DeliveryCompletion::Failed { error, warning }) => {
            let message = if warning == Some(worker::Warning::TransformationFailed) {
                format!("transformation failed; safe fallback delivery also failed: {error}")
            } else {
                error
            };
            desktop::notify(notifications, "SayAll error", &message);
            publish(
                State::Error,
                generation,
                None,
                Some(message.clone()),
                show_timer,
            );
            Err(ToggleError::Failed(message))
        }
        Err(message) => {
            desktop::notify(
                notifications,
                "SayAll error",
                "Speech session failed; see the SayAll HUD for details",
            );
            let s = publish(
                State::Error,
                generation,
                None,
                Some(message.clone()),
                show_timer,
            );
            let _ = s;
            Err(ToggleError::Failed(message))
        }
    }
}
fn terminal_message(
    outcome: desktop::DeliveryOutcome,
    warning: Option<worker::Warning>,
) -> &'static str {
    if warning == Some(worker::Warning::TransformationFailed) {
        return match outcome {
            desktop::DeliveryOutcome::ClipboardFallback => {
                "transformation failed; automatic insertion failed and safe fallback was copied to clipboard"
            }
            desktop::DeliveryOutcome::Clipboard => {
                "transformation failed; safe fallback copied to clipboard"
            }
            _ => "transformation failed; safe fallback delivered",
        };
    }
    match outcome {
        desktop::DeliveryOutcome::ClipboardFallback => {
            "automatic insertion failed; transcript copied to clipboard"
        }
        desktop::DeliveryOutcome::Clipboard => "transcript copied to clipboard",
        _ => "delivery completed",
    }
}

fn validate_reload<T>(load: impl FnOnce() -> std::io::Result<T>) -> Result<(), ToggleError> {
    load()
        .map(|_| ())
        .map_err(|e| ToggleError::Failed(e.to_string()))
}

fn deliver_outcome<F>(
    outcome: worker::Outcome,
    delivery: &mut dyn Delivery,
    output: &config::OutputConfig,
    delivering: F,
) -> DeliveryCompletion
where
    F: FnOnce() -> Snapshot,
{
    match outcome {
        worker::Outcome::NoSpeech { .. } => DeliveryCompletion::NoSpeech,
        worker::Outcome::Transcript { text, warning, .. } => {
            delivering();
            match delivery.deliver(&text, output) {
                Ok(outcome) => DeliveryCompletion::Delivered { outcome, warning },
                Err(error) => DeliveryCompletion::Failed { error, warning },
            }
        }
    }
}
fn no_signal(path: &Path) -> bool {
    std::fs::read(path).map_or(true, |b| {
        b.get(44..).map_or(true, |p| {
            p.chunks_exact(2)
                .all(|x| i16::from_le_bytes([x[0], x[1]]) == 0)
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Barrier, atomic::AtomicUsize};

    struct CountingDelivery(usize);
    impl Delivery for CountingDelivery {
        fn deliver(
            &mut self,
            _: &str,
            _: &config::OutputConfig,
        ) -> Result<desktop::DeliveryOutcome, String> {
            self.0 += 1;
            Ok(desktop::DeliveryOutcome::Typed)
        }
    }

    struct FailingDelivery;
    impl Delivery for FailingDelivery {
        fn deliver(
            &mut self,
            _: &str,
            _: &config::OutputConfig,
        ) -> Result<desktop::DeliveryOutcome, String> {
            Err("clipboard unavailable".into())
        }
    }

    #[test]
    fn no_speech_bypasses_delivery_and_transcript_delivers_once() {
        let mut delivery = CountingDelivery(0);
        let output = config::OutputConfig {
            method: config::OutputMethod::Type,
            trailing_space: false,
        };
        let no_speech = deliver_outcome(
            worker::Outcome::NoSpeech {
                processing_profile: config::ProcessingProfile::Verbatim,
                transport: worker::Transport::Stream,
            },
            &mut delivery,
            &output,
            Snapshot::default,
        );
        assert!(matches!(no_speech, DeliveryCompletion::NoSpeech));
        assert_eq!(delivery.0, 0);
        let delivered = deliver_outcome(
            worker::Outcome::Transcript {
                text: "hello".into(),
                processing_profile: config::ProcessingProfile::Clean,
                transport: worker::Transport::Rest,
                warning: None,
            },
            &mut delivery,
            &output,
            Snapshot::default,
        );
        assert!(matches!(delivered, DeliveryCompletion::Delivered { .. }));
        assert_eq!(delivery.0, 1);
    }

    #[test]
    fn transformation_warning_survives_delivery_failure() {
        let output = config::OutputConfig {
            method: config::OutputMethod::Type,
            trailing_space: false,
        };
        let completion = deliver_outcome(
            worker::Outcome::Transcript {
                text: "raw".into(),
                processing_profile: config::ProcessingProfile::Polished,
                transport: worker::Transport::Rest,
                warning: Some(worker::Warning::TransformationFailed),
            },
            &mut FailingDelivery,
            &output,
            Snapshot::default,
        );
        assert!(matches!(
            completion,
            DeliveryCompletion::Failed {
                ref error,
                warning: Some(worker::Warning::TransformationFailed),
            } if error == "clipboard unavailable"
        ));
    }

    #[test]
    fn concurrent_toggles_admit_exactly_one_mutation() {
        let (tx, rx) = mpsc::channel();
        let inner = Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(Snapshot::default())),
            admitted: Arc::new(AtomicU64::new(ADMISSION_NONE)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION)),
            restart_requested: Arc::new(AtomicU64::new(0)),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        });
        let controller = Controller(inner);
        let mutations = Arc::new(AtomicUsize::new(0));
        let count = mutations.clone();
        let worker = std::thread::spawn(move || {
            let Command::Toggle(_, reply) = rx.recv().unwrap() else {
                panic!()
            };
            count.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(Duration::from_millis(100));
            let _ = reply.send(Ok(Snapshot::default()));
        });
        let barrier = Arc::new(Barrier::new(3));
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let c = controller.clone();
                let b = barrier.clone();
                std::thread::spawn(move || {
                    b.wait();
                    c.toggle()
                })
            })
            .collect();
        barrier.wait();
        let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        worker.join().unwrap();
        assert_eq!(mutations.load(Ordering::SeqCst), 1);
        assert_eq!(
            results
                .iter()
                .filter(|r| matches!(r, Err(ToggleError::Busy)))
                .count(),
            1
        );
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    }

    #[test]
    fn concurrent_recording_toggles_admit_finish_and_queue_restart() {
        let (tx, rx) = mpsc::channel();
        let snapshot = Snapshot {
            state: State::Recording,
            ..Snapshot::default()
        };
        let restart_requested = Arc::new(AtomicU64::new(0));
        let admitted = Arc::new(AtomicU64::new(ADMISSION_NONE));
        let next_admission = Arc::new(AtomicU64::new(FIRST_ADMISSION));
        let controller = Controller(Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(snapshot)),
            admitted: admitted.clone(),
            next_admission: next_admission.clone(),
            restart_requested: restart_requested.clone(),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        }));
        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let mut restart_commands = 0;
            let reply = loop {
                match rx.recv().unwrap() {
                    Command::Toggle(State::Recording, reply) => break reply,
                    Command::RestartReady => restart_commands += 1,
                    _ => panic!(),
                }
            };
            accepted_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            let _ = reply.send(Ok(Snapshot::default()));
            if let Ok(command) = rx.try_recv() {
                assert!(matches!(command, Command::RestartReady));
                restart_commands += 1;
            }
            assert_eq!(restart_commands, 1);
        });
        let barrier = Arc::new(Barrier::new(3));
        let (result_tx, result_rx) = mpsc::channel();
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let controller = controller.clone();
                let barrier = barrier.clone();
                let results = result_tx.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    results.send(controller.toggle()).unwrap();
                })
            })
            .collect();
        drop(result_tx);

        barrier.wait();
        accepted_rx.recv().unwrap();
        assert_eq!(result_rx.recv().unwrap().unwrap().state, State::Recording);
        assert_eq!(restart_requested.load(Ordering::Acquire), 3);
        let finish_admission = admitted.load(Ordering::Acquire);
        assert!(is_finish_admission(finish_admission));
        let start_admission = next_admission.fetch_add(2, Ordering::AcqRel);
        assert_eq!(
            admitted.compare_exchange(
                finish_admission,
                start_admission,
                Ordering::AcqRel,
                Ordering::Acquire,
            ),
            Ok(finish_admission)
        );
        release_tx.send(()).unwrap();
        assert!(result_rx.recv().unwrap().is_ok());
        assert_eq!(admitted.load(Ordering::Acquire), start_admission);
        for handle in handles {
            handle.join().unwrap();
        }
        worker.join().unwrap();
    }

    #[test]
    fn toggle_while_finishing_queues_exactly_one_restart() {
        for (state, finish_admitted) in [
            (State::Recording, true),
            (State::Stopping, false),
            (State::Processing, false),
            (State::Delivering, false),
            (State::Success, false),
            (State::Error, false),
            (State::Cancelled, false),
        ] {
            let (tx, rx) = mpsc::channel();
            let snapshot = Snapshot {
                state,
                ..Snapshot::default()
            };
            let restart_requested = Arc::new(AtomicU64::new(0));
            let controller = Controller(Arc::new(Inner {
                tx,
                snapshot: Arc::new(Mutex::new(snapshot)),
                admitted: Arc::new(AtomicU64::new(if finish_admitted {
                    FIRST_ADMISSION | ADMISSION_FINISH_BIT
                } else {
                    ADMISSION_NONE
                })),
                next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION + 2)),
                restart_requested: restart_requested.clone(),
                shutdown: Arc::new(AtomicBool::new(false)),
                join: Mutex::new(None),
            }));

            assert_eq!(controller.toggle().unwrap().state, state);
            assert_eq!(restart_requested.load(Ordering::Acquire), 3);
            assert!(matches!(controller.toggle(), Err(ToggleError::Busy)));
            assert!(matches!(rx.try_recv(), Ok(Command::RestartReady)));
        }
    }

    #[test]
    fn stale_restart_request_cannot_attach_to_the_next_generation() {
        let (tx, rx) = mpsc::channel();
        let snapshot = Arc::new(Mutex::new(Snapshot {
            state: State::Recording,
            generation: 7,
            ..Snapshot::default()
        }));
        let restart_requested = Arc::new(AtomicU64::new(0));
        let controller = Controller(Arc::new(Inner {
            tx,
            snapshot: snapshot.clone(),
            admitted: Arc::new(AtomicU64::new(FIRST_ADMISSION | ADMISSION_FINISH_BIT)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION + 2)),
            restart_requested: restart_requested.clone(),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        }));

        *snapshot.lock().unwrap() = Snapshot {
            state: State::Recording,
            generation: 8,
            ..Snapshot::default()
        };

        assert!(matches!(
            controller.queue_restart(7),
            Err(ToggleError::Busy)
        ));
        assert_eq!(restart_requested.load(Ordering::Acquire), 0);
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn restart_reserved_during_terminal_expiry_retries_as_idle_start() {
        let (tx, rx) = mpsc::channel();
        let snapshot = Arc::new(Mutex::new(Snapshot {
            state: State::Success,
            generation: 7,
            ..Snapshot::default()
        }));
        let restart_requested = Arc::new(AtomicU64::new(0));
        let controller = Controller(Arc::new(Inner {
            tx,
            snapshot: snapshot.clone(),
            admitted: Arc::new(AtomicU64::new(ADMISSION_NONE)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION)),
            restart_requested: restart_requested.clone(),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        }));
        let mut locked_snapshot = snapshot.lock().unwrap();
        let queued_controller = controller.clone();
        let queued = std::thread::spawn(move || queued_controller.queue_restart(7));
        while restart_requested.load(Ordering::Acquire) == 0 {
            std::thread::yield_now();
        }
        *locked_snapshot = Snapshot {
            state: State::Idle,
            generation: 7,
            ..Snapshot::default()
        };
        drop(locked_snapshot);

        let Command::Toggle(State::Idle, reply) = rx.recv().unwrap() else {
            panic!()
        };
        let started = Snapshot {
            state: State::Recording,
            generation: 8,
            ..Snapshot::default()
        };
        reply.send(Ok(started.clone())).unwrap();

        let result = queued.join().unwrap().unwrap();
        assert_eq!(result.state, started.state);
        assert_eq!(result.generation, started.generation);
        assert_eq!(restart_requested.load(Ordering::Acquire), 0);
    }

    #[test]
    fn concurrent_reload_and_toggle_admit_exactly_one_mutation() {
        let (tx, rx) = mpsc::channel();
        let inner = Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(Snapshot::default())),
            admitted: Arc::new(AtomicU64::new(ADMISSION_NONE)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION)),
            restart_requested: Arc::new(AtomicU64::new(0)),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        });
        let controller = Controller(inner);
        let mutations = Arc::new(AtomicUsize::new(0));
        let count = mutations.clone();
        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let reply = match rx.recv().unwrap() {
                Command::Toggle(_, reply)
                | Command::Reload(reply)
                | Command::SetProcessingMode(_, reply)
                | Command::SetOutputMethod(_, reply) => reply,
                Command::RestartReady | Command::Shutdown => panic!(),
            };
            count.fetch_add(1, Ordering::SeqCst);
            accepted_tx.send(()).unwrap();
            release_rx.recv().unwrap();
            let _ = reply.send(Ok(Snapshot::default()));
        });
        let barrier = Arc::new(Barrier::new(3));
        let (result_tx, result_rx) = mpsc::channel();
        let reload = {
            let c = controller.clone();
            let b = barrier.clone();
            let results = result_tx.clone();
            std::thread::spawn(move || {
                b.wait();
                results.send(c.reload()).unwrap();
            })
        };
        let toggle = {
            let c = controller.clone();
            let b = barrier.clone();
            let results = result_tx;
            std::thread::spawn(move || {
                b.wait();
                results.send(c.toggle()).unwrap();
            })
        };
        barrier.wait();
        accepted_rx.recv().unwrap();
        assert!(matches!(result_rx.recv().unwrap(), Err(ToggleError::Busy)));
        release_tx.send(()).unwrap();
        assert!(result_rx.recv().unwrap().is_ok());
        worker.join().unwrap();
        reload.join().unwrap();
        toggle.join().unwrap();
        assert_eq!(mutations.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn reload_rejects_non_idle_state_without_dispatching() {
        let (tx, rx) = mpsc::channel();
        let mut snapshot = Snapshot::default();
        snapshot.state = State::Processing;
        let controller = Controller(Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(snapshot)),
            admitted: Arc::new(AtomicU64::new(ADMISSION_NONE)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION)),
            restart_requested: Arc::new(AtomicU64::new(0)),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        }));

        assert!(matches!(controller.reload(), Err(ToggleError::Busy)));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn processing_mode_change_rejects_active_session_without_dispatching() {
        let (tx, rx) = mpsc::channel();
        let mut snapshot = Snapshot::default();
        snapshot.state = State::Recording;
        let controller = Controller(Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(snapshot)),
            admitted: Arc::new(AtomicU64::new(ADMISSION_NONE)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION)),
            restart_requested: Arc::new(AtomicU64::new(0)),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        }));

        assert!(matches!(
            controller.set_processing_mode(config::ProcessingMode::Polished),
            Err(ToggleError::Busy)
        ));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn output_method_change_rejects_active_session_without_dispatching() {
        let (tx, rx) = mpsc::channel();
        let mut snapshot = Snapshot::default();
        snapshot.state = State::Recording;
        let controller = Controller(Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(snapshot)),
            admitted: Arc::new(AtomicU64::new(ADMISSION_NONE)),
            next_admission: Arc::new(AtomicU64::new(FIRST_ADMISSION)),
            restart_requested: Arc::new(AtomicU64::new(0)),
            shutdown: Arc::new(AtomicBool::new(false)),
            join: Mutex::new(None),
        }));

        assert!(matches!(
            controller.set_output_method(config::OutputMethod::Paste),
            Err(ToggleError::Busy)
        ));
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn transformation_warning_is_product_neutral() {
        assert_eq!(
            terminal_message(
                desktop::DeliveryOutcome::Typed,
                Some(worker::Warning::TransformationFailed)
            ),
            "transformation failed; safe fallback delivered"
        );
        assert_eq!(
            terminal_message(
                desktop::DeliveryOutcome::ClipboardFallback,
                Some(worker::Warning::TransformationFailed)
            ),
            "transformation failed; automatic insertion failed and safe fallback was copied to clipboard"
        );
    }

    #[test]
    fn reload_validation_recovers_after_invalid_configuration() {
        assert!(validate_reload(|| Ok(())).is_ok());
        let invalid = validate_reload::<()>(|| {
            Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "invalid config",
            ))
        });
        assert_eq!(invalid, Err(ToggleError::Failed("invalid config".into())));
        assert!(validate_reload(|| Ok(())).is_ok());
    }
}
