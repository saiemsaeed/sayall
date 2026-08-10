import Foundation

enum ProcessingProtocol {
    static let version = 3
}

enum ProcessingMode: String, Codable, CaseIterable, Equatable {
    case verbatim, clean, polished
    case aiOnly = "ai_only"

    var title: String { self == .aiOnly ? "AI Only" : rawValue.capitalized }
    var description: String {
        switch self {
        case .verbatim: return "Keep the transcript as spoken"
        case .clean: return "Apply faithful, deterministic cleanup"
        case .polished: return "Restructure for clarity with Cerebras"
        case .aiOnly: return "Send the raw transcript directly to Cerebras"
        }
    }
}

enum ProcessingProfile: String, Codable, Equatable {
    case verbatim, clean, polished, aiOnly = "ai_only", legacyV1 = "legacy_v1"

    var title: String {
        switch self {
        case .verbatim: return "Verbatim"
        case .clean: return "Clean"
        case .polished: return "Polished"
        case .aiOnly: return "AI Only"
        case .legacyV1: return "Legacy"
        }
    }

    var userMode: ProcessingMode {
        switch self {
        case .verbatim: return .verbatim
        case .clean: return .clean
        case .polished, .legacyV1: return .polished
        case .aiOnly: return .aiOnly
        }
    }
}

enum DictationState: String, CaseIterable {
    case idle, starting, recording, stopping, processing, delivering, success, error, cancelled

    func canTransition(to next: DictationState) -> Bool {
        switch (self, next) {
        case (.idle, .starting), (.idle, .error),
             (.starting, .recording), (.starting, .error), (.starting, .cancelled),
             (.recording, .stopping), (.recording, .error), (.recording, .cancelled),
             (.stopping, .processing), (.stopping, .error), (.stopping, .cancelled),
             (.processing, .idle), (.processing, .delivering), (.processing, .success),
             (.processing, .error), (.processing, .cancelled),
             (.delivering, .idle), (.delivering, .success), (.delivering, .error), (.delivering, .cancelled),
             (.success, .idle), (.error, .idle), (.cancelled, .idle): return true
        default: return false
        }
    }
}

struct StateMachine {
    private(set) var state: DictationState = .idle
    mutating func transition(to next: DictationState) throws {
        guard state.canTransition(to: next) else { throw StateError.illegal(state, next) }
        state = next
    }
    enum StateError: Error, Equatable { case illegal(DictationState, DictationState) }
}

struct HelperRequest: Codable, Equatable {
    let version: Int
    let wavPath: String
    let deepgramAPIKey: String
    let deepgramModel: String
    let deepgramLanguage: String
    let deepgramRegion: String
    let deepgramKeyterms: [String]
    let smartFormat: Bool
    let punctuate: Bool
    let dictation: Bool
    let numerals: Bool
    let measurements: Bool
    let llmAPIKey: String
    let llmModel: String
    let llmBaseURL: String
    let processingProfile: ProcessingProfile
    enum CodingKeys: String, CodingKey {
        case version, wavPath = "wav_path", deepgramAPIKey = "deepgram_api_key"
        case deepgramModel = "deepgram_model", deepgramLanguage = "deepgram_language"
        case deepgramRegion = "deepgram_region", deepgramKeyterms = "deepgram_keyterms"
        case smartFormat = "deepgram_smart_format", punctuate = "deepgram_punctuate"
        case dictation = "deepgram_dictation", numerals = "deepgram_numerals", measurements = "deepgram_measurements"
        case llmAPIKey = "llm_api_key", llmModel = "llm_model", llmBaseURL = "llm_base_url"
        case processingProfile = "processing_profile"
    }
}

struct StreamingHelperRequest: Codable, Equatable {
    let version: Int
    let wavPath: String
    let pcmPath: String
    let deepgramAPIKey: String
    let deepgramModel: String
    let deepgramLanguage: String
    let deepgramRegion: String
    let deepgramKeyterms: [String]
    let smartFormat: Bool
    let punctuate: Bool
    let dictation: Bool
    let numerals: Bool
    let measurements: Bool
    let streamFinalizeTimeoutMs: Int
    let llmAPIKey: String
    let llmModel: String
    let llmBaseURL: String
    let processingProfile: ProcessingProfile
    enum CodingKeys: String, CodingKey {
        case version, wavPath = "wav_path", pcmPath = "pcm_path", deepgramAPIKey = "deepgram_api_key"
        case deepgramModel = "deepgram_model", deepgramLanguage = "deepgram_language"
        case deepgramRegion = "deepgram_region", deepgramKeyterms = "deepgram_keyterms"
        case smartFormat = "deepgram_smart_format", punctuate = "deepgram_punctuate"
        case dictation = "deepgram_dictation", numerals = "deepgram_numerals", measurements = "deepgram_measurements"
        case streamFinalizeTimeoutMs = "stream_finalize_timeout_ms"
        case llmAPIKey = "llm_api_key", llmModel = "llm_model", llmBaseURL = "llm_base_url"
        case processingProfile = "processing_profile"
    }
}

