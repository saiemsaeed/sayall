use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use std::io::{self, BufRead};

pub const MAX_FRAME_LEN: usize = 64 * 1024;

enum WireEnvelope {
    Response(Map<String, Value>),
    Event {
        seq: u64,
        name: String,
        data: Map<String, Value>,
    },
}

#[derive(Clone, Copy, Debug, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Idle,
    Recording,
    Stopping,
    Processing,
}

#[derive(Clone, Copy, Debug, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingStage {
    Validating,
    Transcribing,
    Cleaning,
    Delivering,
}

#[derive(Debug)]
pub struct StateSnapshot {
    pub state: State,
    pub elapsed_ms: u64,
    pub show_timer: bool,
}

#[derive(Debug)]
pub struct SubscriptionSnapshot {
    pub state: StateSnapshot,
}

#[derive(Debug)]
pub struct ProtocolEvent {
    pub kind: EventKind,
}

#[derive(Debug)]
pub enum EventKind {
    StateChanged(StateSnapshot),
    AudioLevel(AudioLevel),
    ProcessingStageChanged,
    RecordingLimitReached,
    OperationError(String),
    OutputCompleted(OutputMethod),
    SessionCompleted(bool),
    Unknown,
}

#[derive(Debug)]
pub struct AudioLevel {
    pub rms: f64,
    pub peak: f64,
    pub clipping: bool,
}

#[derive(Clone, Copy, Debug, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OutputMethod {
    Type,
    Clipboard,
    Paste,
}

#[derive(Clone, Copy, Debug, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
enum SessionPhase {
    PreStt,
    Stt,
    PostStt,
}

#[derive(Debug)]
pub enum SubscriptionMessage {
    Snapshot(SubscriptionSnapshot),
    Event(ProtocolEvent),
}

pub struct SubscriptionDecoder {
    request_id: u64,
    expected_seq: Option<u64>,
}

impl SubscriptionDecoder {
    pub fn new(request_id: u64) -> Self {
        Self {
            request_id,
            expected_seq: None,
        }
    }

    pub fn decode(&mut self, frame: &[u8]) -> io::Result<SubscriptionMessage> {
        let parsed: UniqueValue = serde_json::from_slice(frame)
            .map_err(|error| invalid_data(format!("malformed protocol envelope: {error}")))?;
        let UniqueValue(Value::Object(mut envelope)) = parsed else {
            return Err(invalid_data("protocol envelope must be an object"));
        };
        validate_version(take_required(&mut envelope, "v", "protocol envelope")?)?;
        let envelope_type: String = take_required(&mut envelope, "type", "protocol envelope")?;
        let envelope = match envelope_type.as_str() {
            "response" => WireEnvelope::Response(envelope),
            "event" => {
                let seq = take_required(&mut envelope, "seq", "event")?;
                let name = take_required(&mut envelope, "event", "event")?;
                take_required::<u64>(&mut envelope, "session_id", "event")?;
                let data = take_required(&mut envelope, "data", "event")?;
                WireEnvelope::Event { seq, name, data }
            }
            other => {
                return Err(invalid_data(format!(
                    "unknown protocol envelope type {other}"
                )));
            }
        };

        match (self.expected_seq, envelope) {
            (None, WireEnvelope::Response(response)) => self.install_snapshot(response),
            (None, WireEnvelope::Event { .. }) => {
                Err(invalid_data("event arrived before subscription response"))
            }
            (Some(_), WireEnvelope::Response(response)) => {
                self.validate_terminal_response(response)
            }
            (Some(expected), WireEnvelope::Event { seq, name, data }) => {
                self.decode_event(expected, seq, name, data)
            }
        }
    }

    fn install_snapshot(
        &mut self,
        mut response: Map<String, Value>,
    ) -> io::Result<SubscriptionMessage> {
        let id = take_required(&mut response, "id", "response")?;
        self.validate_response_id(id)?;
        let ok: bool = take_required(&mut response, "ok", "response")?;
        let result = decode_optional_subscribe_result(&mut response)?;
        let error = decode_optional_error(&mut response)?;
        if !ok {
            validate_error_response(result, error)?;
            return Err(invalid_data("subscription request failed"));
        }
        if error.is_some() {
            return Err(invalid_data("successful response contained error"));
        }
        let (state, next_seq) =
            result.ok_or_else(|| invalid_data("successful response missing result"))?;
        self.expected_seq = Some(next_seq);
        Ok(SubscriptionMessage::Snapshot(SubscriptionSnapshot {
            state,
        }))
    }

