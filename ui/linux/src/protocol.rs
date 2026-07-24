use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};
use std::collections::HashMap;
use std::io::{self, BufRead};

pub const MAX_FRAME_LEN: usize = 64 * 1024;

type ExtraFields = HashMap<String, Value>;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum WireEnvelope {
    #[serde(rename = "response")]
    Response(ResponseEnvelope),
    #[serde(rename = "event")]
    Event(EventEnvelope),
}

#[derive(Debug, Deserialize)]
struct ResponseEnvelope {
    v: u16,
    id: u64,
    ok: bool,
    #[serde(default)]
    result: Option<SubscribeResult>,
    #[serde(default)]
    error: Option<ErrorEnvelope>,
    #[serde(flatten)]
    extra: ExtraFields,
}

#[derive(Debug, Deserialize)]
struct SubscribeResult {
    state: StateSnapshot,
    next_seq: u64,
    #[serde(flatten)]
    extra: ExtraFields,
}

#[derive(Debug, Deserialize)]
pub struct ErrorEnvelope {
    #[allow(dead_code)]
    pub code: String,
    pub message: String,
    #[serde(flatten)]
    #[allow(dead_code)]
    pub extra: ExtraFields,
}

#[derive(Debug, Deserialize)]
struct EventEnvelope {
    v: u16,
    seq: u64,
    event: String,
    session_id: u64,
    data: Map<String, Value>,
    #[serde(flatten)]
    extra: ExtraFields,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum State {
    Idle,
    Recording,
    Stopping,
    Processing,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProcessingStage {
    Validating,
    Transcribing,
    Cleaning,
    Delivering,
}

/// A nullable field that remains required in its containing JSON object.
#[derive(Debug, Deserialize)]
pub struct Nullable<T>(pub Option<T>);

#[derive(Debug, Deserialize)]
pub struct StateSnapshot {
    pub state: State,
    #[allow(dead_code)]
    pub stage: Nullable<ProcessingStage>,
    #[allow(dead_code)]
    pub session_id: u64,
    pub elapsed_ms: u64,
    #[allow(dead_code)]
    pub cleanup: bool,
    #[serde(default = "default_show_timer")]
    pub show_timer: bool,
    #[serde(flatten)]
    #[allow(dead_code)]
    pub extra: ExtraFields,
}

fn default_show_timer() -> bool {
    true
}

#[derive(Debug)]
pub struct SubscriptionSnapshot {
    pub state: StateSnapshot,
    #[allow(dead_code)]
    pub next_seq: u64,
    #[allow(dead_code)]
    response_extra: ExtraFields,
    #[allow(dead_code)]
    result_extra: ExtraFields,
}

#[derive(Debug)]
pub struct ProtocolEvent {
    #[allow(dead_code)]
    pub seq: u64,
    #[allow(dead_code)]
    pub session_id: u64,
    pub kind: EventKind,
    #[allow(dead_code)]
    pub extra: ExtraFields,
}

#[derive(Debug)]
pub enum EventKind {
    StateChanged(StateSnapshot),
    AudioLevel(AudioLevel),
    #[allow(dead_code)]
    ProcessingStageChanged(ProcessingStageChanged),
    #[allow(dead_code)]
    RecordingLimitReached(RecordingLimitReached),
    OperationError(ErrorEnvelope),
    #[allow(dead_code)]
    OutputCompleted(OutputCompleted),
    SessionCompleted(SessionCompleted),
    Unknown {
        #[allow(dead_code)]
        name: String,
        #[allow(dead_code)]
        data: Map<String, Value>,
    },
}

#[derive(Debug, Deserialize)]
pub struct AudioLevel {
    pub rms: f64,
    pub peak: f64,
    pub clipping: bool,
    #[allow(dead_code)]
    pub window_ms: u64,
    #[serde(flatten)]
    #[allow(dead_code)]
    pub extra: ExtraFields,
}

#[derive(Debug, Deserialize)]
pub struct ProcessingStageChanged {
    #[allow(dead_code)]
    pub stage: Nullable<ProcessingStage>,
    #[serde(flatten)]
    #[allow(dead_code)]
    pub extra: ExtraFields,
}

#[derive(Debug, Deserialize)]
pub struct RecordingLimitReached {
    #[serde(flatten)]
    #[allow(dead_code)]
    pub extra: ExtraFields,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OutputMethod {
    Type,
    Clipboard,
    Paste,
}

#[derive(Debug, Deserialize)]
pub struct OutputCompleted {
    pub method: OutputMethod,
    #[serde(flatten)]
    #[allow(dead_code)]
    extra: ExtraFields,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SessionPhase {
    PreStt,
    Stt,
    PostStt,
}

#[derive(Debug, Deserialize)]
pub struct SessionCompleted {
    pub ok: bool,
    #[allow(dead_code)]
    phase: SessionPhase,
    #[allow(dead_code)]
    reason: Nullable<String>,
    #[allow(dead_code)]
    stt_attempted: bool,
    #[allow(dead_code)]
    latency_ms: u64,
    #[serde(flatten)]
    #[allow(dead_code)]
    extra: ExtraFields,
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
        let envelope: WireEnvelope = serde_json::from_slice(frame)
            .map_err(|error| invalid_data(format!("malformed protocol envelope: {error}")))?;

        match (self.expected_seq, envelope) {
            (None, WireEnvelope::Response(response)) => self.install_snapshot(response),
            (None, WireEnvelope::Event(_)) => {
                Err(invalid_data("event arrived before subscription response"))
            }
            (Some(_), WireEnvelope::Response(response)) => {
                self.validate_terminal_response(response)
            }
            (Some(expected), WireEnvelope::Event(event)) => self.decode_event(expected, event),
        }
    }

    fn install_snapshot(&mut self, response: ResponseEnvelope) -> io::Result<SubscriptionMessage> {
        validate_version(response.v)?;
        self.validate_response_id(response.id)?;
        if !response.ok {
            validate_error_response(&response)?;
            return Err(invalid_data("subscription request failed"));
        }
        if response.error.is_some() {
            return Err(invalid_data("successful response contained error"));
        }
        let result = response
            .result
            .ok_or_else(|| invalid_data("successful response missing result"))?;
        self.expected_seq = Some(result.next_seq);
        Ok(SubscriptionMessage::Snapshot(SubscriptionSnapshot {
            state: result.state,
            next_seq: result.next_seq,
            response_extra: response.extra,
            result_extra: result.extra,
        }))
    }

    fn validate_terminal_response(
        &self,
        response: ResponseEnvelope,
    ) -> io::Result<SubscriptionMessage> {
        validate_version(response.v)?;
        self.validate_response_id(response.id)?;
        if response.ok {
            if response.result.is_none() || response.error.is_some() {
                return Err(invalid_data("malformed successful response"));
            }
            return Err(invalid_data("unexpected response on event stream"));
        }
        validate_error_response(&response)?;
        let code = &response.error.as_ref().expect("validated error").code;
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
        event: EventEnvelope,
    ) -> io::Result<SubscriptionMessage> {
        validate_version(event.v)?;
        if event.seq != expected {
            return Err(invalid_data(format!(
                "non-consecutive event sequence: expected {expected}, got {}",
                event.seq
            )));
        }

        let kind = decode_event_data(event.event, event.data)?;
        self.expected_seq = Some(
            expected
                .checked_add(1)
                .ok_or_else(|| invalid_data("event sequence overflow"))?,
        );
        Ok(SubscriptionMessage::Event(ProtocolEvent {
            seq: event.seq,
            session_id: event.session_id,
            kind,
            extra: event.extra,
        }))
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

fn validate_error_response(response: &ResponseEnvelope) -> io::Result<()> {
    if response.result.is_some() || response.error.is_none() {
        return Err(invalid_data("malformed error response"));
    }
    Ok(())
}

fn decode_event_data(event: String, data: Map<String, Value>) -> io::Result<EventKind> {
    let value = Value::Object(data);

    match event.as_str() {
        "state.changed" => decode_payload(&event, value).map(EventKind::StateChanged),
        "audio.level" => {
            let level: AudioLevel = decode_payload(&event, value)?;
            if !(0.0..=1.0).contains(&level.rms) || !(0.0..=1.0).contains(&level.peak) {
                return Err(invalid_data("audio.level values must be in [0,1]"));
            }
            Ok(EventKind::AudioLevel(level))
        }
        "processing.stage_changed" => {
            decode_payload(&event, value).map(EventKind::ProcessingStageChanged)
        }
        "recording.limit_reached" => {
            decode_payload(&event, value).map(EventKind::RecordingLimitReached)
        }
        "operation.error" => decode_payload(&event, value).map(EventKind::OperationError),
        "output.completed" => decode_payload(&event, value).map(EventKind::OutputCompleted),
        "session.completed" => decode_payload(&event, value).map(EventKind::SessionCompleted),
        _ => {
            let Value::Object(data) = value else {
                unreachable!("event data starts as an object")
            };
            Ok(EventKind::Unknown { name: event, data })
        }
    }
}

fn decode_payload<T: DeserializeOwned>(event: &str, value: Value) -> io::Result<T> {
    serde_json::from_value(value)
        .map_err(|error| invalid_data(format!("invalid {event} payload: {error}")))
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
        assert!(snapshot.state.show_timer);
        assert_eq!(snapshot.next_seq, 19);
        assert!(snapshot.state.extra.contains_key("future_state"));
        assert!(snapshot.result_extra.contains_key("future_barrier"));
        assert!(snapshot.response_extra.contains_key("server_build"));
        decoder
    }

    #[test]
    fn shared_snapshot_and_known_event_fixtures_are_typed_and_additive() {
        let mut decoder = subscribed_decoder();
        let mut count = 0;
        for line in KNOWN_EVENTS.lines() {
            let SubscriptionMessage::Event(event) = decoder.decode(line.as_bytes()).unwrap() else {
                panic!("expected event")
            };
            if let EventKind::AudioLevel(level) = &event.kind {
                assert!(level.extra.contains_key("channels"));
            }
            count += 1;
        }
        assert_eq!(count, 7);
    }

    #[test]
    fn shared_unknown_event_fixture_consumes_sequence_and_retains_data() {
        let mut decoder = subscribed_decoder();
        for line in KNOWN_EVENTS.lines() {
            decoder.decode(line.as_bytes()).unwrap();
        }
        let SubscriptionMessage::Event(event) = decoder.decode(UNKNOWN_EVENT.as_bytes()).unwrap()
        else {
            panic!("expected event")
        };
        let EventKind::Unknown { name, data } = event.kind else {
            panic!("expected unknown event")
        };
        assert_eq!(name, "future.progress");
        assert!(data.contains_key("nested"));
        assert!(event.extra.contains_key("server_time"));

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
    fn shared_error_fixture_is_typed_additive_and_terminal() {
        let envelope: WireEnvelope = serde_json::from_str(ERROR_RESPONSE).unwrap();
        let WireEnvelope::Response(response) = envelope else {
            panic!("expected response")
        };
        let error = response.error.as_ref().unwrap();
        assert_eq!(error.code, "invalid_state");
        assert!(error.extra.contains_key("future_detail"));
        assert!(response.extra.contains_key("retryable"));

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
