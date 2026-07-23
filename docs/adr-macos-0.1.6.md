# ADR: Native macOS product architecture for 0.1.6

- **Status:** Accepted
- **Applies to:** SayAll 0.1.6
- **Date:** 2026-07-23
- **Evidence gate:** Pending physical Apple Silicon qualification and external
  Developer ID/notarization prerequisites

## Context

The 0.1.4 platform ADR assigned native macOS concerns to Swift/AppKit but
deferred linked-library versus helper composition. The implemented 0.1.6
product now supplies enough validated constraints to select that topology. This
record supersedes only that deferral; Linux protocol, composition, and support,
and the Windows deferral, are unchanged.

The first macOS product is the menu-bar `SayAll.app`, bundle identifier
`pro.saiem.sayall`, for Apple Silicon arm64 and macOS 15.0 or later. It is a
direct ZIP distribution outside the App Store.

## Decision

### Ownership and topology

Swift/AppKit owns app lifecycle, status item/menu, shared config loading,
microphone capture and TCC permission, the fixed global Control+/ Carbon
hotkey and menu fallback, Accessibility-authorized Command+V with clipboard
fallback, temporary audio, and packaging. The app bundles and runs
`sayall-process` for each recording. The Zig helper owns the recording-lifetime
Deepgram stream, strict WAV validation, REST fallback, and optional Groq cleanup.

```text
Control+/ or menu
       │
       ▼
Swift/AppKit state machine ──AVFoundation──▶ private WAV + raw S16 sidecar
       │                                             │
       │ bounded start/finish JSON + keys            │ helper tails during capture
       └──────────────────────▶ sayall-process ◀─────┘
                                      │ WSS audio; HTTPS fallback
                                      ▼
                                  Deepgram
                                      │ raw transcript
                         optional HTTPS transcript
                                      ▼
                                    Groq
                                      │ bounded JSON response on stdout
                                      ▼
                 Command+V request with clipboard fallback
```

The app-helper contract is bounded, versioned JSON over inherited stdin and
stdout. It is not Linux control protocol v1. Keys are request fields on stdin,
never argv, environment, or logs. The helper is one-shot: there is no daemon,
socket, reconnection, or persistent helper state. The app enforces a 45-second
post-stop processing timeout and terminates a hung invocation. EOF without an
explicit finish command cancels the helper rather than processing abandoned audio.

### State and failure decisions

The app progresses through idle, recording, processing, delivery, and terminal
success/warning/error states; one recording and one helper invocation may be
active. Recordings below 300 ms are rejected and recording ends at 300 seconds.
The helper accepts only canonical PCM S16LE mono 16 kHz WAV input. Capture,
permission, validation, provider, malformed/oversized response, timeout, and
insertion failures return to idle with user-visible status. If optional Groq
cleanup fails after Deepgram succeeds, the raw transcript is delivered with a
warning rather than discarded. If synthetic paste is unavailable or rejected,
the transcript remains on the clipboard for manual paste. Hotkey registration
conflicts retain the menu action.

### Security and privacy

Deepgram and Groq credentials use the existing Linux-compatible
`$XDG_CONFIG_HOME/sayall/config.json` or `~/.config/sayall/config.json` schema.
Environment overrides and `$VARIABLE` references are supported when present in
the app process; Finder does not read interactive shell startup files. Users
must protect the plaintext config with mode `0600`. Audio is streamed to Deepgram
during recording; the completed private WAV is sent only for REST fallback. The
transcript is sent to Groq only when `llm.enabled` is true and a Groq key
is present. Raw WAV/PCM files have private access and are deleted after every
terminal path. Startup scavenging removes remnants from interrupted prior runs.
Logs omit keys, audio, transcript, and sensitive request content. There is no
telemetry or history.

Microphone and Accessibility grants remain user-controlled OS permissions.
SayAll does not treat build success or entitlement presence as proof that a
user has granted either permission.

### Signing and distribution

The nested helper is signed first, then the app, using Developer ID Application
identity and Hardened Runtime. The resulting app is notarized, stapled, and
verified before `sayall-VERSION-macos-arm64.zip` and `SHA256SUMS.macos` are
created. Direct ZIP is the only selected macOS channel.

Automated CI/build success demonstrates implementation readiness, not the
support publication gate. Publication requires the external credentials and
completed physical matrix in [the qualification checklist](macos-release-qualification.md).

## Explicit non-goals

0.1.6 does not provide or claim a macOS daemon, CLI, launchd service, login
item, Linux protocol-v1 socket, Intel binary,
universal binary, Rosetta support, auto updater, DMG, PKG, Homebrew formula, or
App Store distribution. Multiple input selection, local/offline providers,
telemetry, and transcript history are also out of scope.

## Consequences

- Native code retains authority over privacy-sensitive OS integration and the
  helper remains small, platform-free, bounded, and replaceable.
- Per-recording helper startup cost is accepted in exchange for isolation and
  simpler lifecycle/recovery; Deepgram connection/upload overlaps recording.
- A private raw S16 sidecar provides a bounded append-only stream source while
  the canonical completed WAV remains authoritative for validation and fallback.
- Apple Silicon/macOS claims cannot be published until the physical evidence
  gate is recorded, even when automated checks are green.
