mod protocol;

use gtk::cairo;
use gtk::glib;
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow, DrawingArea};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use protocol::{EventKind, ProcessingStage, ProtocolEvent, State, StateSnapshot};
use serde_json::json;
use std::cell::RefCell;
use std::collections::VecDeque;
use std::env;
use std::io::{self, BufReader, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::{Duration, Instant};

const APP_ID: &str = "dev.sayall.Hud";
const BAR_COUNT: usize = 18;

#[derive(Debug)]
enum UiMessage {
    Snapshot(StateSnapshot),
    Event(ProtocolEvent),
    Disconnected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HudState {
    Idle,
    Recording,
    Stopping,
    Processing,
    Success,
    Error,
}

struct Model {
    state: HudState,
    stage: String,
    history: VecDeque<f64>,
    displayed: [f64; BAR_COUNT],
    recording_started: Option<Instant>,
    hide_at: Option<Instant>,
    clipping_until: Option<Instant>,
    error: String,
}

impl Default for Model {
    fn default() -> Self {
        Self {
            state: HudState::Idle,
            stage: String::new(),
            history: VecDeque::from(vec![0.0; BAR_COUNT]),
            displayed: [0.0; BAR_COUNT],
            recording_started: None,
            hide_at: None,
            clipping_until: None,
            error: String::new(),
        }
    }
}

impl Model {
    fn apply_event(&mut self, event: ProtocolEvent) {
        match event.kind {
            EventKind::StateChanged(snapshot) => self.apply_state(&snapshot),
            EventKind::AudioLevel(data) => {
                let level = (data.rms * 2.2).max(data.peak * 0.72).clamp(0.0, 1.0);
                self.history.pop_front();
                self.history.push_back(level);
                if data.clipping {
                    self.clipping_until = Some(Instant::now() + Duration::from_millis(350));
                }
            }
            EventKind::ProcessingStageChanged(data) => {
                self.stage = data.stage.0.map_or("", ProcessingStage::as_str).to_owned();
            }
            EventKind::OperationError(error) => {
                self.state = HudState::Error;
                self.error = error.message;
                self.hide_at = Some(Instant::now() + Duration::from_secs(3));
            }
            EventKind::SessionCompleted(data) => {
                if data.ok {
                    self.state = HudState::Success;
                    self.hide_at = Some(Instant::now() + Duration::from_millis(700));
                }
            }
            EventKind::RecordingLimitReached(_)
            | EventKind::OutputCompleted(_)
            | EventKind::Unknown { .. } => {}
        }
    }

    fn apply_state(&mut self, snapshot: &StateSnapshot) {
        let previous = self.state;
        let next = match snapshot.state {
            State::Idle => HudState::Idle,
            State::Recording => HudState::Recording,
            State::Stopping => HudState::Stopping,
            State::Processing => HudState::Processing,
        };
        if next == HudState::Idle
            && matches!(previous, HudState::Success | HudState::Error)
            && self
                .hide_at
                .is_some_and(|deadline| deadline > Instant::now())
        {
            return;
        }
        self.state = next;
        self.stage = snapshot
            .stage
            .0
            .map_or("", ProcessingStage::as_str)
            .to_owned();
        if self.state == HudState::Recording && previous != HudState::Recording {
            self.recording_started = Some(Instant::now());
            for value in &mut self.history {
                *value = 0.0;
            }
            self.displayed.fill(0.0);
            self.hide_at = None;
        }
        if self.state == HudState::Idle && !matches!(previous, HudState::Success | HudState::Error)
        {
            self.recording_started = None;
        }
    }

    fn animate(&mut self) {
        for (displayed, target) in self.displayed.iter_mut().zip(self.history.iter()) {
            let speed = if *target > *displayed { 0.48 } else { 0.18 };
            *displayed += (*target - *displayed) * speed;
        }
        if self
            .hide_at
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            self.state = HudState::Idle;
            self.hide_at = None;
        }
    }

    fn visible(&self) -> bool {
        self.state != HudState::Idle
    }
}

fn main() -> glib::ExitCode {
    let app = Application::builder().application_id(APP_ID).build();
    app.connect_activate(build_ui);
    app.run()
}

fn build_ui(app: &Application) {
    let model = Rc::new(RefCell::new(Model::default()));
    let window = ApplicationWindow::builder()
        .application(app)
        .title("SayAll")
        .decorated(false)
        .resizable(false)
        .default_width(280)
        .default_height(64)
        .build();

    let css = gtk::CssProvider::new();
    css.load_from_data("window { background-color: transparent; }");
    gtk::style_context_add_provider_for_display(
        &gtk::gdk::Display::default().expect("a graphical display"),
        &css,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    window.init_layer_shell();
    window.set_namespace(Some("sayall-hud"));
    window.set_layer(Layer::Overlay);
    window.set_keyboard_mode(KeyboardMode::None);
    window.set_anchor(Edge::Bottom, true);
    window.set_margin(Edge::Bottom, 52);
    window.set_exclusive_zone(-1);

    let drawing = DrawingArea::builder()
        .width_request(280)
        .height_request(64)
        .can_target(false)
        .build();
    window.set_child(Some(&drawing));

    let draw_model = model.clone();
    drawing.set_draw_func(move |_, cr, width, height| {
        draw_hud(cr, width, height, &draw_model.borrow())
    });

    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || connection_loop(sender));
    install_tick(&window, &drawing, model, receiver);
    window.set_visible(false);
}

fn install_tick(
    window: &ApplicationWindow,
    drawing: &DrawingArea,
    model: Rc<RefCell<Model>>,
    receiver: Receiver<UiMessage>,
) {
    let window = window.clone();
    let drawing = drawing.clone();
    glib::timeout_add_local(Duration::from_millis(16), move || {
        while let Ok(message) = receiver.try_recv() {
            match message {
                UiMessage::Snapshot(snapshot) => model.borrow_mut().apply_state(&snapshot),
                UiMessage::Event(event) => model.borrow_mut().apply_event(event),
                UiMessage::Disconnected => {
                    let mut model = model.borrow_mut();
                    if model.state != HudState::Idle {
                        model.state = HudState::Error;
                        model.error = "SayAll daemon disconnected".to_owned();
                        model.hide_at = Some(Instant::now() + Duration::from_secs(2));
                    }
                }
            }
        }
        model.borrow_mut().animate();
        let visible = model.borrow().visible();
        window.set_visible(visible);
        if visible {
            drawing.queue_draw();
        }
        glib::ControlFlow::Continue
    });
}

fn connection_loop(sender: Sender<UiMessage>) {
    let mut backoff = Duration::from_millis(200);
    loop {
        match subscribe(&sender) {
            Ok(()) => backoff = Duration::from_millis(200),
            Err(_) => {
                let _ = sender.send(UiMessage::Disconnected);
                thread::sleep(backoff);
                backoff = (backoff * 2).min(Duration::from_secs(5));
            }
        }
    }
}

fn subscribe(sender: &Sender<UiMessage>) -> std::io::Result<()> {
    const REQUEST_ID: u64 = 1;

    let mut stream = UnixStream::connect(socket_path()?)?;
    let request = json!({"v":1,"type":"request","id":REQUEST_ID,"method":"subscribe","params":{}});
    writeln!(stream, "{request}")?;
    let mut reader = BufReader::new(stream);
    let mut storage = [0; protocol::MAX_FRAME_LEN];
    let mut decoder = protocol::SubscriptionDecoder::new(REQUEST_ID);
    loop {
        let frame = protocol::read_frame(&mut reader, &mut storage)?;
        let message = match decoder.decode(frame)? {
            protocol::SubscriptionMessage::Snapshot(snapshot) => {
                UiMessage::Snapshot(snapshot.state)
            }
            protocol::SubscriptionMessage::Event(event) => UiMessage::Event(event),
        };
        if sender.send(message).is_err() {
            return Ok(());
        }
    }
}

fn socket_path() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("SAYALL_SOCKET") {
        let path = PathBuf::from(path);
        validate_socket_path(&path)?;
        return Ok(path);
    }
    if let Some(dir) = env::var_os("XDG_RUNTIME_DIR") {
        return Ok(PathBuf::from(dir).join("sayall.sock"));
    }
    let uid = unsafe { libc::geteuid() };
    Ok(PathBuf::from(format!("/tmp/sayall-{uid}.sock")))
}

