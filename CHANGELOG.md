# Changelog

All notable user-visible changes to SayAll are documented in this file. SayAll
follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] - 2026-08-16

### Added

- Added Verbatim, Clean, and Polished processing modes to the Linux HUD and
  macOS menu. Verbatim sends no transcript to Cerebras, Clean performs only
  local deterministic cleanup, and Polished applies Clean before using the
  structured Cerebras planner with silent Clean fallback.
- Added a deterministic transformation benchmark and release canary covering
  cleanup safety, semantic preservation, and production worker integration.

### Changed

- Made processing-mode configuration updates atomic and concurrency-safe while
  preserving the behavior of existing `llm.enabled` configurations during
  migration.
- Improved Polished mode's handling of acronyms, negation, false starts, and
  cleanup outcomes while retaining provider degradation only in privacy-safe
  local metrics.

### Fixed

- Accepted PipeWire 1.6 `pw-record` status 1 only after SayAll successfully
  sends its expected stop signal, preventing completed Linux recordings from
  being reported as capture failures while preserving genuine early exits.

## [0.2.11] - 2026-08-08

### Added

- Added optional structured Groq formatting that returns anchored edits for
  terminology, punctuation, capitalization, paragraphs, and dictated lists;
  Zig validates and renders every edit from the original Deepgram transcript.
- Added `sayall reload` on macOS and Linux, plus native menu/settings actions,
  so valid configuration and keyword changes apply to the next dictation
  without restarting the application.
- Added privacy-safe live Deepgram REST and streaming benchmark reports with
  WER, CER, post-stop latency, historical comparisons, and macOS/Linux HUD
  evidence.

### Changed

- Changed the optional formatter default to `openai/gpt-oss-20b` and disabled
  LLM formatting for new configurations. Existing users enabling formatting
  should select `openai/gpt-oss-20b` or `openai/gpt-oss-120b`; the legacy
  `llama-3.1-8b-instant` value remains parseable but is unsupported by the
  structured formatter.
- Made release publication depend on successful Deepgram REST and authoritative
  streaming canaries, expected speech/no-speech behavior, and conservative WER
  and CER limits.
- Defined the blocking Linux support cell as current x86-64 Arch Linux with
  Omarchy/Hyprland Wayland; other Linux desktop and distribution combinations
  remain exploratory rather than claimed release targets.

### Fixed

- Prevented optional LLM formatting from answering questions, following
  instructions embedded in dictation, or appending generated prose; any unsafe,
  malformed, or unverifiable plan now returns the unchanged transcript with a
  warning.
- Made configuration reload reject busy or invalid changes without terminating
  the native host or changing the configuration snapshot of an active
  dictation.

## [0.2.10] - 2026-08-06

### Changed

- Rebuilt macOS microphone capture on an input-only Core Audio HAL backend so
  built-in, Bluetooth, and multichannel USB microphones share one reliable
  device-independent capture path without changing the system audio route.
- Made the macOS Input Device menu update immediately when microphones connect,
  disconnect, or become the system default, while hiding internal audio devices.

### Fixed

- Fixed silent capture from native 24-bit multichannel interfaces such as the
  Scarlett 2i2 while preserving MacBook, AirPods, and System Default recording.
- Added bounded buffering, stable input-channel selection, capture watchdogs,
  and callback-safe teardown for disconnected or stalled microphones.

## [0.2.9] - 2026-08-06

### Added

- Added a macOS Input Device submenu with a live System Default option and
  persistent per-device microphone overrides.

### Fixed

- Replaced fragile macOS aggregate-device recording with microphone-only
  capture so Bluetooth sample-rate changes no longer stop recording silently.
- Preserved audio resampling across capture chunks and now fail immediately
  when the active microphone disconnects, is interrupted, or stops unexpectedly.

## [0.2.8] - 2026-08-06

### Fixed

- Made macOS cursor insertion work across hidden and dynamically recreated
  Electron accessibility trees, including Claude Desktop, without app-specific
  exceptions.
- Bound macOS insertion to the original live application process and top-level
  window, revalidated focus and secure input immediately before delivery, and
  targeted paste events to that process instead of the global session.