struct StreamingHelperFinish: Codable, Equatable {
    let version: Int
    let command: String
    let forceRest: Bool
    enum CodingKeys: String, CodingKey { case version, command, forceRest = "force_rest" }
}

enum WorkerErrorCode: String, Codable, Equatable {
    case invalidRequest = "invalid_request"
    case incompatibleVersion = "incompatible_version"
    case invalidAudio = "invalid_audio"
    case audioTooShort = "audio_too_short"
    case audioTooLong = "audio_too_long"
    case missingDeepgramKey = "missing_deepgram_key"
    case deepgramUnauthorized = "deepgram_unauthorized"
    case deepgramRateLimited = "deepgram_rate_limited"
    case deepgramServer = "deepgram_server"
    case deepgramNetwork = "deepgram_network"
    case responseTooLarge = "response_too_large"
    case internalError = "internal"
}

struct HelperResult: Codable, Equatable {
    struct Timing: Codable, Equatable {
        let deepgramConnectMs: Int?
        let deepgramStopToFinalMs: Int?
        let restSTTMs: Int?
        let deterministicProcessingMs: Int
        let plannerMs: Int?
        let processingTotalMs: Int
        enum CodingKeys: String, CodingKey {
            case deepgramConnectMs = "deepgram_connect_ms"
            case deepgramStopToFinalMs = "deepgram_stop_to_final_ms"
            case restSTTMs = "rest_stt_ms"
            case deterministicProcessingMs = "deterministic_processing_ms"
            case plannerMs = "planner_ms"
            case processingTotalMs = "processing_total_ms"
        }
    }
    enum Status: String, Codable { case success, noSpeech = "no_speech", error }
    enum Transport: String, Codable { case rest, stream }
    let version: Int
    let status: Status
    let text: String?
    let warning: String?
    let error: WorkerErrorCode?
    let processingProfile: ProcessingProfile
    let transport: Transport
    let timing: Timing?
    enum CodingKeys: String, CodingKey {
        case version, status, text, warning, error, transport, timing
        case processingProfile = "processing_profile"
    }
}

enum HelperFailure: Error, Equatable {
    case launch, invalidSignature, timeout, oversizedRequest, oversizedOutput, malformedOutput, unsupportedVersion
    case incompatibleBuild, streamUnavailableBeforeFinish, unsuccessful(String)
}

struct WorkerInfo: Codable, Equatable {
    let protocolVersion: Int
    let buildVersion: String
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol_version", buildVersion = "build_version" }
}

enum HelperDecoder {
    static let maximumRequestBytes = 65_536
    static let maximumOutputBytes = 1_048_576
    static func decode(_ data: Data) throws -> HelperResult {
        guard data.count <= maximumOutputBytes else { throw HelperFailure.oversizedOutput }
        guard let result = try? JSONDecoder().decode(HelperResult.self, from: data) else { throw HelperFailure.malformedOutput }
        guard result.version == ProcessingProtocol.version else { throw HelperFailure.unsupportedVersion }
        switch result.status {
        case .success:
            guard let text = result.text, !text.isEmpty, result.error == nil,
                  result.warning == nil || result.warning == "transformation_failed" else {
                throw HelperFailure.malformedOutput
            }
            return result
        case .noSpeech:
            guard result.text == nil, result.warning == nil, result.error == nil else {
                throw HelperFailure.malformedOutput
            }
            return result
        case .error:
            guard result.text == nil, result.warning == nil,
                  let error = result.error else { throw HelperFailure.malformedOutput }
            throw HelperFailure.unsuccessful(error.rawValue)
        }
    }
}

enum StreamingHelperDecoder {
    struct Ready: Codable, Equatable {
        let version: Int
        let event: String
        let streaming: Bool
    }

    static let maximumReadyBytes = 4096
    static func decodeReady(_ data: Data) throws -> Ready {
        guard !data.isEmpty, data.count <= maximumReadyBytes,
              let ready = try? JSONDecoder().decode(Ready.self, from: data),
              ready.version == ProcessingProtocol.version, ready.event == "ready" else { throw HelperFailure.streamUnavailableBeforeFinish }
        return ready
    }

    static func decode(_ data: Data) throws -> HelperResult {
        guard data.count <= HelperDecoder.maximumOutputBytes else { throw HelperFailure.oversizedOutput }
        return try HelperDecoder.decode(data)
    }
}