fn validate_socket_path(path: &Path) -> io::Result<()> {
    // Linux sockaddr_un.sun_path has 108 bytes and needs a trailing NUL.
    const UNIX_PATH_MAX: usize = 108;
    let bytes = path.as_os_str().as_bytes();
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "unsafe SAYALL_SOCKET path");
    if !path.is_absolute()
        || bytes.is_empty()
        || bytes.len() >= UNIX_PATH_MAX
        || bytes.last() == Some(&b'/')
        || bytes.iter().any(u8::is_ascii_control)
    {
        return Err(invalid());
    }
    let mut segments = bytes.split(|byte| *byte == b'/');
    if segments.next() != Some(&b""[..]) {
        return Err(invalid());
    }
    let remaining: Vec<_> = segments.collect();
    if remaining.len() < 2
        || remaining
            .iter()
            .any(|segment| segment.is_empty() || *segment == b"." || *segment == b"..")
    {
        return Err(invalid());
    }
    Ok(())
}

fn draw_hud(cr: &cairo::Context, width: i32, height: i32, model: &Model) {
    let width = f64::from(width);
    let height = f64::from(height);
    rounded_rect(cr, 0.5, 0.5, width - 1.0, height - 1.0, height / 2.0);
    cr.set_source_rgba(0.055, 0.06, 0.075, 0.94);
    let _ = cr.fill_preserve();
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.10);
    cr.set_line_width(1.0);
    let _ = cr.stroke();

    match model.state {
        HudState::Recording => draw_recording(cr, width, height, model),
        HudState::Success => {
            draw_center_text(cr, width, height, "✓  Dictation complete", 0.42, 0.92, 0.62)
        }
        HudState::Error => draw_center_text(cr, width, height, &model.error, 1.0, 0.45, 0.45),
        HudState::Stopping => draw_center_text(cr, width, height, "Finishing…", 0.92, 0.92, 0.96),
        HudState::Processing => {
            let label = match model.stage.as_str() {
                "transcribing" => "Transcribing…",
                "cleaning" => "Cleaning up…",
                "delivering" => "Typing…",
                _ => "Processing…",
            };
            draw_center_text(cr, width, height, label, 0.92, 0.92, 0.96);
        }
        HudState::Idle => {}
    }
}

