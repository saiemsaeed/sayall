use serde::Deserialize;
use std::env;
use std::fs::File;
use std::io::{Read, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const OMARCHY_COLORS_MAX: u64 = 64 * 1024;
const HYPRLAND_REPLY_MAX: u64 = 4096;

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "kebab-case")]
pub enum Theme {
    #[default]
    Omarchy,
    Catppuccin,
    Gruvbox,
    Nord,
    TokyoNight,
    RosePine,
    Kanagawa,
    Everforest,
    Ethereal,
    Ristretto,
    MatteBlack,
    Dark,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum Shape {
    #[default]
    Rounded,
    Soft,
    Square,
}

#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub shell: (f64, f64, f64, f64),
    pub border: (f64, f64, f64, f64),
    pub text: (f64, f64, f64, f64),
    pub wave: (f64, f64, f64),
    pub dot: (f64, f64, f64),
    pub processing: (f64, f64, f64),
    pub success: (f64, f64, f64),
    pub error: (f64, f64, f64),
}

#[derive(Clone, Copy, Debug)]
pub struct Appearance {
    pub palette: Palette,
    pub shape: Shape,
    omarchy_radius: Option<f64>,
}

impl Default for Appearance {
    fn default() -> Self {
        Self::resolve(Theme::default(), Shape::default())
    }
}

impl Appearance {
    pub fn resolve(theme: Theme, shape: Shape) -> Self {
        let palette = match theme {
            Theme::Omarchy => omarchy_palette().unwrap_or(DARK),
            Theme::Catppuccin => {
                palette(0x1e1e2e, 0xcdd6f4, 0x89b4fa, 0xf38ba8, 0xa6e3a1, 0x94e2d5)
            }
            Theme::Gruvbox => palette(0x282828, 0xd4be98, 0x7daea3, 0xea6962, 0xa9b665, 0x89b482),
            Theme::Nord => palette(0x2e3440, 0xd8dee9, 0x81a1c1, 0xbf616a, 0xa3be8c, 0x88c0d0),
            Theme::TokyoNight => {
                palette(0x1a1b26, 0xa9b1d6, 0x7aa2f7, 0xf7768e, 0x9ece6a, 0x449dab)
            }
            Theme::RosePine => palette(0xfaf4ed, 0x575279, 0x56949f, 0xb4637a, 0x286983, 0xd7827e),
            Theme::Kanagawa => palette(0x1f1f28, 0xdcd7ba, 0xdcd7ba, 0xc34043, 0x76946a, 0x6a9589),
            Theme::Everforest => {
                palette(0x2d353b, 0xd3c6aa, 0x7fbbb3, 0xe67e80, 0xa7c080, 0x83c092)
            }
            Theme::Ethereal => palette(0x060b1e, 0xffcead, 0x7d82d9, 0xed5b5a, 0x92a593, 0xa3bfd1),
            Theme::Ristretto => palette(0x2c2525, 0xe6d9db, 0xf38d70, 0xfd6883, 0xadda78, 0x85dacc),
            Theme::MatteBlack => {
                palette(0x121212, 0xbebebe, 0xe68e0d, 0xd35f5f, 0xffc107, 0xbebebe)
            }
            Theme::Dark => DARK,
        };
        let omarchy_radius =
            (theme == Theme::Omarchy).then(|| hyprland_rounding().unwrap_or(HUD_ROUNDED_RADIUS));
        Self {
            palette,
            shape,
            omarchy_radius,
        }
    }

    pub fn shell_radius(self, height: f64) -> f64 {
        if let Some(radius) = self.omarchy_radius {
            return radius.min(height / 2.0);
        }
        match self.shape {
            Shape::Rounded => height / 2.0,
            Shape::Soft => 10.0,
            Shape::Square => 0.0,
        }
    }

    pub fn element_radius(self, width: f64) -> f64 {
        width / 2.0
    }

