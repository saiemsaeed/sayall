# SayAll

A voice-dictation product for Linux and Apple Silicon macOS. Toggle a hotkey,
speak, toggle again, and text is inserted into your focused window. When Groq
cleanup is configured, filler words and false starts are removed before output.

- **STT:** Deepgram Nova-3 (cloud streaming with REST fallback)
- **Cleanup:** LLM pass (Groq `llama-3.1-8b-instant`) — removes filler words,
  false starts, stutters; fixes grammar and punctuation without changing meaning
- **Zig dependencies:** one pinned WebSocket library; otherwise Zig's standard
  library
- **Runtime dependencies:** PipeWire `pw-record`, `wtype`, `wl-copy`, and
  `notify-send`
- **Linux HUD:** Rust, GTK4, and gtk4-layer-shell
- **Requires:** Zig 0.16.x

## Platform support

| Platform / target | 0.1.6 status |
| --- | --- |
| x86-64 Arch Linux with Omarchy (Wayland/Hyprland) | Supported and tested; daemon/CLI/HUD and AUR or archive distribution |
| Apple Silicon (`arm64`), macOS 15.0 or later | Native menu-bar product implemented; direct ZIP distribution. Publication support remains gated on the pending physical-device and external signing/notarization qualification in [the macOS checklist](docs/macos-release-qualification.md) |
| Windows (`x86_64-windows` compile target) | Core compile readiness only; no app, runtime, package, or installable output |

Other Linux systems may work but are not tested or supported. The macOS product
does not claim Intel, universal-binary, or Rosetta support. Windows readiness
does not constitute product or runtime support. The accepted
[`0.1.6 macOS architecture ADR`](docs/adr-macos-0.1.6.md) selects the macOS
topology; the current Linux control and HUD compatibility API remains the
Linux-only [`protocol-v1 contract`](docs/protocol-v1.md).

## Getting Started

### Install on Apple Silicon macOS

SayAll for macOS is `SayAll.app`, a native menu-bar application for arm64 Macs
running macOS 15.0 or later. It is distributed directly as
`sayall-VERSION-macos-arm64.zip`, not through the App Store. After downloading
the ZIP and `SHA256SUMS` from the same release, verify and install it:

```sh
archive=sayall-VERSION-macos-arm64.zip
awk -v file="$archive" '$2 == file' SHA256SUMS | shasum -a 256 -c -
unzip "$archive"
# Drag SayAll.app to /Applications in Finder.
open /Applications/SayAll.app
```

