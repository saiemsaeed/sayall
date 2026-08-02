# ADR: Unified Zig core and CLI with native platform hosts

- **Status:** Accepted
- **Applies to:** SayAll 0.2.0 migration
- **Date:** 2026-08-01
- **Tracks:** SAY-36

## Context

SayAll currently has two working but asymmetric products. On Linux, the Zig
`sayall daemon` owns recording, provider processing, delivery, and state while
the Rust/GTK process subscribes as a HUD. On macOS, the Swift app owns the
complete user-visible session and launches the one-shot Zig `sayall-process`
helper for Deepgram and Groq work. macOS also bundles a Swift command-line
client for native app control.

The 0.2.0 goal is one provider-processing implementation and one public CLI
contract across Linux and macOS without moving permission-sensitive platform
work into Zig or allowing the CLI and UI to become competing state owners.

## Decision

### Product composition

SayAll will have three explicit layers:

1. **The platform-neutral Zig processing core** owns provider configuration
   validation, canonical audio validation, Deepgram REST and streaming,
   optional Groq cleanup, raw-transcript fallback, and normalized processing
   outcomes. File/process framing is an adapter around this core.
2. **One native application host per platform** owns the complete live
   dictation state machine, recording, permissions, shortcuts, UI,
   notifications, cancellation, worker supervision, and text delivery. Swift
   is the macOS host; Rust is the target Linux host.
3. **One public Zig `sayall` CLI** provides the same command names, output,
   errors, and exit codes on both platforms. It controls the native host for
   live dictation and may use the processing worker directly for standalone
   operations such as file transcription. A native UI never executes the CLI
   or parses its output.

The private `sayall-process` executable is a host-managed worker, not a public
CLI or independently installed daemon. It is launched by an absolute,
package-relative path and ships atomically with its host and public CLI.

```text
                    ┌─────────────────────┐
terminal ──────────▶│ public Zig CLI      │
                    └─────────┬───────────┘
                              │ host control for live sessions
                              ▼
                    ┌─────────────────────┐
native UI ─────────▶│ native app host     │
                    └─────────┬───────────┘
                              │ private worker protocol
                              ▼
                    ┌─────────────────────┐
                    │ Zig processing core │
                    │ / sayall-process    │
                    └─────────────────────┘
```

### Ownership invariants

- Exactly one native host owns a live session from trigger through delivery.
- The Zig processing core never requests microphone, Accessibility, input,
  notification, or desktop permission and never delivers text.
- The CLI does not independently record when controlling a native session.
- A worker failure cannot perform text delivery and cannot leave the host with
  two active sessions.
- Streaming failure permits at most one REST fallback. Groq cleanup failure
  preserves the raw transcript with a structured warning.
- Transcript delivery is at most once even when a provider or worker outcome
  is ambiguous. The host is the only delivery authority.
- Secrets are never passed in argv, inherited environment, filenames, logs, or
  persistent request files.

### Contracts

The private processing worker retains its bounded protocol version 1 while the
shared core is extracted. Worker requests are strict: unknown or wrongly typed
fields fail rather than silently changing provider behavior. Result readers
validate required fields and ignore unknown additive object fields. Worker
results distinguish `success`, `no_speech`, and `error`; error and warning codes
are stable machine-readable strings. Control frames are bounded to 64 KiB and
output to 1 MiB. Changing required fields, field meaning, JSON types, framing,
or limits requires a worker protocol version change.

The unified native-host control contract starts at version 2 because the
released private macOS version-1 response used an unstructured error string.
Version 2 has only `status` and `toggle` initially, returns a canonical state,
and uses `{code,message}` errors. `status` never launches an application.
`toggle` may launch the exact installed application, but once a mutating frame
may have been accepted it is never retried by the client. Unknown additive
object fields are ignored; changing required fields, meanings, field types, or
closed state values requires a new version.

Canonical host states are `idle`, `starting`, `recording`, `stopping`,
`processing`, `delivering`, `success`, `error`, and `cancelled`. Error codes are
open for additive values; initial common codes include `busy`, `not_running`,
`incompatible_version`, `invalid_request`, and `unavailable`. Clients branch on
the code, never the display message.

Language-neutral examples for both contracts live in
[`tests/contracts-0.2/`](../tests/contracts-0.2/). Zig, Swift, and
Rust tests consume these same files so contract drift fails CI before a runtime
adapter is replaced.

### Migration and cutover