    fn validate_terminal_response(
        &self,
        mut response: Map<String, Value>,
    ) -> io::Result<SubscriptionMessage> {
        let id = take_required(&mut response, "id", "response")?;
        self.validate_response_id(id)?;
        let ok: bool = take_required(&mut response, "ok", "response")?;
        let result = decode_optional_subscribe_result(&mut response)?;
        let error = decode_optional_error(&mut response)?;
        if ok {
            if result.is_none() || error.is_some() {
                return Err(invalid_data("malformed successful response"));
            }
            return Err(invalid_data("unexpected response on event stream"));
        }
        let code = validate_error_response(result, error)?;
        if code == "event_gap" {
            return Err(invalid_data("server reported event gap"));
        }
        Err(invalid_data("unexpected error response on event stream"))
    }

    fn validate_response_id(&self, id: u64) -> io::Result<()> {
        if id != self.request_id {
            return Err(invalid_data("response id did not match subscription"));
        }
        Ok(())
    }

    fn decode_event(
        &mut self,
        expected: u64,
        seq: u64,
        event_name: String,
        data: Map<String, Value>,
    ) -> io::Result<SubscriptionMessage> {
        if seq != expected {
            return Err(invalid_data(format!(
                "non-consecutive event sequence: expected {expected}, got {seq}"
            )));
        }

        let kind = decode_event_data(event_name, data)?;
        self.expected_seq = Some(
            expected
                .checked_add(1)
                .ok_or_else(|| invalid_data("event sequence overflow"))?,
        );
        Ok(SubscriptionMessage::Event(ProtocolEvent { kind }))
    }
}

fn validate_version(version: u16) -> io::Result<()> {
    if version != 1 {
        return Err(invalid_data(format!(
            "unsupported protocol version {version}"
        )));
    }
    Ok(())
}

fn validate_error_response(
    result: Option<(StateSnapshot, u64)>,
    error: Option<(String, String)>,
) -> io::Result<String> {
    if result.is_some() || error.is_none() {
        return Err(invalid_data("malformed error response"));
    }
    let (code, _) = error.expect("validated error");
    Ok(code)
}

fn decode_optional_subscribe_result(
    response: &mut Map<String, Value>,
) -> io::Result<Option<(StateSnapshot, u64)>> {
    let Some(mut result) = take_optional_object(response, "result", "response")? else {
        return Ok(None);
    };
    let state = decode_state_snapshot(take_required(&mut result, "state", "subscribe result")?)?;
    let next_seq = take_required(&mut result, "next_seq", "subscribe result")?;
    Ok(Some((state, next_seq)))
}

fn decode_optional_error(
    response: &mut Map<String, Value>,
) -> io::Result<Option<(String, String)>> {
    let Some(mut error) = take_optional_object(response, "error", "response")? else {
        return Ok(None);
    };
    let code = take_required(&mut error, "code", "error")?;
    let message = take_required(&mut error, "message", "error")?;
    Ok(Some((code, message)))
}

fn decode_event_data(event: String, mut data: Map<String, Value>) -> io::Result<EventKind> {
    match event.as_str() {
        "state.changed" => decode_state_snapshot(data).map(EventKind::StateChanged),
        "audio.level" => {
            let level = AudioLevel {
                rms: take_required(&mut data, "rms", &event)?,
                peak: take_required(&mut data, "peak", &event)?,
                clipping: take_required(&mut data, "clipping", &event)?,
            };
            take_required::<u64>(&mut data, "window_ms", &event)?;
            if !(0.0..=1.0).contains(&level.rms) || !(0.0..=1.0).contains(&level.peak) {
                return Err(invalid_data("audio.level values must be in [0,1]"));
            }
            Ok(EventKind::AudioLevel(level))
        }
        "processing.stage_changed" => {
            take_required::<Option<ProcessingStage>>(&mut data, "stage", &event)?;
            Ok(EventKind::ProcessingStageChanged)
        }
        "recording.limit_reached" => Ok(EventKind::RecordingLimitReached),
        "operation.error" => {
            take_required::<String>(&mut data, "code", &event)?;
            take_required(&mut data, "message", &event).map(EventKind::OperationError)
        }
        "output.completed" => {
            take_required(&mut data, "method", &event).map(EventKind::OutputCompleted)
        }
        "session.completed" => {
            let ok = take_required(&mut data, "ok", &event)?;
            take_required::<SessionPhase>(&mut data, "phase", &event)?;
            take_required::<Option<String>>(&mut data, "reason", &event)?;
            take_required::<bool>(&mut data, "stt_attempted", &event)?;
            take_required::<u64>(&mut data, "latency_ms", &event)?;
            Ok(EventKind::SessionCompleted(ok))
        }
        _ => Ok(EventKind::Unknown),
    }
}