- Preserved insertion in terminal surfaces such as Ghostty while keeping
  explicit clipboard mode independent of Accessibility APIs.

## [0.2.7] - 2026-08-06

### Changed

- Simplified the macOS menu bar item to show only the waveform icon while
  retaining its SayAll accessibility label and tooltip.

### Fixed

- Fixed cursor insertion in Slack and other Electron-style apps by querying
  the known frontmost application directly for its focused accessibility
  element instead of relying on the system-wide focused-application lookup.

## [0.2.6] - 2026-08-05

### Fixed

- Recreated the macOS audio input graph for every recording so SayAll follows
  the current system-default microphone after an external interface disconnects
  or the default input changes, instead of retaining an incompatible sample
  rate from the previous device.

## [0.2.5] - 2026-08-04

### Changed

- Made the macOS HUD appear immediately after Control+/ while microphone and
  streaming startup continue, matching Linux's explicit starting state.
- Prewarmed the signed processing helper and stopped rebuilding the menu bar
  menu for every audio-level update, reducing work on the main UI thread.
- Added bounded, privacy-safe local macOS startup timing metrics that honor the
  shared metrics enablement and retention settings.

### Fixed

- Corrected helper launch failures during compatibility checks so they no
  longer report an unrelated microphone startup error.

## [0.2.4] - 2026-08-04

### Fixed

- Made the macOS native host honor the shared `type`, `paste`, and `clipboard`
  output modes and `trailing_space` setting. Cursor insertion now targets the
  original editable field with a verified clipboard-backed paste, while failed
  insertion preserves the transcript on the clipboard and reports a native
  warning.
- Fixed silent microphone capture with newer macOS SDKs by explicitly selecting
  active multichannel input and converting it to mono before transcription.

## [0.2.3] - 2026-08-03

### Changed

- Redesigned the macOS and Linux HUDs to match the approved Figma handoff with
  a compact 244×48 pill, platform-consistent recording and processing
  waveforms, updated colors, spacing, typography, and timer presentation.
- Simplified completion feedback so successful typing, pasting, and no-speech
  sessions dismiss silently, while clipboard-only delivery shows the exact
  confirmation `✓  Copied to clipboard` and errors remain visible.
- Applied the shared `hud.show_timer` setting consistently on macOS and Linux.

### Fixed

- Moved macOS transcript-cleanup degradation feedback from the HUD into a
  native warning notification while still delivering the raw transcript.

## [0.2.2] - 2026-08-02

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
- Kept Linux IPC test endpoints within Unix socket path limits in deeply nested
  source-package builds.
- Removed checkout-relative worker lookup from release builds so packaged Linux
  applications resolve only their bundled or installed private worker.
- Made Linux setup wait for the restarted native host's control endpoint before
  reporting success, without retrying toggle operations.

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

[Unreleased]: https://github.com/saiemsaeed/sayall/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/saiemsaeed/sayall/compare/v0.2.11...v0.3.0
[0.2.11]: https://github.com/saiemsaeed/sayall/compare/v0.2.10...v0.2.11
[0.2.10]: https://github.com/saiemsaeed/sayall/compare/v0.2.9...v0.2.10
[0.2.9]: https://github.com/saiemsaeed/sayall/compare/v0.2.8...v0.2.9
[0.2.8]: https://github.com/saiemsaeed/sayall/compare/v0.2.7...v0.2.8
[0.2.7]: https://github.com/saiemsaeed/sayall/compare/v0.2.6...v0.2.7
[0.2.6]: https://github.com/saiemsaeed/sayall/compare/v0.2.5...v0.2.6
[0.2.5]: https://github.com/saiemsaeed/sayall/compare/v0.2.4...v0.2.5
[0.2.4]: https://github.com/saiemsaeed/sayall/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/saiemsaeed/sayall/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/saiemsaeed/sayall/compare/v0.1.8...v0.2.2
[0.1.8]: https://github.com/saiemsaeed/sayall/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/saiemsaeed/sayall/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/saiemsaeed/sayall/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/saiemsaeed/sayall/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/saiemsaeed/sayall/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/saiemsaeed/sayall/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/saiemsaeed/sayall/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/saiemsaeed/sayall/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/saiemsaeed/sayall/releases/tag/v0.1.0
