# SayAll Control Protocol v1

SayAll uses bounded newline-delimited JSON over a private Unix domain socket.
Linux uses `$XDG_RUNTIME_DIR/sayall.sock`.

Every request contains `v`, `type`, `id`, `method`, and `params`:

```json
{"v":1,"type":"request","id":1,"method":"get_state","params":{}}
```

Supported methods:

- `get_capabilities`
- `get_state`
- `get_stats`
- `start_recording` with optional `cleanup` (default `true`)
- `finish_recording`
- `cancel_recording`
- `toggle` with optional `cleanup`
- `subscribe`

`get_stats` returns persistent aggregate transcription counts and latency
statistics. It does not return transcript text or detailed history.
Additive fields include real-time factor, latency per audio second, word and
character-normalized latency, stop-to-final p50/p95 and under-500 coverage, and
per-region REST summaries. Nullable fields have no measured samples yet;
`content_samples` reports coverage for word and character normalization.

`get_capabilities` includes `streaming_stt`. Partial transcripts are not sent
over protocol v1; output remains one finalized delivery after recording stops.

Successful responses have `ok: true` and a structured `result`. Errors have
`ok: false` and `error.code` plus `error.message`.

`subscribe` keeps the connection open after its initial state snapshot. Event
frames include an increasing `seq` and the active `session_id`:

```json
{"v":1,"type":"event","seq":8,"event":"audio.level","session_id":2,"data":{"rms":0.18,"peak":0.52,"clipping":false,"window_ms":100}}
```

Events:

- `state.changed`
- `audio.level`
- `processing.stage_changed`
- `recording.limit_reached`
- `operation.error`
- `output.completed`
- `session.completed`

`session.completed` includes `phase`, `reason`, `stt_attempted`, and
`latency_ms` in addition to `ok`.

Top-level states are `idle`, `recording`, `stopping`, and `processing`.
Processing stages are `validating`, `transcribing`, `cleaning`, and
`delivering`.

Frames are limited to 64 KiB. Event history is bounded; clients must always
apply the initial subscription state snapshot and tolerate reconnects.
