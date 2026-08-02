use crate::{capture, config};
use serde::Serialize;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
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
            message: None,
            level: None,
        }
    }
}

pub trait Processor: Send + 'static {
    fn process(&mut self, wav: &Path) -> Result<String, String>;
}
pub trait Delivery: Send + 'static {
    fn deliver(&mut self, text: &str) -> Result<(), String>;
}
pub struct PreviewProcessor;
impl Processor for PreviewProcessor {
    fn process(&mut self, _: &Path) -> Result<String, String> {
        Err("native preview processing is not ready (SAY-44)".into())
    }
}
pub struct PreviewDelivery;
impl Delivery for PreviewDelivery {
    fn deliver(&mut self, _: &str) -> Result<(), String> {
        Err("native preview delivery is not ready (SAY-45)".into())
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
    Shutdown,
}
struct Inner {
    tx: mpsc::Sender<Command>,
    snapshot: Arc<Mutex<Snapshot>>,
    admitted: Arc<AtomicBool>,
    join: Mutex<Option<JoinHandle<()>>>,
}
#[derive(Clone)]
pub struct Controller(Arc<Inner>);
impl Controller {
    pub fn spawn(
        root: PathBuf,
        processor: impl Processor,
        delivery: impl Delivery,
        updates: mpsc::Sender<Snapshot>,
    ) -> Self {
        let (tx, rx) = mpsc::channel();
        let snapshot = Arc::new(Mutex::new(Snapshot::default()));
        let shared = snapshot.clone();
        let admitted = Arc::new(AtomicBool::new(false));
        let worker_admitted = admitted.clone();
        let join = std::thread::spawn(move || {
            run(
                rx,
                shared,
                worker_admitted,
                root,
                Box::new(processor),
                Box::new(delivery),
                updates,
            )
        });
        Self(Arc::new(Inner {
            tx,
            snapshot,
            admitted,
            join: Mutex::new(Some(join)),
        }))
    }
    pub fn status(&self) -> Snapshot {
        self.0.snapshot.lock().unwrap().clone()
    }
    pub fn toggle(&self) -> Result<Snapshot, ToggleError> {
        let expected = self.status().state;
        if !matches!(expected, State::Idle | State::Recording) {
            return Err(ToggleError::Busy);
        }
        if self
            .0
            .admitted
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(ToggleError::Busy);
        }
        if self.status().state != expected {
            self.0.admitted.store(false, Ordering::Release);
            return Err(ToggleError::Busy);
        }
        let (tx, rx) = mpsc::channel();
        if self.0.tx.send(Command::Toggle(expected, tx)).is_err() {
            self.0.admitted.store(false, Ordering::Release);
            return Err(ToggleError::Unavailable);
        }
        let result = rx.recv().unwrap_or(Err(ToggleError::Unavailable));
        self.0.admitted.store(false, Ordering::Release);
        result
    }
    pub fn shutdown_and_join(&self) {
        let _ = self.0.tx.send(Command::Shutdown);
        if let Some(j) = self.0.join.lock().unwrap().take() {
            let _ = j.join();
        }
    }
}