fn decode_state_snapshot(mut data: Map<String, Value>) -> io::Result<StateSnapshot> {
    let snapshot = StateSnapshot {
        state: take_required(&mut data, "state", "state snapshot")?,
        elapsed_ms: take_required(&mut data, "elapsed_ms", "state snapshot")?,
        show_timer: take_optional(&mut data, "show_timer", "state snapshot")?.unwrap_or(true),
    };
    take_required::<Option<ProcessingStage>>(&mut data, "stage", "state snapshot")?;
    take_required::<u64>(&mut data, "session_id", "state snapshot")?;
    take_required::<bool>(&mut data, "cleanup", "state snapshot")?;
    Ok(snapshot)
}

fn take_required<T: DeserializeOwned>(
    object: &mut Map<String, Value>,
    field: &str,
    context: &str,
) -> io::Result<T> {
    let value = object
        .remove(field)
        .ok_or_else(|| invalid_data(format!("{context} missing required field {field}")))?;
    serde_json::from_value(value)
        .map_err(|error| invalid_data(format!("invalid {context} field {field}: {error}")))
}

fn take_optional<T: DeserializeOwned>(
    object: &mut Map<String, Value>,
    field: &str,
    context: &str,
) -> io::Result<Option<T>> {
    object
        .remove(field)
        .map(|value| {
            serde_json::from_value(value)
                .map_err(|error| invalid_data(format!("invalid {context} field {field}: {error}")))
        })
        .transpose()
}

fn take_optional_object(
    object: &mut Map<String, Value>,
    field: &str,
    context: &str,
) -> io::Result<Option<Map<String, Value>>> {
    let Some(value) = object.remove(field) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    serde_json::from_value(value)
        .map(Some)
        .map_err(|error| invalid_data(format!("invalid {context} field {field}: {error}")))
}

/// A JSON value whose object keys are unique at every nesting level.
/// Serde's derived structs reject duplicate known fields; validating uniqueness
/// before mapping preserves that strict wire behavior without retaining fields.
struct UniqueValue(Value);

impl<'de> serde::Deserialize<'de> for UniqueValue {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(UniqueValueVisitor)
    }
}

struct UniqueValueVisitor;

impl<'de> serde::de::Visitor<'de> for UniqueValueVisitor {
    type Value = UniqueValue;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("a JSON value with unique object keys")
    }

    fn visit_bool<E>(self, value: bool) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::Bool(value)))
    }

    fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::Number(value.into())))
    }

    fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::Number(value.into())))
    }

    fn visit_f64<E>(self, value: f64) -> Result<Self::Value, E>
    where
        E: serde::de::Error,
    {
        serde_json::Number::from_f64(value)
            .map(Value::Number)
            .map(UniqueValue)
            .ok_or_else(|| E::custom("non-finite JSON number"))
    }

    fn visit_str<E>(self, value: &str) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::String(value.to_owned())))
    }

    fn visit_string<E>(self, value: String) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::String(value)))
    }

    fn visit_none<E>(self) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::Null))
    }

    fn visit_unit<E>(self) -> Result<Self::Value, E> {
        Ok(UniqueValue(Value::Null))
    }

    fn visit_seq<A>(self, mut sequence: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::SeqAccess<'de>,
    {
        let mut values = Vec::new();
        while let Some(UniqueValue(value)) = sequence.next_element()? {
            values.push(value);
        }
        Ok(UniqueValue(Value::Array(values)))
    }

    fn visit_map<A>(self, mut entries: A) -> Result<Self::Value, A::Error>
    where
        A: serde::de::MapAccess<'de>,
    {
        let mut object = Map::new();
        while let Some(key) = entries.next_key::<String>()? {
            if object.contains_key(&key) {
                return Err(serde::de::Error::custom(format!(
                    "duplicate object field {key}"
                )));
            }
            let UniqueValue(value) = entries.next_value()?;
            object.insert(key, value);
        }
        Ok(UniqueValue(Value::Object(object)))
    }
}

