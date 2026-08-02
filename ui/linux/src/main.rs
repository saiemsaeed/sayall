mod autostart;
mod capture;
mod config;
mod control;
mod desktop;
mod protocol;
mod runtime;
mod session;
mod settings;
mod worker;

use gtk::cairo;
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow, DrawingArea};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use protocol::{EventKind, OutputMethod, ProtocolEvent, State, StateSnapshot};
use serde_json::json;
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::env;
use std::io::{self, BufReader, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

const APP_ID: &str = "dev.sayall.Hud";
const BAR_COUNT: usize = 14;
const HUD_WIDTH: i32 = 244;
const HUD_HEIGHT: i32 = 48;
const PROCESSING_BAR_COUNT: usize = 10;

#[derive(Clone, Copy)]
struct Palette {
    shell: (f64, f64, f64, f64),
    border: (f64, f64, f64, f64),
    text: (f64, f64, f64, f64),
    wave: (f64, f64, f64),
    dot: (f64, f64, f64),
    processing: (f64, f64, f64),
    success: (f64, f64, f64),
    error: (f64, f64, f64),
}

const PALETTES: [Palette; 2] = [
    Palette {
        shell: (14.0 / 255.0, 15.0 / 255.0, 19.0 / 255.0, 0.94),
        border: (1.0, 1.0, 1.0, 0.10),
        text: (1.0, 1.0, 1.0, 0.82),
        wave: (250.0 / 255.0, 87.0 / 255.0, 122.0 / 255.0),
        dot: (1.0, 64.0 / 255.0, 82.0 / 255.0),
        processing: (76.0 / 255.0, 214.0 / 255.0, 209.0 / 255.0),
        success: (107.0 / 255.0, 235.0 / 255.0, 158.0 / 255.0),
        error: (1.0, 115.0 / 255.0, 115.0 / 255.0),
    },
    Palette {
        shell: (1.0, 1.0, 1.0, 1.0),
        border: (14.0 / 255.0, 15.0 / 255.0, 19.0 / 255.0, 0.12),
        text: (52.0 / 255.0, 64.0 / 255.0, 84.0 / 255.0, 1.0),
        wave: (217.0 / 255.0, 45.0 / 255.0, 94.0 / 255.0),
        dot: (225.0 / 255.0, 29.0 / 255.0, 72.0 / 255.0),
        processing: (8.0 / 255.0, 127.0 / 255.0, 140.0 / 255.0),
        success: (6.0 / 255.0, 118.0 / 255.0, 71.0 / 255.0),
        error: (217.0 / 255.0, 45.0 / 255.0, 32.0 / 255.0),
    },
];
const DARK: Palette = PALETTES[0];

#[derive(Debug)]
enum UiMessage {
    Snapshot(StateSnapshot),
    Event(ProtocolEvent),
    Disconnected,
    Native(session::Snapshot),
}

struct NativeContext {
    _ownership: runtime::Ownership,
    controller: session::Controller,
    server: control::Server,
    updates: Mutex<Option<Receiver<session::Snapshot>>>,
}
static NATIVE: OnceLock<Mutex<Option<NativeContext>>> = OnceLock::new();

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
    native_generation: Option<u64>,
    state: HudState,
    history: VecDeque<f64>,
    displayed: [f64; BAR_COUNT],
    recording_started: Option<Instant>,
    processing_started: Option<Instant>,
    hide_at: Option<Instant>,
    clipping_until: Option<Instant>,
    output_method: Option<OutputMethod>,
    show_timer: bool,
    error: String,
    success_message: String,
}

impl Default for Model {
    fn default() -> Self {
        Self {
            native_generation: None,
            state: HudState::Idle,
            history: VecDeque::from(vec![0.0; BAR_COUNT]),
            displayed: [0.0; BAR_COUNT],
            recording_started: None,
            processing_started: None,
            hide_at: None,
            clipping_until: None,
            output_method: None,
            show_timer: true,
            error: String::new(),
            success_message: "Copied to clipboard".to_owned(),
        }
    }
}