fn run(
    rx: mpsc::Receiver<Command>,
    shared: Arc<Mutex<Snapshot>>,
    admitted: Arc<AtomicBool>,
    root: PathBuf,
    mut processor: Box<dyn Processor>,
    mut delivery: Box<dyn Delivery>,
    updates: mpsc::Sender<Snapshot>,
) {
    let mut generation = 0;
    let mut active: Option<(capture::Capture, Instant, config::RecordingConfig)> = None;
    let mut terminal_until: Option<Instant> = None;
    let publish = |state, g, started: Option<Instant>, message| {
        let s = Snapshot {
            state,
            generation: g,
            elapsed_ms: started.map_or(0, |x| x.elapsed().as_millis() as u64),
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
                if let Some((c, _, _)) = active.take() {
                    c.cancel();
                }
                break;
            }
            Ok(Command::Toggle(expected, reply)) => {
                let current = shared.lock().unwrap().state;
                let result = if current != expected {
                    Err(ToggleError::Busy)
                } else if expected == State::Idle && active.is_none() {
                    generation += 1;
                    publish(State::Starting, generation, None, None);
                    match config::load().and_then(|cfg| {
                        capture::Capture::start(&root, generation, &cfg.source).map(|c| (c, cfg))
                    }) {
                        Ok((c, cfg)) => {
                            let now = Instant::now();
                            active = Some((c, now, cfg));
                            Ok(publish(State::Recording, generation, Some(now), None))
                        }
                        Err(e) => {
                            let msg = format!("capture failed: {e}");
                            publish(State::Error, generation, None, Some(msg.clone()));
                            terminal_until = Some(Instant::now() + Duration::from_secs(2));
                            Err(ToggleError::Failed(msg))
                        }
                    }
                } else if expected == State::Recording && active.is_some() {
                    let result = finish_active(
                        &mut active,
                        generation,
                        &publish,
                        &mut *processor,
                        &mut *delivery,
                    );
                    terminal_until = Some(Instant::now() + Duration::from_secs(2));
                    result
                } else {
                    Err(ToggleError::Busy)
                };
                let _ = reply.send(result); // accepted work is completed even if the client left
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if active.is_none() && terminal_until.is_some_and(|until| Instant::now() >= until) {
                    terminal_until = None;
                    publish(State::Idle, generation, None, None);
                }
                if let Some((c, started, cfg)) = active.as_mut() {
                    if !c.alive().unwrap_or(false) {
                        let (c, _, _) = active.take().unwrap();
                        c.cancel();
                        publish(
                            State::Error,
                            generation,
                            None,
                            Some("capture process exited early".into()),
                        );
                        terminal_until = Some(Instant::now() + Duration::from_secs(2));
                    } else if started.elapsed() >= Duration::from_secs(cfg.max_seconds as u64) {
                        if admitted
                            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                            .is_ok()
                        {
                            let _ = finish_active(
                                &mut active,
                                generation,
                                &publish,
                                &mut *processor,
                                &mut *delivery,
                            );
                            terminal_until = Some(Instant::now() + Duration::from_secs(2));
                            admitted.store(false, Ordering::Release);
                        }
                    } else if let Ok(level) = c.level() {
                        let mut s = publish(State::Recording, generation, Some(*started), None);
                        s.level = Some(level);
                        *shared.lock().unwrap() = s.clone();
                        let _ = updates.send(s);
                    }
                }
            }
        }
    }
}

fn finish_active<F>(
    active: &mut Option<(capture::Capture, Instant, config::RecordingConfig)>,
    generation: u64,
    publish: &F,
    processor: &mut dyn Processor,
    delivery: &mut dyn Delivery,
) -> Result<Snapshot, ToggleError>
where
    F: Fn(State, u64, Option<Instant>, Option<String>) -> Snapshot,
{
    let (capture, started, cfg) = active.take().expect("active capture");
    publish(State::Stopping, generation, Some(started), None);
    let outcome = (|| -> Result<(), String> {
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
        publish(State::Processing, generation, Some(started), None);
        let text = processor.process(&cleanup.0)?;
        publish(State::Delivering, generation, Some(started), None);
        delivery.deliver(&text)
    })();
    match outcome {
        Ok(()) => Ok(publish(
            State::Success,
            generation,
            None,
            Some("delivery completed".into()),
        )),
        Err(message) => {
            let s = publish(State::Error, generation, None, Some(message.clone()));
            let _ = s;
            Err(ToggleError::Failed(message))
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

    #[test]
    fn concurrent_toggles_admit_exactly_one_mutation() {
        let (tx, rx) = mpsc::channel();
        let inner = Arc::new(Inner {
            tx,
            snapshot: Arc::new(Mutex::new(Snapshot::default())),
            admitted: Arc::new(AtomicBool::new(false)),
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
}
