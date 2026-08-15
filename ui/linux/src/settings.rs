use crate::{autostart, config, global_shortcut, worker};
use gtk::prelude::*;
use gtk::{
    Align, Application, ApplicationWindow, Box as GtkBox, Button, CheckButton, Label, Orientation,
};
use serde::Deserialize;
use std::cell::Cell;
use std::ffi::OsStr;
use std::sync::mpsc;
use std::time::Duration;

#[derive(Deserialize)]
struct Reply {
    version: u32,
    status: String,
}

#[derive(Debug, Eq, PartialEq)]
enum ConfigResult {
    Missing,
    Valid,
    Created,
    Exists,
    Invalid,
}

fn config_operation(flag: &str) -> Result<ConfigResult, String> {
    let path = worker::resolve()
        .map_err(|_| "private configuration worker is not installed".to_owned())?;
    let mut environment = Vec::new();
    if let Some(value) = std::env::var_os("HOME") {
        environment.push(("HOME", value));
    }
    if let Some(value) = std::env::var_os("XDG_CONFIG_HOME") {
        environment.push(("XDG_CONFIG_HOME", value));
    }
    let refs: Vec<(&str, &OsStr)> = environment
        .iter()
        .map(|(k, v)| (*k, v.as_os_str()))
        .collect();
    let output = worker::supervised(&path, &[flag], &refs, Duration::from_secs(3))?;
    let reply: Reply = serde_json::from_slice(&output.stdout)
        .map_err(|_| "configuration worker response was invalid".to_owned())?;
    if reply.version != 1 || !output.status.success() {
        return Err("configuration worker is incompatible".into());
    }
    match reply.status.as_str() {
        "missing" => Ok(ConfigResult::Missing),
        "created" => Ok(ConfigResult::Created),
        "exists" => Ok(ConfigResult::Exists),
        "invalid" | "error" => Ok(ConfigResult::Invalid),
        "valid" => Ok(ConfigResult::Valid),
        _ => Err("configuration worker response was invalid".into()),
    }
}

