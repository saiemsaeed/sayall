use crate::{autostart, global_shortcut, worker};
use gtk::prelude::*;
use gtk::{Application, ApplicationWindow, Box as GtkBox, Button, CheckButton, Label, Orientation};
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
        .default_width(460)
        .default_height(220)
        .build();
    let column = GtkBox::new(Orientation::Vertical, 12);
    column.set_margin_top(20);
    column.set_margin_bottom(20);
    column.set_margin_start(20);
    column.set_margin_end(20);
    let heading = Label::new(Some("SayAll Linux host"));
    heading.set_xalign(0.0);
    let status = Label::new(None);
    status.set_xalign(0.0);
    status.set_wrap(true);
    let shortcut = Label::new(Some(shortcut_status.message()));
    shortcut.set_xalign(0.0);
    shortcut.set_wrap(true);
    let init = Button::with_label("Initialize configuration");
    let enable_shortcut = Button::with_label("Enable/configure global shortcut");
    let reload = Button::with_label("Reload Configuration");
    let login = CheckButton::with_label("Start SayAll at login");
    column.append(&heading);
    column.append(&status);
    column.append(&shortcut);
    column.append(&enable_shortcut);
    column.append(&init);
    column.append(&reload);
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
    let refresh = {
        let status = status.clone();
        let init = init.clone();
        let login = login.clone();
        let changing = changing.clone();
        move || {
            let (tx, rx) = mpsc::channel();
            std::thread::spawn(move || {
                let config = config_operation("--config-validate");
                let autostart = autostart::state();
                let _ = tx.send((config, autostart));
            });
            let status = status.clone();
            let init = init.clone();
            let login = login.clone();
            let changing = changing.clone();
            gtk::glib::timeout_add_local(Duration::from_millis(20), move || {
                let Ok((result, autostart_state)) = rx.try_recv() else {
                    return gtk::glib::ControlFlow::Continue;
                };
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