    pub fn settings_css(self) -> String {
        let p = self.palette;
        let outer_radius = match self.omarchy_radius {
            Some(value) => value.round() as u32,
            None => match self.shape {
                Shape::Rounded => 18,
                Shape::Soft => 10,
                Shape::Square => 0,
            },
        };
        format!(
            ".sayall-settings {{ background-color: {}; color: {}; }}
             .settings-content {{ background-color: {}; border: 1px solid {}; border-radius: {}px; padding: 24px; }}
             .settings-title, .settings-section-title {{ color: {}; font-weight: 700; }}
             .settings-title {{ font-size: 24px; }}
             .settings-section-title {{ font-size: 15px; }}
             .settings-subtitle, .settings-secondary {{ color: {}; }}
             .settings-status {{ color: {}; font-weight: 600; }}
             .settings-card {{ background-color: {}; border: 1px solid {}; border-radius: {}px; padding: 16px; }}
             .settings-option {{ padding: 6px 2px; }}
             .settings-actions button {{ border-radius: {}px; padding: 10px 14px; }}
             .settings-primary {{ background-color: {}; color: {}; font-weight: 700; }}",
            css_rgb(p.shell),
            css_rgba(p.text),
            css_rgb(p.shell),
            css_rgba(p.border),
            outer_radius,
            css_rgba(p.text),
            css_rgba((p.text.0, p.text.1, p.text.2, 0.66)),
            css_rgb3(p.success),
            css_rgba((p.text.0, p.text.1, p.text.2, 0.06)),
            css_rgba(p.border),
            12,
            10,
            css_rgb3(p.wave),
            css_rgb(p.shell),
        )
    }
}

const HUD_ROUNDED_RADIUS: f64 = 24.0;

const DARK: Palette = Palette {
    shell: (14.0 / 255.0, 15.0 / 255.0, 19.0 / 255.0, 0.94),
    border: (1.0, 1.0, 1.0, 0.10),
    text: (1.0, 1.0, 1.0, 0.82),
    wave: (250.0 / 255.0, 87.0 / 255.0, 122.0 / 255.0),
    dot: (1.0, 64.0 / 255.0, 82.0 / 255.0),
    processing: (76.0 / 255.0, 214.0 / 255.0, 209.0 / 255.0),
    success: (107.0 / 255.0, 235.0 / 255.0, 158.0 / 255.0),
    error: (1.0, 115.0 / 255.0, 115.0 / 255.0),
};

fn palette(
    background: u32,
    foreground: u32,
    accent: u32,
    red: u32,
    green: u32,
    cyan: u32,
) -> Palette {
    let background = rgb(background);
    let foreground = rgb(foreground);
    Palette {
        shell: (background.0, background.1, background.2, 0.96),
        border: (foreground.0, foreground.1, foreground.2, 0.18),
        text: (foreground.0, foreground.1, foreground.2, 0.90),
        wave: rgb(accent),
        dot: rgb(red),
        processing: rgb(cyan),
        success: rgb(green),
        error: rgb(red),
    }
}

fn rgb(value: u32) -> (f64, f64, f64) {
    (
        f64::from((value >> 16) & 0xff) / 255.0,
        f64::from((value >> 8) & 0xff) / 255.0,
        f64::from(value & 0xff) / 255.0,
    )
}

fn omarchy_palette() -> Option<Palette> {
    let home = env::var_os("HOME")?;
    let path = PathBuf::from(home).join(".local/state/omarchy/current/theme/colors.toml");
    let mut file = File::open(path).ok()?;
    let mut contents = String::new();
    Read::by_ref(&mut file)
        .take(OMARCHY_COLORS_MAX + 1)
        .read_to_string(&mut contents)
        .ok()?;
    if contents.len() as u64 > OMARCHY_COLORS_MAX {
        return None;
    }
    parse_omarchy_colors(&contents)
}

#[derive(Deserialize)]
struct HyprlandOption {
    int: i32,
}

fn hyprland_rounding() -> Option<f64> {
    let runtime = PathBuf::from(env::var_os("XDG_RUNTIME_DIR")?);
    if !runtime.is_absolute() {
        return None;
    }
    let signature = env::var_os("HYPRLAND_INSTANCE_SIGNATURE")?;
    let signature = signature.to_str()?;
    if signature.is_empty()
        || signature.len() > 255
        || signature.contains('/')
        || signature.chars().any(char::is_control)
    {
        return None;
    }
    let socket = runtime.join("hypr").join(signature).join(".socket.sock");
    let mut stream = UnixStream::connect(socket).ok()?;
    let timeout = Some(Duration::from_millis(100));
    stream.set_read_timeout(timeout).ok()?;
    stream.set_write_timeout(timeout).ok()?;
    stream.write_all(b"j/getoption decoration:rounding").ok()?;
    stream.shutdown(Shutdown::Write).ok()?;
    let mut reply = String::new();
    stream
        .take(HYPRLAND_REPLY_MAX + 1)
        .read_to_string(&mut reply)
        .ok()?;
    if reply.len() as u64 > HYPRLAND_REPLY_MAX {
        return None;
    }
    parse_hyprland_rounding(&reply)
}

