use crate::worker;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::Path;
use std::time::Duration;

const UNIT: &str = "sayall-hud.service";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Disabled,
    Enabled,
    Unavailable,
}

fn environment() -> Vec<(&'static str, OsString)> {
    ["HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"]
        .into_iter()
        .filter_map(|key| std::env::var_os(key).map(|value| (key, value)))
        .collect()
}

fn parse_enabled(success: bool, output: &str) -> State {
    if success
        || matches!(
            output.trim(),
            "enabled" | "enabled-runtime" | "linked" | "linked-runtime" | "alias"
        )
    {
        State::Enabled
    } else if matches!(
        output.trim(),
        "disabled"
            | "masked"
            | "masked-runtime"
            | "static"
            | "indirect"
            | "generated"
            | "transient"
            | "not-found"
    ) {
        State::Disabled
    } else {
        State::Unavailable
    }
}

pub fn state() -> io::Result<State> {
    let env = environment();
    let refs: Vec<(&str, &OsStr)> = env.iter().map(|(k, v)| (*k, v.as_os_str())).collect();
    let output = worker::supervised(
        Path::new("/usr/bin/systemctl"),
        &["--user", "is-enabled", UNIT],
        &refs,
        Duration::from_secs(2),
    )
    .map_err(io::Error::other)?;
    Ok(parse_enabled(
        output.status.success(),
        &String::from_utf8_lossy(&output.stdout),
    ))
}

fn set(verb: &str) -> io::Result<()> {
    let env = environment();
    let refs: Vec<(&str, &OsStr)> = env.iter().map(|(k, v)| (*k, v.as_os_str())).collect();
    let output = worker::supervised(
        Path::new("/usr/bin/systemctl"),
        &["--user", verb, UNIT],
        &refs,
        Duration::from_secs(5),
    )
    .map_err(io::Error::other)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(format!("could not {verb} {UNIT}")))
    }
}

pub fn enable() -> io::Result<()> {
    set("enable")
}
pub fn disable() -> io::Result<()> {
    set("disable")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn parses_unit_states() {
        assert_eq!(parse_enabled(true, ""), State::Enabled);
        assert_eq!(parse_enabled(false, "enabled-runtime\n"), State::Enabled);
        assert_eq!(parse_enabled(false, "disabled\n"), State::Disabled);
        assert_eq!(parse_enabled(false, "not-found\n"), State::Disabled);
        assert_eq!(parse_enabled(false, "garbage\n"), State::Unavailable);
    }
}