pub fn show(app: &Application, shortcut_status: global_shortcut::Status) {
    if let Some(window) = app
        .windows()
        .into_iter()
        .find(|w| w.title().as_deref() == Some("SayAll Settings"))
    {
        window.present();
        return;
    }
    let window = ApplicationWindow::builder()
        .application(app)
        .title("SayAll Settings")
        .default_width(560)
        .default_height(520)
        .build();
    window.add_css_class("sayall-settings");
    let css = gtk::CssProvider::new();
    css.load_from_data(
        ".sayall-settings {
            background-color: #101116;
            color: #f7f7fa;
        }
        .settings-content {
            background-color: #17191f;
            border: 1px solid rgba(255, 255, 255, 0.10);
            border-radius: 18px;
            padding: 24px;
        }
        .settings-title {
            color: #ffffff;
            font-size: 24px;
            font-weight: 700;
        }
        .settings-subtitle, .settings-secondary {
            color: rgba(255, 255, 255, 0.66);
        }
        .settings-status {
            color: #6beba0;
            font-weight: 600;
        }
        .settings-card {
            background-color: #20232b;
            border: 1px solid rgba(255, 255, 255, 0.08);
            border-radius: 12px;
            padding: 16px;
        }
        .settings-section-title {
            color: #ffffff;
            font-size: 15px;
            font-weight: 700;
        }
        .settings-option {
            padding: 6px 2px;
        }
        .settings-actions button {
            border-radius: 10px;
            padding: 10px 14px;
        }
        .settings-primary {
            background-color: #fa577a;
            color: #ffffff;
            font-weight: 700;
        }",
    );
    gtk::style_context_add_provider_for_display(
        &gtk::gdk::Display::default().expect("a graphical display"),
        &css,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    let column = GtkBox::new(Orientation::Vertical, 16);
    column.add_css_class("settings-content");
    column.set_width_request(480);
    column.set_halign(Align::Center);
    column.set_valign(Align::Center);
    let heading = Label::new(Some("SayAll"));
    heading.set_xalign(0.0);
    heading.add_css_class("settings-title");
    let subtitle = Label::new(Some("Voice dictation settings"));
    subtitle.set_xalign(0.0);
    subtitle.add_css_class("settings-subtitle");
    let overview = GtkBox::new(Orientation::Vertical, 8);
    overview.add_css_class("settings-card");
    let status = Label::new(None);
    status.set_xalign(0.0);
    status.set_wrap(true);
    status.add_css_class("settings-status");
    let shortcut = Label::new(Some(shortcut_status.message()));
    shortcut.set_xalign(0.0);
    shortcut.set_wrap(true);
    shortcut.add_css_class("settings-secondary");
    let init = Button::with_label("Initialize configuration");
    let enable_shortcut = Button::with_label("Configure Shortcut");
    let reload = Button::with_label("Reload Configuration");
    reload.add_css_class("settings-primary");
    let login = CheckButton::with_label("Start SayAll at login");
    login.add_css_class("settings-option");
    let actions = GtkBox::new(Orientation::Horizontal, 8);
    actions.add_css_class("settings-actions");
    actions.append(&enable_shortcut);
    actions.append(&reload);
    actions.append(&init);
    let processing = GtkBox::new(Orientation::Vertical, 6);
    processing.add_css_class("settings-card");
    let processing_heading = Label::new(Some("Processing mode"));
    processing_heading.set_xalign(0.0);
    processing_heading.add_css_class("settings-section-title");
    let verbatim = CheckButton::with_label("Verbatim — preserve finalized transcription");
    let clean = CheckButton::with_label("Clean — apply deterministic cleanup");
    let polished = CheckButton::with_label("Polished — refine wording and structure");
    clean.set_group(Some(&verbatim));
    polished.set_group(Some(&verbatim));
    for button in [&verbatim, &clean, &polished] {
        button.set_sensitive(false);
        button.add_css_class("settings-option");
    }
    column.append(&heading);
    column.append(&subtitle);
    overview.append(&status);
    overview.append(&shortcut);
    column.append(&overview);
    column.append(&actions);
    processing.append(&processing_heading);
    processing.append(&verbatim);
    processing.append(&clean);
    processing.append(&polished);
    column.append(&processing);
    column.append(&login);
    window.set_child(Some(&column));
    let enable_for_click = enable_shortcut.clone();
    enable_shortcut.connect_clicked(move |_| {
        enable_for_click.set_sensitive(false);
        crate::enable_portal_shortcut();
    });
    let shortcut_poll = shortcut.downgrade();
    let enable_poll = enable_shortcut.downgrade();
    gtk::glib::timeout_add_local(Duration::from_millis(250), move || {
        let (Some(shortcut), Some(enable)) = (shortcut_poll.upgrade(), enable_poll.upgrade())
        else {
            return gtk::glib::ControlFlow::Break;
        };
        let current = crate::portal_status();
        shortcut.set_text(current.message());
        enable.set_sensitive(!matches!(
            current,
            global_shortcut::Status::Initializing | global_shortcut::Status::Active
        ));
        gtk::glib::ControlFlow::Continue
    });
    let changing = std::rc::Rc::new(Cell::new(false));
    let confirmed_mode = std::rc::Rc::new(Cell::new(config::ProcessingMode::Verbatim));
    let refresh = {
        let status = status.clone();
        let init = init.clone();
        let login = login.clone();
        let verbatim = verbatim.clone();
        let clean = clean.clone();
        let polished = polished.clone();
        let changing = changing.clone();
        let confirmed_mode = confirmed_mode.clone();
        move || {
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let config = config_operation("--config-validate");
                let mode = config::selected_processing_mode();
                let autostart = autostart::state();
                let _ = tx.send((config, mode, autostart));
            });
            let status = status.clone();
            let init = init.clone();
            let login = login.clone();
            let verbatim = verbatim.clone();
            let clean = clean.clone();
            let polished = polished.clone();
            let changing = changing.clone();
            let confirmed_mode = confirmed_mode.clone();
            gtk::glib::timeout_add_local(Duration::from_millis(20), move || {
                let Ok((result, mode, autostart_state)) = rx.try_recv() else {
                    return gtk::glib::ControlFlow::Continue;
                };
                let config_valid = matches!(&result, Ok(ConfigResult::Valid));
                match result {
                    Ok(ConfigResult::Valid) => {
                        status.set_text("Configuration is valid.");
                        init.set_sensitive(false)
                    }
                    Ok(ConfigResult::Missing | ConfigResult::Invalid) => {
                        status.set_text("Configuration is missing or invalid. Credential values are never displayed.");
                        init.set_sensitive(true)
                    }
                    Ok(_) => {
                        status.set_text("Configuration status changed; revalidate to continue.");
                        init.set_sensitive(false)
                    }
                    Err(e) => {
                        status.set_text(&e);
                        init.set_sensitive(false)
                    }
                }
                for button in [&verbatim, &clean, &polished] {
                    button.set_sensitive(config_valid);
                }
                if let Ok(mode) = mode {
                    confirmed_mode.set(mode);
                    changing.set(true);
                    match mode {
                        config::ProcessingMode::Verbatim => verbatim.set_active(true),
                        config::ProcessingMode::Clean => clean.set_active(true),
                        config::ProcessingMode::Polished => polished.set_active(true),
                    }
                    changing.set(false);
                }
                if let Ok(autostart_state) = autostart_state {
                    changing.set(true);
                    match autostart_state {
                        autostart::State::Enabled => login.set_active(true),
                        autostart::State::Disabled => login.set_active(false),
                        autostart::State::Unavailable => login.set_sensitive(false),
                    }
                    changing.set(false);
                }
                gtk::glib::ControlFlow::Break
            });
        }
    };
    refresh();
    let status2 = status.clone();
    init.connect_clicked(move |_| {
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(config_operation("--config-init"));
        });
        let status2 = status2.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(20), move || {
            let Ok(result) = rx.try_recv() else {
                return gtk::glib::ControlFlow::Continue;
            };
            match result {
        Ok(ConfigResult::Created) => status2.set_text("Configuration initialized securely. Revalidate to load it."),
        Ok(ConfigResult::Exists) => status2.set_text(
            "Configuration already exists or could not be initialized; nothing was overwritten.",
        ),
        Ok(_) => status2.set_text("Configuration could not be initialized; nothing was overwritten."),
        Err(e) => status2.set_text(&e),
      };
            gtk::glib::ControlFlow::Break
        });
    });
    let reload_status = status.clone();
    reload.connect_clicked(move |_| match crate::reload_configuration() {
        Ok(()) => {
            reload_status.set_text("Configuration reloaded. Changes apply to the next dictation.")
        }
        Err(e) => reload_status.set_text(&format!("Could not reload configuration: {e}")),
    });
    for (button, mode) in [
        (verbatim.clone(), config::ProcessingMode::Verbatim),
        (clean.clone(), config::ProcessingMode::Clean),
        (polished.clone(), config::ProcessingMode::Polished),
    ] {
        let changing = changing.clone();
        let confirmed_mode = confirmed_mode.clone();
        let mode_status = status.clone();
        let verbatim = verbatim.clone();
        let clean = clean.clone();
        let polished = polished.clone();
        button.connect_toggled(move |button| {
            if changing.get() || !button.is_active() {
                return;
            }
            match crate::set_processing_mode(mode) {
                Ok(()) => {
                    confirmed_mode.set(mode);
                    mode_status.set_text("Processing mode saved. It applies to the next dictation.")
                }
                Err(error) => {
                    changing.set(true);
                    match confirmed_mode.get() {
                        config::ProcessingMode::Verbatim => verbatim.set_active(true),
                        config::ProcessingMode::Clean => clean.set_active(true),
                        config::ProcessingMode::Polished => polished.set_active(true),
                    }
                    changing.set(false);
                    mode_status.set_text(&format!("Could not change mode: {error}"));
                }
            }
        });
    }
    let status3 = status.clone();
    let changing2 = changing.clone();
    login.connect_toggled(move |toggle| {
        if changing2.get() {
            return;
        }
        let requested = toggle.is_active();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let result = if requested {
                autostart::enable()
            } else {
                autostart::disable()
            };
            let state = autostart::state();
            let _ = tx.send((result, state));
        });
        let toggle = toggle.clone();
        let status3 = status3.clone();
        let changing2 = changing2.clone();
        gtk::glib::timeout_add_local(Duration::from_millis(20), move || {
            let Ok((result, state)) = rx.try_recv() else {
                return gtk::glib::ControlFlow::Continue;
            };
            if let Err(e) = result {
                status3.set_text(&e.to_string());
            }
            if let Ok(state) = state {
                changing2.set(true);
                toggle.set_active(state == autostart::State::Enabled);
                changing2.set(false);
            }
            gtk::glib::ControlFlow::Break
        });
    });
    window.present();
}
