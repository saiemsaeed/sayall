# Changelog

All notable user-visible changes to SayAll are documented in this file. SayAll
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-08-02

### Added

- Added one cross-platform Zig CLI with consistent `version`, `status`,
  `toggle`, file transcription, configuration initialization and validation,
  diagnostics, and native package update operations. The public interface has
  no start, stop, or legacy-daemon commands.
- Added versioned, bounded private protocols for native-host control and Zig
  processing, with same-user endpoint protection, worker compatibility checks,
  supervised streaming, and exactly one REST fallback.
- Added native Linux settings, autostart and shortcut controls, desktop error
  notifications, X11 and Wayland delivery, and opt-in desktop-portal shortcuts.
- Added a complete signed macOS product containing the native app, shared CLI,
  and private worker, with DMG, menu CLI installation, and Homebrew Cask
  delivery paths.

### Changed

- Moved platform-neutral provider configuration, audio validation, Deepgram
  streaming and REST transcription, and optional Groq cleanup into one Zig
  processing core used by both native applications.
- Replaced the split Linux Zig daemon and Rust HUD runtime with one native Rust
  session host controlled by the shared Zig CLI and backed by the private Zig
  processing worker. Linux now installs one package-managed user service, with
  no experimental mode or public legacy daemon commands.
- Added native X11 typing, paste, and clipboard delivery alongside the existing
  Wayland path, with runtime session selection and matching diagnostics.
- Linux release archives and all AUR variants now install one complete product:
  the public CLI and application, private processing worker, native-host service,
  desktop launcher, and application icon. The CLI, host, and worker versions are
  validated together, including dynamically versioned `sayall-git` builds.
- Release publication now binds protected macOS and Linux approvals to exact
  signed/notarized DMG and Linux manifest digests after physical qualification.

### Fixed

- Hardened Linux migration ordering, stale endpoint ownership, worker failure
  recovery, and fail-closed retirement of the old daemon service.
- Accepted Arch's trusted root-owned `/usr/bin/pw-record` symlink while still
  rejecting writable or escaping capture executables.
- Made private-worker permission tests portable across physical Arch kernels
  and filesystems.

## [0.1.8] - 2026-08-01

### Added

- Bundled a signed native macOS `sayall` terminal helper with `version`,
  `status`, `toggle`, and one-time private `config init`, plus an explicit menu
  action that safely guides installation at `/usr/local/bin/sayall`.
- Added a bounded same-UID private Unix control socket for macOS status and
  toggle requests, including exact-containing-app background launch.

### Changed

- macOS reports terminal dictation and configuration errors through native
  notifications instead of the HUD when notification permission is available.

## [0.1.7] - 2026-08-01

### Added

- Prepared direct Apple Silicon distribution as a Developer ID-signed,
  notarized, and stapled `sayall-0.1.7-macos-arm64.zip` for macOS 15.0 or later.
- Added credential-isolated release promotion: CI builds and verifies the
  unsigned candidate before a protected signing job imports credentials, and a
  separate credential-free protected publication environment accepts only the
  physically qualified ZIP's exact SHA-256.

### Fixed

- Bound automatic macOS paste delivery to the original editable,
  non-secure Accessibility element; focus changes and uncertain or secure
  targets now fall back to clipboard-only delivery.

### Development target

- Apple Silicon macOS publication and support remain conditional on successful
  Developer ID signing, notarization, Gatekeeper verification, and the complete
  physical Apple Silicon qualification matrix. If any gate is incomplete,
  macOS remains a development preview and no macOS artifact is published.

## [0.1.6] - 2026-07-24

### Added

- Linux `paste` output mode, which copies the completed transcript and sends a
  single `Ctrl+V` shortcut to insert it in the focused application.
- Optional Linux HUD recording timer controlled by `hud.show_timer`; it remains
  enabled by default for backward compatibility.

### Changed

- Redesigned the Linux HUD as a compact 244 × 48 fully rounded pill with live
  recording amplitude, a centered timeless layout, waveform-only processing,
  semantic clipping feedback, and the exact `Copied to clipboard` success state.
- Copy output is the only mode that shows success; Type and Paste now dismiss
  the HUD silently after delivery.