fn parse_hyprland_rounding(reply: &str) -> Option<f64> {
    let option: HyprlandOption = serde_json::from_str(reply).ok()?;
    (option.int >= 0).then_some(f64::from(option.int))
}

fn parse_omarchy_colors(contents: &str) -> Option<Palette> {
    let mut background = None;
    let mut foreground = None;
    let mut accent = None;
    let mut red = None;
    let mut green = None;
    let mut cyan = None;
    for line in contents.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let value = value.trim().trim_matches('"');
        let parsed = parse_hex(value);
        match key.trim() {
            "background" => background = parsed,
            "foreground" => foreground = parsed,
            "accent" => accent = parsed,
            "red" => red = parsed,
            "green" => green = parsed,
            "cyan" => cyan = parsed,
            _ => {}
        }
    }
    let accent = accent?;
    Some(palette(
        background?,
        foreground?,
        accent,
        red?,
        green?,
        cyan.unwrap_or(accent),
    ))
}

fn parse_hex(value: &str) -> Option<u32> {
    let value = value.strip_prefix('#')?;
    (value.len() == 6)
        .then(|| u32::from_str_radix(value, 16).ok())
        .flatten()
}

fn css_rgb(color: (f64, f64, f64, f64)) -> String {
    css_rgb3((color.0, color.1, color.2))
}

fn css_rgb3(color: (f64, f64, f64)) -> String {
    format!(
        "rgb({}, {}, {})",
        (color.0 * 255.0).round(),
        (color.1 * 255.0).round(),
        (color.2 * 255.0).round()
    )
}

fn css_rgba(color: (f64, f64, f64, f64)) -> String {
    format!(
        "rgba({}, {}, {}, {:.2})",
        (color.0 * 255.0).round(),
        (color.1 * 255.0).round(),
        (color.2 * 255.0).round(),
        color.3
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_preconfigured_theme_name_deserializes() {
        for name in [
            "omarchy",
            "catppuccin",
            "gruvbox",
            "nord",
            "tokyo-night",
            "rose-pine",
            "kanagawa",
            "everforest",
            "ethereal",
            "ristretto",
            "matte-black",
            "dark",
        ] {
            serde_json::from_str::<Theme>(&format!("\"{name}\"")).unwrap();
        }
    }

    #[test]
    fn omarchy_colors_map_to_hud_roles() {
        let parsed = parse_omarchy_colors(
            r##"mode = "dark"
background = "#282828"
foreground = "#d4be98"
accent = "#7daea3"
red = "#ea6962"
green = "#a9b665"
cyan = "#89b482""##,
        )
        .unwrap();
        assert_eq!(parsed.wave, rgb(0x7daea3));
        assert_eq!(parsed.error, rgb(0xea6962));
        assert_eq!(parsed.success, rgb(0xa9b665));
    }

    #[test]
    fn shape_controls_shell_and_element_corners() {
        let rounded = Appearance::resolve(Theme::Dark, Shape::Rounded);
        let soft = Appearance::resolve(Theme::Dark, Shape::Soft);
        let square = Appearance::resolve(Theme::Dark, Shape::Square);
        assert_eq!(rounded.shell_radius(48.0), 24.0);
        assert_eq!(soft.shell_radius(48.0), 10.0);
        assert_eq!(square.shell_radius(48.0), 0.0);
        assert_eq!(square.element_radius(4.5), 2.25);
    }

    #[test]
    fn omarchy_uses_live_rounding_instead_of_explicit_shape() {
        let appearance = Appearance {
            palette: DARK,
            shape: Shape::Square,
            omarchy_radius: Some(8.0),
        };
        assert_eq!(appearance.shell_radius(48.0), 8.0);
        assert_eq!(appearance.element_radius(4.5), 2.25);
        assert_eq!(parse_hyprland_rounding(r#"{"int":0}"#), Some(0.0));
        assert_eq!(parse_hyprland_rounding(r#"{"int":6}"#), Some(6.0));
    }
}