fn invalid_data(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.into())
}

/// Reads one frame into fixed caller-owned storage. The terminating newline is
/// counted toward the protocol's 64-KiB limit and omitted from the returned slice.
pub fn read_frame<'a, R: BufRead>(
    reader: &mut R,
    storage: &'a mut [u8; MAX_FRAME_LEN],
) -> io::Result<&'a [u8]> {
    let mut used = 0;
    loop {
        let available = reader.fill_buf()?;
        if available.is_empty() {
            let message = if used == 0 {
                "connection closed before next frame"
            } else {
                "unterminated protocol frame"
            };
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, message));
        }

        if let Some(newline) = available.iter().position(|byte| *byte == b'\n') {
            let count = newline + 1;
            if used + count > MAX_FRAME_LEN {
                return Err(invalid_data("protocol frame exceeds 64 KiB"));
            }
            storage[used..used + count].copy_from_slice(&available[..count]);
            reader.consume(count);
            return Ok(&storage[..used + count - 1]);
        }

        if available.len() >= MAX_FRAME_LEN - used {
            return Err(invalid_data(
                "protocol frame exceeds 64 KiB or is unterminated",
            ));
        }
        let count = available.len();
        storage[used..used + count].copy_from_slice(available);
        used += count;
        reader.consume(count);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufReader, Cursor};

    const SUBSCRIBE: &str =
        include_str!("../../../tests/protocol-v1/response-subscribe-additive.json");
    const KNOWN_EVENTS: &str = include_str!("../../../tests/protocol-v1/events-known.ndjson");
    const ERROR_RESPONSE: &str =
        include_str!("../../../tests/protocol-v1/response-error-additive.json");
    const UNKNOWN_EVENT: &str =
        include_str!("../../../tests/protocol-v1/event-unknown-additive.json");

    fn subscribed_decoder() -> SubscriptionDecoder {
        let mut decoder = SubscriptionDecoder::new(3);
        let message = decoder.decode(SUBSCRIBE.as_bytes()).unwrap();
        let SubscriptionMessage::Snapshot(snapshot) = message else {
            panic!("expected snapshot")
        };
        assert_eq!(snapshot.state.state, State::Recording);
        assert_eq!(snapshot.state.elapsed_ms, 1250);
        assert!(snapshot.state.show_timer);
        decoder
    }

    #[test]
    fn shared_snapshot_and_known_event_fixtures_map_to_hud_events() {
        let mut decoder = subscribed_decoder();
        let mut kinds = Vec::new();
        for line in KNOWN_EVENTS.lines() {
            let SubscriptionMessage::Event(event) = decoder.decode(line.as_bytes()).unwrap() else {
                panic!("expected event")
            };
            kinds.push(match event.kind {
                EventKind::StateChanged(_) => "state",
                EventKind::AudioLevel(_) => "audio",
                EventKind::ProcessingStageChanged => "stage",
                EventKind::RecordingLimitReached => "limit",
                EventKind::OperationError(message) if message == "Transcription failed" => "error",
                EventKind::OutputCompleted(OutputMethod::Paste) => "output",
                EventKind::SessionCompleted(true) => "completed",
                other => panic!("unexpected mapped event: {other:?}"),
            });
        }
        assert_eq!(
            kinds,
            [
                "state",
                "audio",
                "stage",
                "limit",
                "error",
                "output",
                "completed"
            ]
        );
    }

    #[test]
    fn additive_unknown_fields_and_events_are_discarded_after_mapping() {
        let mut decoder = subscribed_decoder();
        for line in KNOWN_EVENTS.lines() {
            decoder.decode(line.as_bytes()).unwrap();
        }
        let SubscriptionMessage::Event(event) = decoder.decode(UNKNOWN_EVENT.as_bytes()).unwrap()
        else {
            panic!("expected event")
        };
        assert!(matches!(event.kind, EventKind::Unknown));

        let next = br#"{"v":1,"type":"event","seq":27,"event":"recording.limit_reached","session_id":8,"data":{}}"#;
        decoder.decode(next).unwrap();
    }

    #[test]
    fn event_gap_and_local_sequence_gap_end_the_subscription() {
        let mut decoder = subscribed_decoder();
        let gap = br#"{"v":1,"type":"response","id":3,"ok":false,"error":{"code":"event_gap","message":"resubscribe","future":true}}"#;
        assert!(decoder.decode(gap).is_err());

        let mut decoder = subscribed_decoder();
        let local_gap = br#"{"v":1,"type":"event","seq":20,"event":"recording.limit_reached","session_id":8,"data":{}}"#;
        assert!(decoder.decode(local_gap).is_err());
    }

    #[test]
    fn shared_additive_error_fixture_is_validated_and_terminal() {
        let mut decoder = SubscriptionDecoder::new(4);
        assert!(decoder.decode(ERROR_RESPONSE.as_bytes()).is_err());
    }

    #[test]
    fn malformed_required_fields_and_known_payloads_are_rejected() {
        let mut decoder = SubscriptionDecoder::new(3);
        assert!(decoder.decode(b"{").is_err());

        let wrong_id = SUBSCRIBE.replacen("\"id\":3", "\"id\":4", 1);
        assert!(decoder.decode(wrong_id.as_bytes()).is_err());

        let mut decoder = SubscriptionDecoder::new(3);
        let missing_result = br#"{"v":1,"type":"response","id":3,"ok":true}"#;
        assert!(decoder.decode(missing_result).is_err());

        let mut decoder = SubscriptionDecoder::new(3);
        let missing_next_seq = br#"{"v":1,"type":"response","id":3,"ok":true,"result":{"state":{"state":"idle","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true}}}"#;
        assert!(decoder.decode(missing_next_seq).is_err());

        let mut decoder = SubscriptionDecoder::new(3);
        let wrong_type = br#"{"v":1,"type":"request","id":3,"ok":true,"result":{}}"#;
        assert!(decoder.decode(wrong_type).is_err());

        let mut decoder = subscribed_decoder();
        let missing_stage = br#"{"v":1,"type":"event","seq":19,"event":"state.changed","session_id":8,"data":{"state":"recording","session_id":8,"elapsed_ms":1,"cleanup":true}}"#;
        assert!(decoder.decode(missing_stage).is_err());

        let mut decoder = subscribed_decoder();
        let invalid_level = br#"{"v":1,"type":"event","seq":19,"event":"audio.level","session_id":8,"data":{"rms":1.1,"peak":0.2,"clipping":false,"window_ms":100}}"#;
        assert!(decoder.decode(invalid_level).is_err());
    }

    #[test]
    fn required_wire_only_fields_are_validated_before_mapping() {
        for missing in ["stage", "session_id", "cleanup"] {
            let snapshot = r#"{"v":1,"type":"response","id":3,"ok":true,"result":{"state":{"state":"idle","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true},"next_seq":19}}"#;
            let mut value: Value = serde_json::from_str(snapshot).unwrap();
            value["result"]["state"]
                .as_object_mut()
                .unwrap()
                .remove(missing);
            assert!(
                SubscriptionDecoder::new(3)
                    .decode(value.to_string().as_bytes())
                    .is_err(),
                "missing snapshot field {missing}"
            );
        }

        for (event, missing) in [
            (
                r#"{"v":1,"type":"event","seq":19,"event":"audio.level","session_id":8,"data":{"rms":0.1,"peak":0.2,"clipping":false,"window_ms":100}}"#,
                "window_ms",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"operation.error","session_id":8,"data":{"code":"failed","message":"failed"}}"#,
                "code",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"processing.stage_changed","session_id":8,"data":{"stage":"validating"}}"#,
                "stage",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"session.completed","session_id":8,"data":{"ok":true,"phase":"post_stt","reason":null,"stt_attempted":true,"latency_ms":1}}"#,
                "phase",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"session.completed","session_id":8,"data":{"ok":true,"phase":"post_stt","reason":null,"stt_attempted":true,"latency_ms":1}}"#,
                "reason",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"session.completed","session_id":8,"data":{"ok":true,"phase":"post_stt","reason":null,"stt_attempted":true,"latency_ms":1}}"#,
                "stt_attempted",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"session.completed","session_id":8,"data":{"ok":true,"phase":"post_stt","reason":null,"stt_attempted":true,"latency_ms":1}}"#,
                "latency_ms",
            ),
        ] {
            let mut value: Value = serde_json::from_str(event).unwrap();
            value["data"].as_object_mut().unwrap().remove(missing);
            let mut decoder = subscribed_decoder();
            assert!(
                decoder.decode(value.to_string().as_bytes()).is_err(),
                "missing event field {missing}"
            );
        }

        let missing_session_id =
            br#"{"v":1,"type":"event","seq":19,"event":"future.event","data":{}}"#;
        let mut decoder = subscribed_decoder();
        assert!(decoder.decode(missing_session_id).is_err());

        let missing_error_message =
            br#"{"v":1,"type":"response","id":4,"ok":false,"error":{"code":"failed"}}"#;
        assert!(
            SubscriptionDecoder::new(4)
                .decode(missing_error_message)
                .is_err()
        );
    }

    #[test]
    fn duplicate_fields_and_unknown_closed_enum_values_are_rejected() {
        let duplicate = br#"{"v":1,"type":"response","id":3,"ok":true,"result":{"state":{"state":"idle","stage":null,"session_id":1,"elapsed_ms":0,"cleanup":true},"next_seq":19,"next_seq":20}}"#;
        assert!(SubscriptionDecoder::new(3).decode(duplicate).is_err());

        for (event, field) in [
            (
                r#"{"v":1,"type":"event","seq":19,"event":"state.changed","session_id":8,"data":{"state":"future","stage":null,"session_id":8,"elapsed_ms":0,"cleanup":true}}"#,
                "state",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"processing.stage_changed","session_id":8,"data":{"stage":"future"}}"#,
                "processing stage",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"output.completed","session_id":8,"data":{"method":"future"}}"#,
                "output method",
            ),
            (
                r#"{"v":1,"type":"event","seq":19,"event":"session.completed","session_id":8,"data":{"ok":true,"phase":"future","reason":null,"stt_attempted":true,"latency_ms":1}}"#,
                "session phase",
            ),
        ] {
            let mut decoder = subscribed_decoder();
            assert!(decoder.decode(event.as_bytes()).is_err(), "unknown {field}");
        }
    }

    #[test]
    fn unsupported_versions_are_rejected_for_response_and_event() {
        let mut decoder = SubscriptionDecoder::new(3);
        let unsupported = SUBSCRIBE.replacen("\"v\":1", "\"v\":2", 1);
        assert!(decoder.decode(unsupported.as_bytes()).is_err());

        let mut decoder = subscribed_decoder();
        let event = br#"{"v":2,"type":"event","seq":19,"event":"recording.limit_reached","session_id":8,"data":{}}"#;
        assert!(decoder.decode(event).is_err());
    }

    #[test]
    fn bounded_reader_accepts_limit_and_rejects_oversized_or_unterminated_frames() {
        let mut exact = vec![b' '; MAX_FRAME_LEN];
        exact[MAX_FRAME_LEN - 1] = b'\n';
        let mut reader = BufReader::new(Cursor::new(exact));
        let mut storage = [0; MAX_FRAME_LEN];
        assert_eq!(
            read_frame(&mut reader, &mut storage).unwrap().len(),
            MAX_FRAME_LEN - 1
        );

        let mut oversized = vec![b' '; MAX_FRAME_LEN + 1];
        oversized[MAX_FRAME_LEN] = b'\n';
        let mut reader = BufReader::new(Cursor::new(oversized));
        assert!(read_frame(&mut reader, &mut storage).is_err());

        let mut reader = BufReader::new(Cursor::new(b"{}"));
        assert_eq!(
            read_frame(&mut reader, &mut storage).unwrap_err().kind(),
            io::ErrorKind::UnexpectedEof
        );
    }
}
