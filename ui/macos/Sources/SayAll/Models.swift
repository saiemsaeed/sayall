import Foundation

enum ProcessingProtocol {
    static let version = 2
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
    let groqAPIKey: String
    let groqModel: String
    let groqBaseURL: String
    let cleanupEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case version, wavPath = "wav_path", deepgramAPIKey = "deepgram_api_key"
        case deepgramModel = "deepgram_model", deepgramLanguage = "deepgram_language"
        case deepgramRegion = "deepgram_region", deepgramKeyterms = "deepgram_keyterms"
        case smartFormat = "deepgram_smart_format", punctuate = "deepgram_punctuate"
        case dictation = "deepgram_dictation", numerals = "deepgram_numerals", measurements = "deepgram_measurements"
        case groqAPIKey = "groq_api_key", groqModel = "groq_model", groqBaseURL = "groq_base_url"
        case cleanupEnabled = "cleanup_enabled"
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
    let groqAPIKey: String
    let groqModel: String
    let groqBaseURL: String
    let cleanupEnabled: Bool
    enum CodingKeys: String, CodingKey {
        case version, wavPath = "wav_path", pcmPath = "pcm_path", deepgramAPIKey = "deepgram_api_key"
        case deepgramModel = "deepgram_model", deepgramLanguage = "deepgram_language"
        case deepgramRegion = "deepgram_region", deepgramKeyterms = "deepgram_keyterms"
        case smartFormat = "deepgram_smart_format", punctuate = "deepgram_punctuate"
        case dictation = "deepgram_dictation", numerals = "deepgram_numerals", measurements = "deepgram_measurements"
        case streamFinalizeTimeoutMs = "stream_finalize_timeout_ms"
        case groqAPIKey = "groq_api_key", groqModel = "groq_model", groqBaseURL = "groq_base_url"
        case cleanupEnabled = "cleanup_enabled"
    }
}

struct StreamingHelperFinish: Codable, Equatable {
    let version: Int
    let command: String
    let forceRest: Bool
    enum CodingKeys: String, CodingKey { case version, command, forceRest = "force_rest" }
}

struct HelperResult: Codable, Equatable {
    enum Status: String, Codable { case success, noSpeech = "no_speech", error }
    let version: Int
    let status: Status
    let text: String?
    let warning: String?
    let error: String?
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
        if result.status == .error { throw HelperFailure.unsuccessful(result.error ?? "helper_error") }
        return result
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