fn draw_recording(cr: &cairo::Context, width: f64, height: f64, model: &Model) {
    cr.arc(25.0, height / 2.0, 5.0, 0.0, std::f64::consts::TAU);
    cr.set_source_rgb(1.0, 0.25, 0.32);
    let _ = cr.fill();

    let clipping = model
        .clipping_until
        .is_some_and(|deadline| deadline > Instant::now());
    let (r, g, b) = if clipping {
        (1.0, 0.63, 0.22)
    } else {
        (0.98, 0.34, 0.48)
    };
    let start_x = 48.0;
    let visualizer_width = width - 112.0;
    let gap = 3.0;
    let bar_width = (visualizer_width - gap * (BAR_COUNT as f64 - 1.0)) / BAR_COUNT as f64;
    for (index, level) in model.displayed.iter().enumerate() {
        let shaped = (level * (0.72 + 0.28 * ((index as f64 * 1.7).sin().abs()))).clamp(0.0, 1.0);
        let bar_height = 5.0 + shaped * 31.0;
        let x = start_x + index as f64 * (bar_width + gap);
        rounded_rect(
            cr,
            x,
            (height - bar_height) / 2.0,
            bar_width,
            bar_height,
            bar_width / 2.0,
        );
        cr.set_source_rgb(r, g, b);
        let _ = cr.fill();
    }

    let elapsed = model
        .recording_started
        .map_or(0, |started| started.elapsed().as_secs());
    let label = format!("{:02}:{:02}", elapsed / 60, elapsed % 60);
    cr.set_source_rgba(0.92, 0.92, 0.96, 0.82);
    cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    cr.set_font_size(12.0);
    cr.move_to(width - 51.0, height / 2.0 + 4.0);
    let _ = cr.show_text(&label);
}

