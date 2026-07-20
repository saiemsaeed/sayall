# SayAll

A WisprFlow-style voice dictation daemon for Linux, written in Zig.
Toggle a hotkey, speak, toggle again, and text is typed into your focused
window. When Groq cleanup is configured, filler words and false starts are
removed before output.

- **STT:** Deepgram Nova-3 (cloud, batch upload)
- **Cleanup:** LLM pass (Groq `llama-3.1-8b-instant`) — removes filler words,
  false starts, stutters; fixes grammar and punctuation without changing meaning
- **Platform:** Wayland (developed on Hyprland), audio via PipeWire
- **Zig dependencies:** none; the implementation uses Zig's standard library
- **Runtime dependencies:** PipeWire `pw-record`, `wtype`, `wl-copy`, and
  `notify-send`
- **Linux HUD:** Rust, GTK4, and gtk4-layer-shell
- **Requires:** Zig 0.16.x

## Getting Started

```sh
# 1. Build and install
zig build -Doptimize=ReleaseFast
cp zig-out/bin/sayall ~/.local/bin/
cargo build --release --manifest-path ui/linux/Cargo.toml
cp ui/linux/target/release/sayall-hud ~/.local/bin/

# 2. Configure API keys (file is created with your keys)
mkdir -p ~/.config/sayall
$EDITOR ~/.config/sayall/config.json   # see Configuration below
chmod 600 ~/.config/sayall/config.json

# 3. Run the daemon — either via systemd (recommended)…
mkdir -p ~/.config/systemd/user
cp sayall.service ~/.config/systemd/user/
cp sayall-hud.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now sayall sayall-hud

#    …or via Hyprland exec-once
#    exec-once = sayall daemon

# 4. Bind the toggle key in hyprland.conf
#    bind = SUPER, F9, exec, sayall toggle
```

Verify it works: `sayall status` → `idle`; `sayall transcribe some.wav` →
transcript. Then press the bind, speak, press it again.

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

## Architecture

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
is documented in `docs/protocol-v1.md` and is intended for the future Swift
macOS UI as well.

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
├── src/
│   ├── main.zig               # CLI, mic-test, and transcribe commands
│   ├── daemon.zig             # recording/processing state machine
│   ├── ipc.zig                # unix socket @ $XDG_RUNTIME_DIR/sayall.sock
│   ├── recorder.zig           # pw-record spawn/SIGINT, WAV validation
│   ├── stt/deepgram.zig       # raw-body POST, JSON parse
│   ├── llm/groq.zig           # OpenAI-compatible chat completions
│   ├── typer.zig              # direct wtype delivery, clipboard fallback
│   ├── config.zig             # ~/.config/sayall/config.json + env var keys
│   └── notify.zig             # notify-send for state/error feedback
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

`~/.config/sayall/config.json` (keys overridable by env):

```json
{
  "stt": {
    "provider": "deepgram",
    "api_key": "$DEEPGRAM_API_KEY",
    "model": "nova-3",
    "language": "en",
    "keyterms": ["SayAll", "Hyprland", "Model Context Protocol"],
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

`stt.keyterms` is a global vocabulary of names, jargon, and phrases that Nova-3
should recognize more accurately. Keyterms are applied to both streaming and
REST fallback transcription, with their spelling and capitalization also
provided to LLM cleanup when enabled. Keep the list focused on uncommon or
frequently misrecognized terminology; Deepgram allows up to 100 keyterms and
enforces a 500-token limit per request.

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

## Hyprland Setup

```conf
exec-once = sayall daemon
bind = SUPER, F9, exec, sayall toggle
# optional: raw (no LLM cleanup) on a second bind
bind = SUPER SHIFT, F9, exec, sayall toggle --raw
```

(A systemd `--user` service is the alternative to `exec-once`.)

## Limitations

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