macOS reads the same `~/.config/sayall/config.json` provider configuration as
Linux. Put the Deepgram key in `stt.api_key`; optionally put a Groq key in
`llm.api_key` and set `llm.enabled` to `true`. Protect the plaintext file with
`chmod 600 ~/.config/sayall/config.json`; see [Configuration](#configuration)
for the full schema. On the first dictation, grant Microphone and Accessibility
when macOS requests them; SayAll detects the Accessibility grant without an app
restart. Accessibility affects automatic paste only and never blocks recording.
Press **Control+/** to start recording, speak, then press it again to stop and
transcribe. The same actions are available from the menu bar if that fixed
global shortcut conflicts with another app. SayAll attempts
an Accessibility-authorized Command+V at the currently focused cursor and
leaves the text on the clipboard as a manual fallback.

The default input device is used. Recordings shorter than 300 ms are rejected
and recording stops at five minutes. Deepgram and a network connection are
required; when enabled, cleanup also sends the transcript to Groq. A cleanup
failure still delivers the raw transcript and shows a warning.

#### Update or uninstall on macOS

Updates are manual: quit SayAll, download and checksum-verify the new ZIP,
unzip it, replace `/Applications/SayAll.app`, relaunch, and confirm the version
in the app. There is no auto-updater.

To uninstall, quit SayAll and move `/Applications/SayAll.app` to Trash. The
shared config is retained so Linux or a later installation can continue using
it. If it is no longer needed, remove it manually:

```sh
rm ~/.config/sayall/config.json
rmdir ~/.config/sayall  # succeeds only when otherwise empty
```

Removing the config is irreversible and is not required merely to replace or
update the app. Temporary Application Support recordings are removed on every
terminal path and startup.

### Install on Arch Linux or Omarchy

The stable AUR package builds the release from source:

```sh
yay -S sayall
```

Prebuilt and development variants are also available. Install only one variant
at a time:

| Package | Use case |
| --- | --- |
| `sayall` | Build the latest stable release from source |
| `sayall-bin` | Install official prebuilt release binaries |
| `sayall-git` | Build the latest `main` commit from source |

Configure API keys, keeping the file private:

```sh
mkdir -p ~/.config/sayall
$EDITOR ~/.config/sayall/config.json   # see Configuration below
chmod 600 ~/.config/sayall/config.json

# Start SayAll now and on future graphical logins.
sayall setup
```

`sayall setup` enables and restarts the daemon and HUD services and installs the
default `Ctrl+Slash` Hyprland shortcut for `sayall toggle`. It preserves a
shortcut previously selected or disabled through the SayAll CLI. If
`Ctrl+Slash` is already manually bound to `sayall toggle`, setup recognizes it
as equivalent and leaves the existing line untouched.

Run the installation diagnostics and microphone test:

```sh
sayall --version
sayall doctor
sayall mic-test
```

Verify `sayall status` reports `idle`, then press `Ctrl+Slash`, speak, and press
it again. The transcript should be typed into the focused window.

View or customize the managed shortcut at any time:

```sh
sayall shortcut                 # show the current/default state
sayall shortcut set SUPER+SPACE # choose another Hyprland chord
sayall shortcut reset           # restore Ctrl+Slash
sayall shortcut disable         # keep services, remove the managed binding
```

Shortcut changes are checked against the Hyprland configuration include tree.
SayAll reports the conflicting file and line and does not add an `unbind` or
overwrite another binding. When run inside Hyprland, it reloads the compositor
and checks `hyprctl configerrors`; if safe activation fails, it restores the
previous SayAll files. Outside a Hyprland session it saves the change and tells
you to run `hyprctl reload` inside the session (or log in again).
Variable-based `source`, modifier, and key expressions are not partially
evaluated: shortcut management stops and reports the exact file and line for
manual resolution. A symlinked `hyprland.conf` is likewise rejected before any
shortcut configuration is written.

Update the installed AUR variant and restart both running processes with one
command:

```sh
sayall update
sayall --version
sayall doctor
```

`sayall update` detects whether `sayall`, `sayall-bin`, or `sayall-git` owns
the installation, asks `yay` to update that same package, and only restarts the
services after the package operation succeeds. It deliberately uses the AUR
package rather than overwriting `/usr/bin` directly, preserving package
ownership, dependency handling, checksums, and clean uninstallation. To avoid
losing audio, it refuses to update while the daemon is recording or processing
a clip. After a successful package operation it restarts both services and
re-applies the saved custom, default, or disabled shortcut state. The retired
`sayall-src` name remains recognized by the 0.1.5 and later CLI as a migration
fallback. Installations still running the 0.1.4 `sayall-src` CLI must use the
explicit one-time `yay -S sayall` command below; that older CLI cannot redirect
itself to a package name introduced by a later release.

#### Migrate from the earlier AUR package names

The package transition does not own or remove
`~/.config/sayall/config.json`. Review the AUR helper's conflict-removal prompt
and switch packages in one operation; do not uninstall the old package first.

- Existing `sayall` users will move to the stable source build on upgrade. To
  keep using official prebuilt artifacts instead, run `yay -S sayall-bin`.
- Existing `sayall-bin` users continue to receive prebuilt artifacts under the
  same package name.
- Existing `sayall-src` users should run `yay -S sayall`. The canonical package
  replaces the retired source-suffixed name, but an AUR merge does not rename
  packages already installed on users' machines.

After any switch, run `sayall setup`, `sayall doctor`, and a short dictation
smoke test. Locally installed units in `~/.config/systemd/user` override the
package units; remove obsolete manual units as described below if diagnostics
show paths under `~/.local/bin`.

#### Migrate from a manual installation

Older instructions installed files under `~/.local/bin` and
`~/.config/systemd/user`. Remove those files before installing an AUR package
so they cannot override the package-managed binaries and services. This does
not remove `~/.config/sayall/config.json`:

```sh
systemctl --user disable --now sayall sayall-hud
rm -f ~/.local/bin/sayall ~/.local/bin/sayall-hud
rm -f ~/.config/systemd/user/sayall.service \
      ~/.config/systemd/user/sayall-hud.service
systemctl --user daemon-reload
yay -S sayall
sayall setup
sayall doctor
```

### Build from source

Source builds are intended for contributors. Build and test directly from the
checkout rather than copying over an AUR-managed installation:

```sh
zig build test
zig build check-darwin-core   # portable-core check; does not build SayAll.app
zig build check-windows-core  # compile-only; no Windows product or artifact
zig build -Doptimize=ReleaseFast
cargo test --locked --manifest-path ui/linux/Cargo.toml
cargo build --locked --release --manifest-path ui/linux/Cargo.toml

# Stop the packaged daemon before running a checkout build; both use the same
# socket and configuration.
systemctl --user stop sayall sayall-hud
./zig-out/bin/sayall daemon --verbose
```

In another terminal, use `./zig-out/bin/sayall status`, `toggle`, and `stop`.
Restart the packaged installation afterwards with
`systemctl --user start sayall sayall-hud`.

Print the installed release version with `sayall --version`.

The Darwin core command is only a portable-core compilation check and is not
the native macOS product build. The Windows command is likewise a contributor
readiness check, not an app, runtime, package, or supported product.

After changing `~/.config/sayall/config.json`, restart the systemd user service
to load the new configuration:

```sh
sayall restart
```

The HUD reconnects automatically. This command requires the recommended
systemd user-service setup above; if running `sayall daemon` directly, stop and
start that foreground process instead.

Manage recognition keywords locally with the CLI. Quote phrases and any value
whose leading or trailing spaces are intentional:

```sh
sayall keywords list
sayall keywords search protocol
sayall keywords add SayAll "Model Context Protocol" " München "
sayall keywords update SayAll sayALL
# `rename` is an alias for `update`.
sayall keywords delete " München "
sayall keywords clear --confirm
```

Matching for updates and deletion is exact, including spelling, case, Unicode,
and spaces. Search is a substring search with ASCII case folding. Mutating
commands print the `sayall restart` command needed to activate the change in a
running daemon; restart the foreground process instead when not using systemd.

View persistent transcription metrics:

```sh
sayall stats
sayall stats --json
```

Metrics contain only timing, outcome, audio-duration, and numeric output-size
metadata. Transcript text, audio, API keys, provider bodies, and recording
paths are never persisted.

Test the OS-default microphone before dictating:

```sh
sayall mic-test
# Speak for three seconds. The result reports OK, VERY QUIET, or SILENCE.
# Test a particular PipeWire node name or serial:
sayall mic-test 3687
```

For debugging: `sayall daemon --verbose` in a terminal logs every stage with
per-stage timings. `SAYALL_VERBOSE=1` works too.

### Install a release archive

Release archives contain both executables, documentation, the license, and
systemd user-service files. AUR installation is preferred on Arch Linux. Do
not combine this manual installation with an AUR package. After downloading
and verifying the archive's entry in `SHA256SUMS`, install it for the current
user:

```sh
sudo pacman -S --needed pipewire-audio wtype wl-clipboard libnotify gtk4 gtk4-layer-shell
sha256sum --check --ignore-missing SHA256SUMS
# Replace VERSION with the published version from the archive filename.
tar -xzf sayall-VERSION-linux-x86_64.tar.gz
cd sayall-VERSION-linux-x86_64
install -Dm755 -t ~/.local/bin bin/sayall bin/sayall-hud
install -Dm644 -t ~/.config/systemd/user share/systemd/user/*.service
systemctl --user daemon-reload
systemctl --user enable --now sayall sayall-hud
```

Configuration and shortcut setup are the same as for an AUR installation; run
`sayall setup` after installing the files and user units.

### Uninstall

Disable the managed shortcut while the CLI is still installed, then stop the
services and remove the package variant:

```sh
sayall shortcut disable
systemctl --user disable --now sayall sayall-hud
yay -Rns sayall # or sayall-bin / sayall-git
```

If disable reports that the shortcut is an external manual binding, remove
that `sayall toggle` line from `~/.config/hypr/bindings.conf` instead.

Package removal deliberately preserves user configuration. To remove every
shortcut trace as well, delete the block between `BEGIN SAYALL MANAGED
SHORTCUT` and `END SAYALL MANAGED SHORTCUT` in
`~/.config/hypr/hyprland.conf`, plus `~/.config/hypr/sayall.conf` and
`~/.config/sayall/shortcut.json`, then run `hyprctl reload`. After all SayAll
commands have stopped, `~/.config/sayall/shortcut.lock` can also be removed.
Keep `~/.config/sayall/config.json` if you may reinstall and want to retain
provider settings.

## Architecture

### macOS

The stable bundle identifier is `pro.saiem.sayall`. Swift/AppKit owns the menu
bar UI, lifecycle, config loading, native microphone/TCC,
Control+/ Carbon hotkey and menu fallback, Accessibility-authorized paste and
clipboard fallback, temporary audio, and packaging. It invokes the bundled
`sayall-process` helper once per recording. The Zig helper streams private raw
PCM to Deepgram during capture, validates the completed PCM S16LE mono 16 kHz
WAV, falls back to REST when streaming fails, and optionally runs Groq cleanup.

The app and helper exchange bounded, versioned JSON over inherited stdin and
stdout. API keys are never passed in argv or environment variables and are not
logged. Canonical WAV and streaming PCM paths are private; post-stop processing
has a 45-second app-side timeout. Raw audio is deleted after every terminal path, with startup
scavenging for interrupted runs. There is no daemon, socket, Linux protocol
v1, CLI, launchd service, login item, or transcript history on
macOS. See the [macOS architecture ADR](docs/adr-macos-0.1.6.md).

Provider settings use the same `$XDG_CONFIG_HOME/sayall/config.json` or
`~/.config/sayall/config.json` schema as Linux. The app reloads it before each
recording. Environment overrides work when the app is launched from a shell;
Finder launches do not inherit interactive shell-file variables. Audio is streamed
to Deepgram during recording and, only when `llm.enabled` is true and a Groq key is present, the
transcript is sent to Groq. SayAll collects no telemetry.

### Linux

```
Hyprland bind ──exec──▶ sayall toggle ──unix socket──▶ sayall daemon
                                                          │ JSON events
                                                          ▼
                                                  Rust/GTK recording HUD
                                                          │ toggle ON
                                                    spawn pw-record (raw PCM)
                                                          │ 50-100 ms frames
                                             WSS api.eu.deepgram.com/v1/listen
                                                          │ toggle OFF
                                                 CloseStream → final text
                                                          │ REST fallback uses WAV
                                                          │ raw transcript
                                                    POST Groq chat/completions (cleanup)
                                                          │ clean text
                                                     wtype → focused window
```

The Zig binary provides the daemon and CLI. The separate `sayall-hud` process
subscribes to the versioned JSON API at `$XDG_RUNTIME_DIR/sayall.sock`. It
receives state, processing-stage, error, completion, and normalized audio-level
events; it never receives raw microphone audio or transcripts. The hotkey is
owned by your compositor, so the HUD never steals focus.

## Linux HUD

The HUD is a transparent bottom-center layer-shell surface for Hyprland,
wlroots compositors, and KDE Wayland. It displays:

- live recording bars driven by RMS/peak events;
- elapsed recording time;
- transcribing, cleanup, and typing stages;
- short success and error states.

It automatically reconnects after either process restarts. The wire protocol
is documented in [`docs/protocol-v1.md`](docs/protocol-v1.md). Its current
scope and the native-platform ownership boundaries are defined by the
[`0.1.4 platform support ADR`](docs/adr-platform-ownership-and-support.md).

## Provider Choices (and why)

### STT: Deepgram Nova-3 — ~$0.26/hr

| Candidate | Cost/hr | Latency (10s clip) | Verdict |
|---|---|---|---|
| **Deepgram Nova-3** ✅ | ~$0.26 | ~0.3–0.8s | Smart Formatting (punctuation/casing) included free; simplest API (raw WAV body, no multipart — a real win in Zig); $200 free credit ≈ 770 hrs |
| Groq Whisper v3 Turbo | $0.04 | ~0.3–0.6s | Cheapest/fastest; roadmap candidate |
| OpenAI gpt-4o-transcribe | $0.36 | ~1–2s | Strong alternative; not implemented yet |
| AssemblyAI Universal-3.5 | $0.21 | slowest | Upload→poll model; wrong fit for dictation |

### LLM cleanup: Groq `llama-3.1-8b-instant`

840 tok/s, $0.05/$0.08 per 1M tokens — sub-500ms and effectively free at
dictation volume (~100 tokens per 30s clip). OpenAI-compatible chat-completions
API = plain JSON from Zig. Only the Groq provider is currently implemented.

**Realistic cost:** ~2h dictation/day → ~$10/mo STT (after free credit) + ~$0.15/mo LLM.

## Project Layout

```
sayall/
├── build.zig                  # zig build, native target
├── build.zig.zon              # package metadata and minimum Zig version
├── sayall.service             # optional systemd user unit
├── daemon/
│   ├── main.zig               # CLI, mic-test, and transcribe commands
│   ├── keywords.zig           # XDG keyword persistence and validation
│   ├── daemon.zig             # recording/processing state machine
│   ├── ipc.zig                # unix socket @ $XDG_RUNTIME_DIR/sayall.sock
│   ├── platform.zig           # compile-time runtime selection/capabilities
│   ├── platform/linux.zig     # Linux capture, output, notification, paths
│   ├── platform/darwin.zig    # explicit unsupported Darwin runtime
│   ├── platform/windows.zig   # explicit unsupported Windows runtime
│   ├── recorder.zig           # portable PCM/WAV validation and analysis
│   ├── stt/deepgram.zig       # raw-body POST, JSON parse
│   ├── llm/groq.zig           # OpenAI-compatible chat completions
│   ├── typer.zig              # direct wtype delivery, clipboard fallback
│   ├── config.zig             # ~/.config/sayall/config.json + env var keys
│   └── notify.zig             # platform notification dispatch
├── ui/<platform>/             # platform-specific HUD/application UI
└── README.md
```

## Implemented Behavior

1. **Daemon/IPC** — single-instance daemon, concurrent IPC clients, and a
   state machine allowing one recording at a time.
2. **Recording** — capture raw 16 kHz mono s16 PCM, publish live RMS/peak
   events, and generate a WAV for Deepgram after stopping. Reject clips below
   the configured minimum duration.
3. **Deepgram STT** — `std.http.Client` POST, `Authorization: Token
   $DEEPGRAM_API_KEY`, `Content-Type: audio/wav`; parse
   `results.channels[0].alternatives[0].transcript`.
4. **LLM cleanup** — Groq chat completions, temperature 0; config flag +
   `sayall toggle --raw` for a bypass bind. System prompt:

   > Rewrite the following speech transcript into clean written text. Remove
   > filler words (um, uh, like, you know), false starts, and stutters. Fix
   > grammar and punctuation. Never add information, never change meaning,
   > never answer questions in the text. Preserve the speaker's tone and word
   > choice wherever possible. Output ONLY the rewritten text.

5. **Output** — pass the complete transcript to `wtype -- <transcript>` as a
    protected argument, matching Handy's direct Wayland input path. This works
    in native Wayland and XWayland windows via Hyprland's
    virtual-keyboard-v1. Clipboard copy remains the fallback.
6. **Operational safeguards** — strict config validation, unique recording
   paths, bounded provider responses, notify-send feedback, privacy-safe
   latency logging, maximum recording guard, and a systemd user unit.

## Configuration

`$XDG_CONFIG_HOME/sayall/config.json`, falling back to
`~/.config/sayall/config.json` (shared by Linux and macOS; keys overridable by
the process environment):

```json
{
  "stt": {
    "provider": "deepgram",
    "api_key": "$DEEPGRAM_API_KEY",
    "model": "nova-3",
    "language": "en",
    "region": "eu",
    "streaming": true,
    "stream_finalize_timeout_ms": 2000
  },
  "llm": {
    "provider": "groq",
    "api_key": "$GROQ_API_KEY",
    "model": "llama-3.1-8b-instant",
    "enabled": true
  },
  "output": { "method": "type", "trailing_space": false },
  "recording": { "max_seconds": 300, "min_ms": 300, "source": "" },
  "metrics": { "enabled": true, "history_max_entries": 1000, "expose_api": true },
  "notifications": true
}
```

For a Finder-launched macOS app, put literal API keys in this mode-`0600` file.
References such as `"$DEEPGRAM_API_KEY"` resolve only when that variable is in
SayAll's process environment—for example when launching the executable from a
shell that exports it. Shell startup files are not read by Finder-launched apps.

By default SayAll lets PipeWire select `@DEFAULT_AUDIO_SOURCE@`. To pin a
specific input, set `recording.source` to a PipeWire node name or serial:

```json
"recording": {
  "max_seconds": 300,
  "min_ms": 300,
  "source": ""
}
```

An empty `source` follows the OS default, including future default-device
changes.

Output method `type` passes the complete transcript directly to `wtype`. Use
`clipboard` to copy without typing.

Deepgram region is allow-listed to `global`, `eu`, or `au`. The regional
endpoint changes data-processing location and network latency without changing
credentials or the Nova-3 model.

Keywords are a global vocabulary of names, jargon, and phrases that Nova-3
should recognize more accurately. Manage them with `sayall keywords`; the
authoritative file is `$XDG_CONFIG_HOME/sayall/keywords.json`, falling back to
`~/.config/sayall/keywords.json`. It is written atomically with mode `0600`, and
the containing directory is restricted to mode `0700`. Keep the list focused
on uncommon or frequently misrecognized terminology. SayAll rejects empty or
duplicate entries, control characters, entries over 256 bytes, more than 100
entries, and lists over 4096 bytes. Deepgram also enforces its request token
limit.

For compatibility, if the keyword file is absent and an older config contains
`stt.keyterms`, Linux SayAll validates and atomically imports that list on first load;
the macOS app consumes the validated legacy list without modifying configuration.
On Linux, legacy exact duplicates are collapsed without reordering: the first
spelling, case, and spacing is retained. The keyword file is authoritative after
migration; the old field is not rewritten and can be removed from `config.json`
after verifying `sayall keywords list`. Streaming, REST fallback, and LLM
cleanup all consume this same effective keyword list while preserving spelling,
case, spaces, and Unicode.

Streaming sends raw 16 kHz mono PCM while recording and inserts text only after
Deepgram finalizes the stream. The complete local recording is retained until
then and automatically uses regional REST transcription if connection,
protocol, or finalization fails. Set `stt.streaming` to `false` to force REST.
Socket connect, handshake, read, write, and finalization waits are bounded.
Cancellation also stops waiting after a fixed deadline; a pathological system
DNS resolver may leave its detached lookup worker alive until resolution ends.

Metrics are stored at `$XDG_STATE_HOME/sayall/metrics-v2.json`, or
`~/.local/state/sayall/metrics-v2.json`. Existing v1 counters and history are
imported automatically. The directory is mode `0700`, files are mode `0600`,
all-time counters are retained, and detailed metadata rotates after the
configured number of entries. Normalized statistics use successful entries in
that bounded history; legacy records have no word or character counts. Stream
failures are recorded separately from the successful REST fallback. Provider
latency covers the full provider operation; stream stop-to-final latency is
also retained as a dedicated responsiveness metric.

### Backup and removal

Back up both `config.json` and `keywords.json` from the SayAll directory under
`$XDG_CONFIG_HOME` (or `~/.config/sayall`). `config.json` can contain API-key
references or secrets, so keep backups private. Package removal and the manual
installation cleanup commands intentionally leave this directory in place.

After uninstalling SayAll, remove its local configuration only if it is no
longer needed. This is irreversible unless backed up:

```sh
# Default XDG location; adjust if XDG_CONFIG_HOME is set.
rm ~/.config/sayall/config.json ~/.config/sayall/keywords.json
rm -f ~/.config/sayall/keywords.json.lock
rmdir ~/.config/sayall  # succeeds only when the directory is otherwise empty
```

The adjacent `keywords.json.lock` is coordination metadata; remove it only
after all SayAll processes have stopped. Persistent metrics are separate under
`$XDG_STATE_HOME/sayall` (or `~/.local/state/sayall`) and must be backed up or
removed independently.

## Hyprland Setup

The supported Omarchy setup is managed through the CLI:

```sh
sayall setup                  # services + saved shortcut; default Ctrl+Slash
sayall shortcut show
sayall shortcut set SUPER+H
sayall shortcut reset
sayall shortcut disable
```

SayAll stores shortcut intent in `~/.config/sayall/shortcut.json`, generates
`~/.config/hypr/sayall.conf`, and adds one marked source block to
`~/.config/hypr/hyprland.conf`. Repeated setup and upgrade runs are idempotent
and keep a custom or disabled state. A different existing binding is never
silently replaced. Shortcut errors do not prevent `sayall setup` from enabling
and restarting the daemon and HUD services, though setup exits unsuccessfully
until the shortcut conflict is resolved or the managed shortcut is disabled.

The shortcut manager intentionally controls only the normal `sayall toggle`
binding. To keep a second raw/no-cleanup shortcut, add it normally to
`~/.config/hypr/bindings.conf`; for example:

```conf
bindd = SUPER SHIFT, F9, Raw SayAll dictation, exec, sayall toggle --raw
```

On upgrade from a manual `bind = CTRL, SLASH, exec, sayall toggle` line, setup
recognizes the equivalent binding and does not take ownership of or rewrite
it. `shortcut set` and `shortcut disable` will likewise refuse to claim that
external binding; remove the manual line first if you later want the SayAll CLI
to manage the shortcut. `shortcut reset` treats the external default as already
satisfied.

## Limitations

- **Support scope** — Linux support is limited to x86-64 Arch Linux running
  Omarchy. macOS is Apple Silicon arm64 on macOS 15.0 or later, with physical
  publication qualification still pending. Other environments may work but
  are not supported.
- **macOS insertion** — secure or noneditable fields and apps that reject
  synthetic Command+V use clipboard fallback. A Control+/ conflict uses
  the menu action instead. macOS supports only the default input, cloud
  providers/network are required, and recordings are limited to five minutes.
- **REST network deadlines** — provider responses are memory-bounded, but an
  explicit end-to-end REST cancellation deadline is still roadmap work.
- **Wayland input** — direct output requires a compositor implementing the
  virtual-keyboard protocol used by `wtype`.
- **Final-only output** — audio streams while recording, but text is inserted
  only after Deepgram returns its final transcript.

## Success Criteria

Press bind → speak → press bind → text typed into the focused window. The
current test suite covers configuration validation, strict WAV parsing and
level analysis, and provider response parsing; daemon and HTTP integration
tests remain roadmap work.

## Versioning and releases

SayAll follows [Semantic Versioning](https://semver.org/). The Linux daemon,
CLI, and HUD and the macOS app/helper are released under one product version.
Protocol versions are independent: SayAll 0.1.6 continues to use the documented
[`protocol-v1 contract`](docs/protocol-v1.md) for Linux only; the macOS helper
contract is separate.

During the pre-1.0 period, patch releases remain backward-compatible whenever
possible. A minor release may make a documented breaking change to
configuration or behavior. See `CHANGELOG.md` for user-visible changes and
`docs/releasing.md` for the release process.

SayAll is licensed under the MIT License. See `LICENSE`.