fn draw_center_text(
    cr: &cairo::Context,
    width: f64,
    height: f64,
    text: &str,
    r: f64,
    g: f64,
    b: f64,
) {
    cr.select_font_face("Sans", cairo::FontSlant::Normal, cairo::FontWeight::Bold);
    cr.set_font_size(if text.len() > 30 { 11.0 } else { 13.0 });
    cr.set_source_rgb(r, g, b);
    let extents = cr.text_extents(text).ok();
    let text_width = extents.as_ref().map_or(0.0, cairo::TextExtents::width);
    cr.move_to((width - text_width) / 2.0, height / 2.0 + 4.5);
    let _ = cr.show_text(text);
}

fn rounded_rect(cr: &cairo::Context, x: f64, y: f64, width: f64, height: f64, radius: f64) {
    let radius = radius.min(width / 2.0).min(height / 2.0);
    cr.new_sub_path();
    cr.arc(
        x + width - radius,
        y + radius,
        radius,
        -std::f64::consts::FRAC_PI_2,
        0.0,
    );
    cr.arc(
        x + width - radius,
        y + height - radius,
        radius,
        0.0,
        std::f64::consts::FRAC_PI_2,
    );
    cr.arc(
        x + radius,
        y + height - radius,
        radius,
        std::f64::consts::FRAC_PI_2,
        std::f64::consts::PI,
    );
    cr.arc(
        x + radius,
        y + radius,
        radius,
        std::f64::consts::PI,
        std::f64::consts::PI * 1.5,
    );
    cr.close_path();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decoder_with_idle_snapshot() -> protocol::SubscriptionDecoder {
        let mut decoder = protocol::SubscriptionDecoder::new(1);
        decoder
            .decode(
                br#"{"v":1,"type":"response","id":1,"ok":true,"result":{"state":{"state":"idle","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true},"next_seq":1}}"#,
            )
            .unwrap();
        decoder
    }

    fn decode_event(decoder: &mut protocol::SubscriptionDecoder, frame: &[u8]) -> ProtocolEvent {
        let protocol::SubscriptionMessage::Event(event) = decoder.decode(frame).unwrap() else {
            panic!("expected event")
        };
        event
    }

    #[test]
    fn model_tracks_recording_and_levels() {
        let mut model = Model::default();
        let mut decoder = decoder_with_idle_snapshot();
        let state = decode_event(
            &mut decoder,
            br#"{"v":1,"type":"event","seq":1,"event":"state.changed","session_id":1,"data":{"state":"recording","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true}}"#,
        );
        model.apply_event(state);
        assert_eq!(model.state, HudState::Recording);
        let level = decode_event(
            &mut decoder,
            br#"{"v":1,"type":"event","seq":2,"event":"audio.level","session_id":1,"data":{"rms":0.2,"peak":0.5,"clipping":false,"window_ms":100}}"#,
        );
        model.apply_event(level);
        assert!(model.history.back().copied().unwrap_or_default() > 0.3);
    }

    #[test]
    fn error_survives_following_idle_state_until_timeout() {
        let mut model = Model::default();
        let mut decoder = decoder_with_idle_snapshot();
        let error = decode_event(
            &mut decoder,
            br#"{"v":1,"type":"event","seq":1,"event":"operation.error","session_id":1,"data":{"code":"failed","message":"Network failed"}}"#,
        );
        model.apply_event(error);
        let idle = decode_event(
            &mut decoder,
            br#"{"v":1,"type":"event","seq":2,"event":"state.changed","session_id":1,"data":{"state":"idle","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true}}"#,
        );
        model.apply_event(idle);
        assert_eq!(model.state, HudState::Error);
    }

    #[test]
    fn socket_override_validation_matches_safe_filesystem_paths() {
        assert!(validate_socket_path(Path::new("/tmp/private/sayall.sock")).is_ok());
        for invalid in [
            "relative.sock",
            "/sayall.sock",
            "/tmp/../sayall.sock",
            "/tmp//sayall.sock",
            "/tmp/private/",
            "/tmp/private/socket\n.sock",
        ] {
            assert!(
                validate_socket_path(Path::new(invalid)).is_err(),
                "{invalid}"
            );
        }
    }
}
