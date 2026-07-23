# Changelog

All notable user-visible changes to SayAll are documented in this file. SayAll
follows [Semantic Versioning](https://semver.org/).

## [0.1.6] - 2026-07-23

Release preparation: implementation and automated readiness are complete, but
publication remains gated on external signing/notarization prerequisites and
physical Apple Silicon qualification.

### Added

- Native Apple Silicon menu-bar application for macOS 15.0 or later, packaged
  as a directly distributed ZIP with an isolated per-recording Zig helper.
- Native microphone permission/capture, shared config-file provider credentials,
  fixed global Control+/ toggle with menu fallback, Accessibility-authorized paste,
  and clipboard fallback.
- Developer ID signing, Hardened Runtime, notarization, stapling, verification,
  checksum, and macOS CI/release packaging automation.

### Changed

- The macOS app owns lifecycle, menu/status UI, config loading, permissions, capture, focus,
  insertion, temporary files, and packaging; Zig owns validated WAV processing,
  Deepgram streaming with REST fallback, and optional Groq cleanup through bounded versioned JSON
  on inherited stdin/stdout.
- Release output can combine the macOS arm64 ZIP with Linux and source assets
  in one `SHA256SUMS`; Linux AUR/install/update behavior is unchanged.

### Known limitations

- macOS support is arm64 and macOS 15.0+ only; there is no Intel, universal,
  Rosetta, App Store, DMG/PKG, Homebrew, or automatic-update claim.
- Secure/inaccessible fields and apps rejecting Accessibility insertion fall
  back to the clipboard; shortcut conflicts require the menu action.
- Cloud access is required, only the default input is supported, recordings are
  capped at five minutes, and physical-device qualification is still pending.

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

[0.1.6]: https://github.com/saiemsaeed/sayall/compare/v0.1.5...HEAD
[0.1.5]: https://github.com/saiemsaeed/sayall/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/saiemsaeed/sayall/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/saiemsaeed/sayall/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/saiemsaeed/sayall/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/saiemsaeed/sayall/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/saiemsaeed/sayall/releases/tag/v0.1.0