0.2.0 extraction work preserves current runtime ownership first. Linux keeps
the existing Zig daemon and Linux protocol v1 while the shared processing core,
worker contract, and unified CLI are established. macOS keeps its Swift
Coordinator and existing signed worker boundary.

The Linux daemon must not be partially stripped while it still owns a session.
The Rust process becomes the sole Linux host in one gated migration after it
has parity for capture, state transitions, cancellation, worker supervision,
delivery, shortcuts, configuration, notifications, startup, and recovery. Only
then may packaging disable and remove `sayall.service` and stale endpoints.

Release cutover requires clean-install and 0.1.8-upgrade tests, exactly one
host after upgrade, no duplicate shortcut handling or delivery, worker crash
recovery, provider fallback parity, package-managed autostart, and a documented
rollback path.

### Packaging

Each platform distributes one versioned product containing the native UI,
public `sayall` CLI, and private `sayall-process` worker. Direct macOS installs
retain **Install Command Line Tool…**; Homebrew Cask and AUR expose the public
CLI automatically. The private worker is never linked into `PATH` or updated
independently. Nested macOS executables are signed before the outer app and the
complete bundle is notarized and stapled.

## Linux native-host settings and startup

The Rust `sayall-hud` process is the sole Linux session owner and provides a small GTK settings
window. Canonical initialization and read-only validation remain Zig-owned and
are requested through bounded private `sayall-process` operations; the UI does
not execute or parse the public `sayall` CLI and never displays credentials.
The package-managed `sayall-hud.service` is the only login startup mechanism.
Its `--autostart` activation is silent; a later interactive invocation is
forwarded through GApplication and opens the singleton Settings window. Settings
enables or disables that user unit without stopping its own running process.

The Settings action can bind
an XDG GlobalShortcuts portal session. Autostart never performs the first bind;
even after the private consent marker exists, restoration is reported as needing
setup because ashpd/portal behavior cannot guarantee a prompt-free bind. Session
loss and removal of the accepted shortcut immediately remove Active status. The
host registers stable app ID `dev.sayall.Hud` on the same dedicated D-Bus
connection used for the portal session; physical portal identity remains an
acceptance gate. Missing portal support does not
prevent startup. The existing Hyprland `sayall toggle` binding remains the
wlroots fallback and is not rewritten by the native host.

## Rejected alternatives

- **A persistent cross-platform Zig daemon:** adds launchd/systemd lifecycle,
  reconnection, audio transport, and version-skew concerns while native apps
  still have to own protected OS operations.
- **A Zig C ABI for 0.2.0:** makes allocator ownership, callbacks, threading,
  cancellation, and crashes part of the Swift/Rust process contract. The
  existing bounded worker boundary is simpler and isolated. An ABI can be
  reconsidered only after measurement shows worker transport is inadequate.
- **Having the UI invoke the CLI:** makes human output an application API and
  obscures session ownership. UI and CLI instead call the same host operation
  through direct calls and the control protocol, respectively.

## Consequences

- Provider behavior and public terminal behavior can converge without forcing
  identical platform process topology during migration.
- macOS retains correct TCC, AVFoundation, AppKit, and Accessibility ownership.
- Linux host migration is intentionally substantial; the current Rust HUD is
  not treated as if it already owns recording or delivery.
- Worker startup overhead is accepted for crash isolation and atomic packaging.
- The public CLI remains useful while live microphone authority stays in the
  native application.

## Public CLI syntax during the 0.2.0 migration

The cross-platform public surface currently consists of `help`, `version`,
`status`, `toggle`, `config init`, `config validate [--json]`,
`doctor [--json]`, `update`, and:

```text
sayall transcribe <WAV> [--raw] [--json]
```

`transcribe` accepts one WAV file of at most 10 MiB. It copies the input to a
private, bounded scratch file and sends credentials only through the private
worker's stdin protocol. Human output is transcript-only; `--json` emits the
canonical worker result for automation, and `--raw` disables optional LLM
cleanup. Status diagnostics go to stderr and never include credentials or
transcript text. The native UI does not invoke this command.

`doctor` performs read-only configuration, packaged-worker/protocol,
executable, native-host status, and platform checks. Its bounded JSON output
contains no credentials or transcripts and exits 1 when a check fails. The
macOS host protocol cannot expose Accessibility or microphone authorization,
so doctor does not claim to diagnose those permissions. `update` refuses while
the host is non-idle. Linux retains its AUR channel; macOS upgrades only a
detected Homebrew Cask installation and directs DMG installations to update
manually.
