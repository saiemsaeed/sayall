# Changelog

All notable user-visible changes to SayAll are documented in this file. SayAll
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.2] - 2026-07-22

### Added

- `sayall setup` enables and starts or restarts the daemon and HUD systemd user
  services without requiring users to remember the underlying `systemctl`
  commands.
- `sayall update` upgrades the currently installed AUR package with `yay`, then
  reloads, enables, and restarts both user services after a successful update.

## [0.1.1] - 2026-07-22

### Added

- `sayall doctor` installation and runtime diagnostics for Wayland, API
  credentials, required commands, systemd service state, and daemon health.

### Changed

- AUR installation is now the recommended setup for supported Arch Linux and
  Omarchy users; source builds are documented as a contributor workflow.

## [0.1.0] - 2026-07-21

Initial release, tested and supported on x86-64 Arch Linux with Omarchy.

### Added

- Zig voice-dictation daemon and command-line client.
- PipeWire recording with Deepgram Nova-3 streaming transcription and REST
  fallback.
- Optional Groq cleanup of filler words, false starts, grammar, and
  punctuation.
- Direct Wayland typing with clipboard fallback.
- Rust/GTK4 layer-shell recording HUD.
- Versioned control protocol v1 over a private Unix socket.
- Persistent privacy-safe transcription metrics and microphone diagnostics.
- systemd user services and Hyprland hotkey integration.

[Unreleased]: https://github.com/saiemsaeed/sayall/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/saiemsaeed/sayall/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/saiemsaeed/sayall/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/saiemsaeed/sayall/releases/tag/v0.1.0