impl Model {
    fn apply_native_terminal(&mut self, snapshot: &session::Snapshot) -> bool {
        if self.native_generation != Some(snapshot.generation) {
            self.native_generation = Some(snapshot.generation);
            self.recording_started = None;
            self.processing_started = None;
            self.hide_at = None;
            self.clipping_until = None;
            self.error.clear();
            self.success_message = "Copied to clipboard".to_owned();
            for value in &mut self.history {
                *value = 0.0;
            }
            self.displayed.fill(0.0);
        }
        if snapshot.state == session::State::Idle
            && matches!(self.state, HudState::Success | HudState::Error)
            && self
                .hide_at
                .is_some_and(|deadline| deadline > Instant::now())
        {
            return false;
        }
        self.state = match snapshot.state {
            session::State::Idle => HudState::Idle,
            session::State::Starting | session::State::Recording => HudState::Recording,
            session::State::Stopping => HudState::Stopping,
            session::State::Processing | session::State::Delivering => HudState::Processing,
            session::State::Success => HudState::Success,
            session::State::Error | session::State::Cancelled => HudState::Error,
        };
        if let Some(message) = &snapshot.message {
            if snapshot.state == session::State::Success {
                self.success_message.clone_from(message);
            } else {
                self.error.clone_from(message);
            }
        }
        if matches!(
            snapshot.state,
            session::State::Success | session::State::Error | session::State::Cancelled
        ) {
            self.hide_at = Some(Instant::now() + Duration::from_secs(2));
        }
        true
    }

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
            EventKind::ProcessingStageChanged => {}
            EventKind::OperationError(message) => {
                self.state = HudState::Error;
                self.error = message;
                self.hide_at = Some(Instant::now() + Duration::from_secs(3));
            }
            EventKind::OutputCompleted(method) => self.output_method = Some(method),
            EventKind::SessionCompleted(ok) => {
                if ok && self.output_method == Some(OutputMethod::Clipboard) {
                    self.state = HudState::Success;
                    self.hide_at = Some(Instant::now() + Duration::from_millis(700));
                } else if ok {
                    self.state = HudState::Idle;
                    self.hide_at = None;
                }
            }
            EventKind::RecordingLimitReached | EventKind::Unknown => {}
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
        self.show_timer = snapshot.show_timer;
        if next == HudState::Idle
            && matches!(previous, HudState::Stopping | HudState::Processing)
            && self.output_method == Some(OutputMethod::Clipboard)
        {
            return;
        }
        if next == HudState::Idle
            && matches!(previous, HudState::Success | HudState::Error)
            && self
                .hide_at
                .is_some_and(|deadline| deadline > Instant::now())
        {
            return;
        }
        self.state = next;
        if self.state == HudState::Recording && previous != HudState::Recording {
            self.recording_started =
                Instant::now().checked_sub(Duration::from_millis(snapshot.elapsed_ms));
            for value in &mut self.history {
                *value = 0.0;
            }
            self.displayed.fill(0.0);
            self.hide_at = None;
            self.output_method = None;
        }
        if matches!(self.state, HudState::Stopping | HudState::Processing)
            && !matches!(previous, HudState::Stopping | HudState::Processing)
        {
            self.processing_started = Some(Instant::now());
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
    let native = env::args_os()
        .skip(1)
        .any(|arg| arg == "--native-host-preview");
    let autostart = env::args_os().skip(1).any(|arg| arg == "--autostart");
    let application_id = if native {
        "dev.sayall.Hud.NativePreview"
    } else {
        APP_ID
    };
    let app = Application::builder()
        .application_id(application_id)
        .build();
    if native {
        let settings_action = gio::SimpleAction::new("settings", None);
        let settings_app = app.clone();
        settings_action.connect_activate(move |_, _| settings::show(&settings_app));
        app.add_action(&settings_action);
    }
    let built = Rc::new(Cell::new(false));
    let suppress_settings_once = Rc::new(Cell::new(autostart));
    app.connect_activate(move |app| {
        if !built.replace(true) {
            build_ui(app);
        }
        let silent = suppress_settings_once.replace(false);
        if native && !silent {
            settings::show(app);
        }
    });
    app.connect_shutdown(|_| shutdown_native_host());
    let exit = if native {
        if let Err(error) = app.register(None::<&gio::Cancellable>) {
            eprintln!("sayall-hud: application registration failed: {error}");
            return glib::ExitCode::FAILURE;
        }
        if app.is_remote() && autostart {
            return glib::ExitCode::SUCCESS;
        }
        if !app.is_remote() {
            if let Err(error) = start_native_host() {
                eprintln!("sayall-hud: native host preview unavailable: {error}");
                return glib::ExitCode::FAILURE;
            }
        }
        let program = env::args_os()
            .next()
            .map(|arg| arg.to_string_lossy().into_owned())
            .unwrap_or_else(|| "sayall-hud".to_owned());
        app.run_with_args(&[program])
    } else {
        app.run()
    };
    shutdown_native_host();
    exit
}

fn shutdown_native_host() {
    if let Some(native) = NATIVE.get().and_then(|slot| slot.lock().unwrap().take()) {
        let NativeContext {
            _ownership,
            controller,
            mut server,
            updates: _,
        } = native;
        controller.shutdown_and_join();
        server.shutdown_and_join();
        drop(_ownership);
    }
}

fn start_native_host() -> io::Result<()> {
    let ownership = runtime::Ownership::acquire(socket_path()?)?;
    let root = runtime::session_root()?;
    let (tx, rx) = mpsc::channel();
    let controller = session::Controller::spawn(root, desktop::NativeDelivery::new(), tx);
    let socket = ownership.socket.clone();
    let server = match control::Server::bind(&socket, controller.clone()) {
        Ok(server) => server,
        Err(error) => {
            controller.shutdown_and_join();
            return Err(error);
        }
    };
    NATIVE
        .set(Mutex::new(Some(NativeContext {
            _ownership: ownership,
            controller,
            server,
            updates: Mutex::new(Some(rx)),
        })))
        .map_err(|_| {
            io::Error::new(
                io::ErrorKind::AlreadyExists,
                "native host already initialized",
            )
        })
}

fn build_ui(app: &Application) {
    let model = Rc::new(RefCell::new(Model::default()));
    let window = ApplicationWindow::builder()
        .application(app)
        .title("SayAll")
        .decorated(false)
        .resizable(false)
        .default_width(HUD_WIDTH)
        .default_height(HUD_HEIGHT)
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
        .width_request(HUD_WIDTH)
        .height_request(HUD_HEIGHT)
        .can_target(false)
        .build();
    window.set_child(Some(&drawing));

    let draw_model = model.clone();
    drawing.set_draw_func(move |_, cr, width, height| {
        draw_hud(cr, width, height, &draw_model.borrow())
    });

    let (sender, receiver) = mpsc::channel();
    if let Some(native) = NATIVE.get().and_then(|slot| {
        slot.lock()
            .unwrap()
            .as_ref()
            .and_then(|native| native.updates.lock().unwrap().take())
    }) {
        {
            let updates = native;
            thread::spawn(move || {
                while let Ok(snapshot) = updates.recv() {
                    if sender.send(UiMessage::Native(snapshot)).is_err() {
                        break;
                    }
                }
            });
        }
    } else {
        thread::spawn(move || connection_loop(sender));
    }
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
                UiMessage::Native(snapshot) => {
                    let mut model = model.borrow_mut();
                    if !model.apply_native_terminal(&snapshot) {
                        continue;
                    }
                    if matches!(
                        snapshot.state,
                        session::State::Processing | session::State::Delivering
                    ) && model.processing_started.is_none()
                    {
                        model.processing_started = Some(Instant::now());
                    }
                    if let Some(level) = snapshot.level {
                        let value = (level.rms * 2.2).max(level.peak * 0.72).clamp(0.0, 1.0);
                        model.history.pop_front();
                        model.history.push_back(value);
                        if level.clipping {
                            model.clipping_until =
                                Some(Instant::now() + Duration::from_millis(350));
                        }
                    }
                    if snapshot.state == session::State::Recording
                        && model.recording_started.is_none()
                    {
                        model.recording_started =
                            Instant::now().checked_sub(Duration::from_millis(snapshot.elapsed_ms));
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
    set_rgba(cr, DARK.shell);
    let _ = cr.fill_preserve();
    set_rgba(cr, DARK.border);
    cr.set_line_width(1.0);
    let _ = cr.stroke();

    match model.state {
        HudState::Recording => draw_recording(cr, width, height, model),
        HudState::Stopping | HudState::Processing => draw_processing(cr, width, height, model),
        HudState::Success => draw_success(cr, width, height, &model.success_message),
        HudState::Error => draw_center_text(cr, width, height, &model.error, DARK.error),
        HudState::Idle => {}
    }
}

fn draw_recording(cr: &cairo::Context, width: f64, height: f64, model: &Model) {
    const REFERENCE_HEIGHTS: [f64; BAR_COUNT] = [
        5.0, 9.0, 14.0, 20.0, 12.0, 24.0, 17.0, 22.0, 10.0, 16.0, 24.0, 14.0, 8.0, 5.0,
    ];
    let content_width = 8.0 + 16.0 + 138.0 + if model.show_timer { 16.0 + 34.0 } else { 0.0 };
    let content_x = (width - content_width) / 2.0;

    cr.arc(
        content_x + 4.0,
        height / 2.0,
        4.0,
        0.0,
        std::f64::consts::TAU,
    );
    set_rgb(cr, DARK.dot);
    let _ = cr.fill();

    let clipping = model
        .clipping_until
        .is_some_and(|deadline| deadline > Instant::now());
    let color = if clipping { DARK.error } else { DARK.wave };
    let start_x = content_x + 24.0;
    let visualizer_width = 138.0;
    let bar_width = 4.5;
    let gap = (visualizer_width - bar_width * BAR_COUNT as f64) / (BAR_COUNT - 1) as f64;
    for (index, level) in model.displayed.iter().enumerate() {
        let bar_height = 5.0 + level.clamp(0.0, 1.0) * (REFERENCE_HEIGHTS[index] - 5.0);
        let x = start_x + index as f64 * (bar_width + gap);
        rounded_rect(
            cr,
            x,
            (height - bar_height) / 2.0,
            bar_width,
            bar_height,
            bar_width / 2.0,
        );
        set_rgb(cr, color);
        let _ = cr.fill();
    }

    if model.show_timer {
        let elapsed = model
            .recording_started
            .map_or(0, |started| started.elapsed().as_secs());
        let label = format!("{:02}:{:02}", elapsed / 60, elapsed % 60);
        select_bold_font(cr, 12.0);
        set_rgba(cr, DARK.text);
        let timer_x = start_x + visualizer_width + 16.0;
        draw_tracked_text_right_aligned(cr, &label, timer_x, 34.0, height / 2.0 + 4.0, 0.2);
    }
}

fn draw_processing(cr: &cairo::Context, width: f64, height: f64, model: &Model) {
    const REFERENCE_HEIGHTS: [f64; PROCESSING_BAR_COUNT] =
        [6.0, 10.0, 16.0, 22.0, 14.0, 8.0, 18.0, 24.0, 14.0, 8.0];
    let bar_width = 4.5;
    let gap = 5.0;
    let waveform_width =
        PROCESSING_BAR_COUNT as f64 * bar_width + (PROCESSING_BAR_COUNT - 1) as f64 * gap;
    let start_x = (width - waveform_width) / 2.0;
    let elapsed_ms = model
        .processing_started
        .map_or(0, |started| started.elapsed().as_millis() as u64);

    for (index, reference_height) in REFERENCE_HEIGHTS.iter().enumerate() {
        let phase_ms = (elapsed_ms + index as u64 * 120) % 2000;
        let activity = if phase_ms < 1600 {
            (std::f64::consts::PI * phase_ms as f64 / 1600.0).sin()
        } else {
            0.0
        };
        let bar_height = 4.0 + activity * (reference_height - 4.0);
        rounded_rect(
            cr,
            start_x + index as f64 * (bar_width + gap),
            (height - bar_height) / 2.0,
            bar_width,
            bar_height,
            2.0,
        );
        set_rgb(cr, DARK.processing);
        let _ = cr.fill();
    }
}

fn draw_success(cr: &cairo::Context, width: f64, height: f64, label: &str) {
    select_bold_font(cr, 13.0);
    let text_width = cr
        .text_extents(label)
        .map_or(0.0, |extents| extents.x_advance());
    let gap = cr
        .text_extents("  ")
        .map_or(8.0, |extents| extents.x_advance());
    let check_width = 11.0;
    let start_x = (width - check_width - gap - text_width) / 2.0;
    let center_y = height / 2.0;

    cr.move_to(start_x, center_y);
    cr.line_to(start_x + 3.5, center_y + 3.5);
    cr.line_to(start_x + check_width, center_y - 4.0);
    cr.set_line_cap(cairo::LineCap::Round);
    cr.set_line_join(cairo::LineJoin::Round);
    cr.set_line_width(1.8);
    set_rgb(cr, DARK.success);
    let _ = cr.stroke();

    cr.move_to(start_x + check_width + gap, center_y + 4.5);
    let _ = cr.show_text(label);
}

fn draw_center_text(
    cr: &cairo::Context,
    width: f64,
    height: f64,
    text: &str,
    color: (f64, f64, f64),
) {
    cr.select_font_face(
        "Noto Sans",
        cairo::FontSlant::Normal,
        cairo::FontWeight::Bold,
    );
    cr.set_font_size(if text.len() > 30 { 11.0 } else { 13.0 });
    set_rgb(cr, color);
    let extents = cr.text_extents(text).ok();
    let text_width = extents.as_ref().map_or(0.0, cairo::TextExtents::x_advance);
    cr.move_to((width - text_width) / 2.0, height / 2.0 + 4.5);
    let _ = cr.show_text(text);
}

fn select_bold_font(cr: &cairo::Context, size: f64) {
    cr.select_font_face(
        "Noto Sans",
        cairo::FontSlant::Normal,
        cairo::FontWeight::Bold,
    );
    cr.set_font_size(size);
}

fn draw_tracked_text_right_aligned(
    cr: &cairo::Context,
    text: &str,
    box_x: f64,
    box_width: f64,
    baseline: f64,
    tracking: f64,
) {
    let glyphs: Vec<String> = text
        .chars()
        .map(|character| character.to_string())
        .collect();
    let advances: Vec<f64> = glyphs
        .iter()
        .map(|glyph| {
            cr.text_extents(glyph)
                .map_or(0.0, |extents| extents.x_advance())
        })
        .collect();
    let width = advances.iter().sum::<f64>() + tracking * glyphs.len().saturating_sub(1) as f64;
    let mut x = box_x + box_width - width;
    for (glyph, advance) in glyphs.iter().zip(advances) {
        cr.move_to(x, baseline);
        let _ = cr.show_text(glyph);
        x += advance + tracking;
    }
}

fn set_rgb(cr: &cairo::Context, color: (f64, f64, f64)) {
    cr.set_source_rgb(color.0, color.1, color.2);
}

fn set_rgba(cr: &cairo::Context, color: (f64, f64, f64, f64)) {
    cr.set_source_rgba(color.0, color.1, color.2, color.3);
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
    fn recording_honors_timeless_snapshot_configuration() {
        let mut model = Model::default();
        let mut decoder = decoder_with_idle_snapshot();
        let state = decode_event(
            &mut decoder,
            br#"{"v":1,"type":"event","seq":1,"event":"state.changed","session_id":1,"data":{"state":"recording","stage":null,"session_id":1,"elapsed_ms":1250,"cleanup":true,"show_timer":false}}"#,
        );
        model.apply_event(state);
        assert_eq!(model.state, HudState::Recording);
        assert!(!model.show_timer);
        assert!(model.recording_started.unwrap().elapsed() >= Duration::from_millis(1250));
    }

    #[test]
    fn success_is_exclusive_to_clipboard_output() {
        for (method, expected) in [
            ("clipboard", HudState::Success),
            ("type", HudState::Idle),
            ("paste", HudState::Idle),
        ] {
            let mut model = Model {
                state: HudState::Processing,
                ..Model::default()
            };
            let mut decoder = decoder_with_idle_snapshot();
            let output = format!(
                r#"{{"v":1,"type":"event","seq":1,"event":"output.completed","session_id":1,"data":{{"method":"{method}"}}}}"#
            );
            model.apply_event(decode_event(&mut decoder, output.as_bytes()));
            model.apply_event(decode_event(
                &mut decoder,
                br#"{"v":1,"type":"event","seq":2,"event":"state.changed","session_id":1,"data":{"state":"idle","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true,"show_timer":true}}"#,
            ));
            assert_eq!(
                model.state,
                if method == "clipboard" {
                    HudState::Processing
                } else {
                    HudState::Idle
                },
                "intermediate output method {method}"
            );
            model.apply_event(decode_event(
                &mut decoder,
                br#"{"v":1,"type":"event","seq":3,"event":"session.completed","session_id":1,"data":{"ok":true,"phase":"post_stt","reason":null,"stt_attempted":true,"latency_ms":10}}"#,
            ));
            assert_eq!(model.state, expected, "output method {method}");
        }
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
    fn native_success_uses_no_speech_generic_clipboard_and_fallback_labels() {
        for (generation, message) in [
            (1, "No speech detected"),
            (2, "delivery completed"),
            (3, "delivery completed"),
            (4, "transcript copied to clipboard"),
            (5, "typing failed; transcript copied to clipboard"),
        ] {
            let mut model = Model::default();
            model.apply_native_terminal(&session::Snapshot {
                state: session::State::Success,
                generation,
                message: Some(message.to_owned()),
                ..session::Snapshot::default()
            });
            assert_eq!(model.state, HudState::Success);
            assert_eq!(model.success_message, message);
            assert!(model.error.is_empty());
        }
    }

    #[test]
    fn native_generation_resets_success_label_to_legacy_fallback() {
        let mut model = Model::default();
        model.apply_native_terminal(&session::Snapshot {
            state: session::State::Success,
            generation: 1,
            message: Some("delivery completed".to_owned()),
            ..session::Snapshot::default()
        });
        model.apply_native_terminal(&session::Snapshot {
            state: session::State::Starting,
            generation: 2,
            ..session::Snapshot::default()
        });
        assert_eq!(model.success_message, "Copied to clipboard");
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
