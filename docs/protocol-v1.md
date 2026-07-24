# SayAll Control Protocol v1

SayAll v1 is bounded newline-delimited JSON (NDJSON) over the private Unix
domain socket. One connection carries one request. The exception is `subscribe`:
after its response, the connection stays open for event frames.

The Zig daemon and CLI discover the Linux endpoint in this order:

1. `SAYALL_SOCKET`, when it is an absolute, normalized, filesystem Unix-socket
   path suitable for `sun_path`. This override is intended for development and
   tests.
2. `$XDG_RUNTIME_DIR/sayall.sock`.
3. `/tmp/sayall-<effective-user-id>.sock` when `XDG_RUNTIME_DIR` is absent.

Private runtime/override parents are required to have no group or other mode
bits. The `/tmp` fallback instead requires the standard writable sticky
directory. The daemon creates the socket with mode `0600`; clients reject
non-sockets and sockets with group or other permissions. The scratch recording
directory is resolved separately (`XDG_RUNTIME_DIR`, then `/tmp`), so changing
`SAYALL_SOCKET` does not relocate recordings.

The Linux Rust HUD continues to mirror the two production defaults; sharing
the override/discovery implementation with it is tracked separately. No macOS
or Windows production endpoint default is selected by protocol v1.

Legacy plaintext commands remain valid on the same socket:

- `toggle`, `toggle raw`, `stop`, and `status`
- their one-line replies remain `recording`, `processing`, `stopped`, `idle`,
  `stopping`, or the existing `busy:`/`error:` text

## Framing and compatibility

Every JSON or plaintext frame ends in `\n`. The encoded frame, including that
newline, MUST be at most 65,536 bytes (64 KiB). A JSON frame has no embedded raw
newline. An overlong request receives an error with `id: 0` when possible and
the connection closes:

```json
{"v":1,"type":"response","id":0,"ok":false,"error":{"code":"frame_too_large","message":"Frame exceeds 65536 bytes including newline"}}
```

Readers MUST ignore unknown object fields and unknown event names. New optional
fields, methods, error codes, enum values where explicitly documented as open,
and event names are additive v1 changes. Readers should treat an unknown event
as consuming its `seq` and otherwise ignore it.

Removing or renaming a field/method/event, changing a field's meaning or JSON
type, making an optional field required, changing the framing/transport, or
changing subscription ordering requires protocol v2. Adding values to the
closed state, processing-stage, session-phase, or output-method lists also
requires v2. V1 does not provide
authentication, durable replay, acknowledgements, or resume cursors.

Shared compatibility examples live in [`tests/protocol-v1/`](../tests/protocol-v1/).

## Common envelopes

All requests contain `v`, `type`, `id`, `method`, and `params`. `id` is an
unsigned 64-bit client-selected correlation value.

```json
{"v":1,"type":"request","id":1,"method":"get_state","params":{}}
```

A successful response has a structured `result`:

```json
{"v":1,"type":"response","id":1,"ok":true,"result":{}}
```

An error has an open string `code` and human-readable `message`:

```json
{"v":1,"type":"response","id":1,"ok":false,"error":{"code":"unknown_method","message":"Unknown method"}}
```

Clients must branch on `code`, not `message`. Current method errors include
`invalid_request`, `unknown_method`, `invalid_state`, `method_disabled`, and
`metrics_error`; framing/subscription errors include `frame_too_large` and
`event_gap`. Unsupported `v`, the wrong envelope `type`, malformed JSON, and
missing/wrongly typed required fields produce `invalid_request` with `id: 0`.

## Shared result schemas

A state snapshot is:

```json
{"state":"recording","stage":null,"session_id":2,"elapsed_ms":842,"cleanup":true,"show_timer":true}
```

- `state`: `idle`, `recording`, `stopping`, or `processing`
- `stage`: `null`, `validating`, `transcribing`, `cleaning`, or `delivering`
- `session_id`: unsigned 64-bit ID; increments when recording starts
- `elapsed_ms`: non-negative recording elapsed time, otherwise `0`
- `cleanup`: whether LLM cleanup is requested for this session
- `show_timer`: whether the HUD displays elapsed recording time; additive and
  optional for older v1 servers, with clients defaulting it to `true`