- Deepgram streaming and REST transcription now enable Smart Format,
  punctuation, spoken dictation commands, numerals, and measurements, and
  preserve dictated newlines between finalized streaming segments.
- `output.trailing_space` now defaults to `true`.
- The Linux HUD protocol client now validates required protocol-v1 fields and
  duplicate JSON keys without retaining unused wire fields, while preserving
  additive unknown-field and unknown-event compatibility.

### Fixed

- Terminal state and completion events are published atomically so a delayed
  completion from one session cannot dismiss a newly started recording.
- Immutable AUR release recipes are verified against the requested tag before
  publication.

### Development preview

- Built a native Apple Silicon menu-bar app for macOS 15.0 or later, with native
  microphone capture and permissions, a global `Control+/` shortcut with menu
  fallback, Accessibility-authorized paste with clipboard fallback, and an
  isolated per-recording Zig transcription helper.
- Added ad-hoc CI assembly plus the Developer ID signing, Hardened Runtime,
  notarization, stapling, checksum, and physical-device qualification plan.
  Distribution is parked for 0.1.7: 0.1.6 does not publish a macOS artifact or
  claim macOS support, and 0.1.7 may do so only after every publication gate
  passes.

### Known limitations

- Release support remains limited to x86-64 Arch Linux with Omarchy. The
  macOS preview awaits Developer ID signing, notarization, and physical Apple
  Silicon qualification before its targeted 0.1.7 supported release.
- The Linux HUD currently uses the Dark palette. Light palette tokens are
  implemented, but user-facing theme selection is not yet exposed.

## [0.1.5] - 2026-07-23

### Changed

- Restored conventional AUR package names: `sayall` builds the stable release
  from source, `sayall-bin` installs official prebuilt release artifacts, and
  `sayall-git` continues to build the latest development revision.
- `sayall update` now updates `sayall-bin` in place and migrates the retired
  `sayall-src` package name to `sayall`.

## [0.1.4] - 2026-07-22

### Added

- Compile-only core readiness checks for `aarch64-macos` and `x86_64-windows`
  exercise portable orchestration and contracts against explicit unsupported
  runtime/product boundaries. They do not provide a macOS or Windows app,
  runtime, package, or installable output.

### Changed

- Platform-independent orchestration and contracts are separated from the
  Linux-owned runtime and product integrations, following the accepted
  [platform ownership and support ADR](docs/adr-platform-ownership-and-support.md).
- [Control protocol v1](docs/protocol-v1.md) now has explicit compatibility
  fixtures, bounded framing, coherent subscription snapshots and sequencing,
  event-gap recovery, and safer stale-socket replacement. The Linux HUD client
  validates the same contract and resynchronizes after connection loss.

## [0.1.3] - 2026-07-22

### Added

- Omarchy/Hyprland shortcut management through `sayall shortcut`, with a
  conflict-safe `Ctrl+Slash` default integrated into setup and upgrade flows.
- Local `sayall keywords` CRUD backed by an atomic, private XDG configuration
  file shared by streaming STT, REST fallback, and LLM cleanup.

### Changed

- Daemon sources and package/build inputs now use the dedicated `daemon/`
  directory instead of the former top-level `src/` tree.
- `sayall setup` preserves custom and disabled shortcut state, recognizes an
  equivalent existing manual binding, and still configures daemon/HUD services
  when a different binding conflict needs user action.
- Legacy `stt.keyterms` values are imported without rewriting `config.json`;
  exact repeats are deduplicated in first-occurrence order for compatibility.
- The `sayall` AUR package now installs official prebuilt release artifacts,
  the stable source build is named `sayall-src`, and `sayall-git` remains the
  development source build.

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

[Unreleased]: https://github.com/saiemsaeed/sayall/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/saiemsaeed/sayall/compare/v0.1.8...v0.2.0
[0.1.8]: https://github.com/saiemsaeed/sayall/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/saiemsaeed/sayall/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/saiemsaeed/sayall/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/saiemsaeed/sayall/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/saiemsaeed/sayall/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/saiemsaeed/sayall/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/saiemsaeed/sayall/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/saiemsaeed/sayall/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/saiemsaeed/sayall/releases/tag/v0.1.0