## Methods

### `get_capabilities`

Request and complete result schema:

```json
{"v":1,"type":"request","id":1,"method":"get_capabilities","params":{}}
{"v":1,"type":"response","id":1,"ok":true,"result":{"protocol_version":1,"platform":"linux","live_levels":true,"text_injection":true,"clipboard_fallback":true,"stats":true,"streaming_stt":true}}
```

All result fields are required booleans except the numeric `protocol_version`
and string `platform`. `stats` reflects whether `get_stats` is enabled;
`streaming_stt` reflects the active configuration. Partial transcripts are not
sent in v1; delivery still occurs once after recording stops.

### `get_state`

```json
{"v":1,"type":"request","id":2,"method":"get_state","params":{}}
{"v":1,"type":"response","id":2,"ok":true,"result":{"state":"idle","stage":null,"session_id":2,"elapsed_ms":0,"cleanup":true}}
```

### Recording controls

`start_recording` and `toggle` accept optional boolean `cleanup`, defaulting to
`true`. `finish_recording` and `cancel_recording` take empty params. Every
successful control response returns the complete state snapshot after the
operation was accepted.

```json
{"v":1,"type":"request","id":3,"method":"start_recording","params":{"cleanup":false}}
{"v":1,"type":"request","id":4,"method":"finish_recording","params":{}}
{"v":1,"type":"request","id":5,"method":"cancel_recording","params":{}}
{"v":1,"type":"request","id":6,"method":"toggle","params":{"cleanup":true}}
{"v":1,"type":"response","id":3,"ok":true,"result":{"state":"recording","stage":null,"session_id":3,"elapsed_ms":0,"cleanup":false}}
```

### `get_stats`

```json
{"v":1,"type":"request","id":7,"method":"get_stats","params":{}}
{"v":1,"type":"response","id":7,"ok":true,"result":{"attempts":10,"successful":8,"no_speech":1,"failed":1,"pre_stt_failed":0,"success_rate":0.8,"average_latency_ms":420,"minimum_latency_ms":210,"maximum_latency_ms":800,"recent_p50_ms":390,"recent_p95_ms":760,"normalized_samples":8,"realtime_factor":0.12,"average_latency_ms_per_audio_second":120.0,"content_samples":8,"average_latency_ms_per_word":31.5,"average_latency_ms_per_character":6.2,"stop_to_final_samples":5,"average_stop_to_final_ms":340,"stop_to_final_p50_ms":320,"stop_to_final_p95_ms":490,"stop_to_final_under_500":5,"stop_to_final_under_500_percentage":100.0,"global_rest":{"attempts":5,"samples":4,"failed":1,"average_latency_ms":450,"p50_latency_ms":430,"p95_latency_ms":700,"realtime_factor":0.13,"average_connection_ms":null},"eu_rest":{"attempts":0,"samples":0,"failed":0,"average_latency_ms":null,"p50_latency_ms":null,"p95_latency_ms":null,"realtime_factor":null,"average_connection_ms":null},"au_rest":{"attempts":0,"samples":0,"failed":0,"average_latency_ms":null,"p50_latency_ms":null,"p95_latency_ms":null,"realtime_factor":null,"average_connection_ms":null},"global_stream":{"attempts":5,"samples":4,"failed":1,"average_latency_ms":390,"p50_latency_ms":370,"p95_latency_ms":600,"realtime_factor":0.11,"average_connection_ms":95},"eu_stream":{"attempts":0,"samples":0,"failed":0,"average_latency_ms":null,"p50_latency_ms":null,"p95_latency_ms":null,"realtime_factor":null,"average_connection_ms":null},"au_stream":{"attempts":0,"samples":0,"failed":0,"average_latency_ms":null,"p50_latency_ms":null,"p95_latency_ms":null,"realtime_factor":null,"average_connection_ms":null},"history_entries":10,"history_limit":1000}}
```

Counts and millisecond values are non-negative integers; rates and normalized
values are numbers. Nullable measurements are `null` when no qualifying sample
exists. Each regional transport object has exactly the fields shown above.
`content_samples` reports word/character-normalized coverage. No transcript text
or detailed history is returned. Disabled statistics return `method_disabled`.

### `subscribe`

```json
{"v":1,"type":"request","id":8,"method":"subscribe","params":{}}
{"v":1,"type":"response","id":8,"ok":true,"result":{"state":{"state":"recording","stage":null,"session_id":3,"elapsed_ms":120,"cleanup":true},"next_seq":41}}
```

The response establishes a coherent barrier. Its snapshot is current at that
barrier, and `next_seq` is the sequence number of the first event strictly after
the snapshot. The server sends the response before any post-barrier event. A
client MUST install the snapshot first, then require event sequence numbers to
be exactly `next_seq`, `next_seq + 1`, and so on.

Sequence numbers are daemon-lifetime, strictly consecutive unsigned 64-bit
values. Event storage is a bounded in-memory ring, not replay durability. If a
subscriber falls behind the retained ring, the server does not skip forward.
It sends a terminal response using the subscription request ID, then closes:

```json
{"v":1,"type":"response","id":8,"ok":false,"error":{"code":"event_gap","message":"Event history overflowed; resubscribe for a fresh snapshot"}}
```

On `event_gap`, any locally detected non-consecutive `seq`, EOF, socket error,
or daemon restart, discard assumptions based on the old stream, reconnect with
a new `subscribe`, install its fresh snapshot, and restart from its `next_seq`.

## Events

Every event uses this envelope; `data` is defined per event below:

```json
{"v":1,"type":"event","seq":41,"event":"audio.level","session_id":3,"data":{"rms":0.18,"peak":0.52,"clipping":false,"window_ms":100}}
```

Events are transient observations. They are never replayed across daemon
restarts and may be lost when a client disconnects. The fresh subscription
snapshot is authoritative for current state. Completion, error, limit, output,
stage-transition, and audio-level events that happened while disconnected are
not reconstructed.

### `state.changed`

`data` is the complete state snapshot schema.

```json
{"v":1,"type":"event","seq":42,"event":"state.changed","session_id":3,"data":{"state":"processing","stage":"validating","session_id":3,"elapsed_ms":0,"cleanup":true}}
```

### `audio.level`

```json
{"v":1,"type":"event","seq":43,"event":"audio.level","session_id":3,"data":{"rms":0.18,"peak":0.52,"clipping":false,"window_ms":100}}
```

`rms` and `peak` are normalized numbers in `[0,1]`; `clipping` is boolean;
`window_ms` is a non-negative integer.

### `processing.stage_changed`

```json
{"v":1,"type":"event","seq":44,"event":"processing.stage_changed","session_id":3,"data":{"stage":"transcribing"}}
```

`stage` is nullable and otherwise uses the processing-stage values above.

### `recording.limit_reached`

```json
{"v":1,"type":"event","seq":45,"event":"recording.limit_reached","session_id":3,"data":{}}
```

### `operation.error`

```json
{"v":1,"type":"event","seq":46,"event":"operation.error","session_id":3,"data":{"code":"transcription_failed","message":"Transcription failed"}}
```

Both fields are strings. `code` is open for additive values and is stable for
client branching; `message` is display text.

### `output.completed`

```json
{"v":1,"type":"event","seq":47,"event":"output.completed","session_id":3,"data":{"method":"type"}}
```

`method` is currently `type`, `clipboard`, or `paste`.

### `session.completed`

```json
{"v":1,"type":"event","seq":48,"event":"session.completed","session_id":3,"data":{"ok":true,"phase":"post_stt","reason":null,"stt_attempted":true,"latency_ms":340}}
```

- `ok`: whether the session completed and delivered output
- `phase`: `pre_stt`, `stt`, or `post_stt`
- `reason`: nullable open string code; non-null on unsuccessful completion
- `stt_attempted`: whether speech-to-text was attempted
- `latency_ms`: non-negative STT finalization/request latency; `0` when absent

Cancellation uses `ok:false`, `phase:"pre_stt"`, `reason:"cancelled"`,
`stt_attempted:false`, and `latency_ms:0`.
