import Foundation

enum OutputMethod: String, Equatable {
    case type, clipboard, paste
}

struct ProviderSettings: Equatable {
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
    let streamingEnabled: Bool
    let streamFinalizeTimeoutMs: Int
    let groqAPIKey: String
    let groqModel: String
    let groqBaseURL: String
    let cleanupEnabled: Bool
    let showTimer: Bool
    let outputMethod: OutputMethod
    let trailingSpace: Bool
    let metricsEnabled: Bool
    let metricsHistoryMaxEntries: Int
}

enum ConfigurationError: Error, Equatable {
    case missing, oversized, malformed, missingDeepgramKey, invalidProvider, invalidOutputMethod, invalidMetrics, invalidSecret
}

struct ConfigurationLoader {
    private static let maximumBytes = 1_048_576
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var url: URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("sayall/config.json")
        }
        return homeDirectory.appendingPathComponent(".config/sayall/config.json")
    }

    func load() throws -> ProviderSettings {
        let document: Document
        if FileManager.default.fileExists(atPath: url.path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else { throw ConfigurationError.malformed }
            guard size.intValue <= Self.maximumBytes else { throw ConfigurationError.oversized }
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(Document.self, from: data) else {
                throw ConfigurationError.malformed
            }
            document = decoded
        } else {
            document = Document(stt: nil, llm: nil, output: nil, metrics: nil, hud: nil)
        }
        let deepgram = resolve(document.stt?.apiKey, override: "DEEPGRAM_API_KEY")
        let groq = resolve(document.llm?.apiKey, override: "GROQ_API_KEY")
        let model = document.stt?.model ?? "nova-3"
        let language = document.stt?.language ?? "en"
        let region = document.stt?.region ?? "global"
        let keyterms = try loadKeyterms(fallback: document.stt?.keyterms ?? [])
        let streaming = document.stt?.streaming ?? true
        let finalizeTimeout = document.stt?.streamFinalizeTimeoutMs ?? 2_000
        let groqModel = document.llm?.model ?? "openai/gpt-oss-20b"
        let groqBaseURL = document.llm?.baseURL ?? "https://api.groq.com/openai/v1/chat/completions"
        guard let outputMethod = OutputMethod(rawValue: document.output?.method ?? "type") else {
            throw ConfigurationError.invalidOutputMethod
        }
        guard (0...100_000).contains(document.metrics?.historyMaxEntries ?? 1_000) else {
            throw ConfigurationError.invalidMetrics
        }
        guard !deepgram.isEmpty else { throw ConfigurationError.missingDeepgramKey }
        guard Self.safeSecret(deepgram), Self.safeSecret(groq) else { throw ConfigurationError.invalidSecret }
        guard (document.stt?.provider ?? "deepgram") == "deepgram",
              (document.llm?.provider ?? "groq") == "groq",
              Self.safeProviderValue(model), Self.safeProviderValue(language), Self.safeLLMModel(groqModel),
              ["global", "eu", "au"].contains(region),
              (250...10_000).contains(finalizeTimeout),
              !(document.stt?.dictation ?? false) || (document.stt?.punctuate ?? false),
              groqBaseURL == "https://api.groq.com/openai/v1/chat/completions",
              keyterms.isEmpty || model == "nova-3" || model.hasPrefix("nova-3-") else {
            throw ConfigurationError.invalidProvider
        }
        return ProviderSettings(
            deepgramAPIKey: deepgram,
            deepgramModel: model,
            deepgramLanguage: language,
            deepgramRegion: region,
            deepgramKeyterms: keyterms,
            smartFormat: document.stt?.smartFormat ?? false,
            punctuate: document.stt?.punctuate ?? false,
            dictation: document.stt?.dictation ?? false,
            numerals: document.stt?.numerals ?? false,
            measurements: document.stt?.measurements ?? false,
            streamingEnabled: streaming,
            streamFinalizeTimeoutMs: finalizeTimeout,
            groqAPIKey: groq,
            groqModel: groqModel,
            groqBaseURL: groqBaseURL,
            cleanupEnabled: (document.llm?.enabled ?? false) && !groq.isEmpty,
            showTimer: document.hud?.showTimer ?? true,
            outputMethod: outputMethod,
            trailingSpace: document.output?.trailingSpace ?? true,
            metricsEnabled: document.metrics?.enabled ?? true,
            metricsHistoryMaxEntries: document.metrics?.historyMaxEntries ?? 1_000
        )
    }

    private func loadKeyterms(fallback: [String]) throws -> [String] {
        let keywordsURL = url.deletingLastPathComponent().appendingPathComponent("keywords.json")
        let values: [String]
        if FileManager.default.fileExists(atPath: keywordsURL.path) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: keywordsURL.path),
                  let size = attributes[.size] as? NSNumber, size.intValue <= 65_536,
                  let data = try? Data(contentsOf: keywordsURL),
                  let document = try? JSONDecoder().decode(KeywordDocument.self, from: data),
                  document.version == 1 else { throw ConfigurationError.malformed }
            values = document.keywords
        } else {
            values = fallback
        }
        guard values.count <= 100,
              Set(values).count == values.count,
              values.reduce(0, { $0 + $1.utf8.count }) <= 4_096,
              values.allSatisfy({ value in
                  !value.isEmpty && value.utf8.count <= 256 && value.unicodeScalars.allSatisfy {
                      !($0.value <= 0x1f || ($0.value >= 0x7f && $0.value <= 0x9f))
                  }
              }) else { throw ConfigurationError.invalidProvider }
        return values
    }

    private func resolve(_ fileValue: String?, override name: String) -> String {
        if let value = environment[name], !value.isEmpty { return value }
        let value = fileValue ?? ""
        if value.first == "$", value.count > 1 {
            return environment[String(value.dropFirst())] ?? ""
        }
        return value
    }

    private static func safeSecret(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            !$0.properties.isWhitespace && $0.value >= 0x20 && $0.value != 0x7f
        }
    }

    private static func safeProviderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || [45, 46, 95].contains($0)
        }
    }

    private static func safeLLMModel(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return value.utf8.count <= 64 && (parts.count == 1 || parts.count == 2)
            && parts.allSatisfy { safeProviderValue(String($0)) }
    }

    private struct Document: Decodable {
        let stt: STT?
        let llm: LLM?
        let output: Output?
        let metrics: Metrics?
        let hud: HUD?
    }

    private struct STT: Decodable {
        let provider: String?
        let apiKey: String?
        let model: String?
        let language: String?
        let region: String?
        let keyterms: [String]?
        let smartFormat: Bool?
        let punctuate: Bool?
        let dictation: Bool?
        let numerals: Bool?
        let measurements: Bool?
        let streaming: Bool?
        let streamFinalizeTimeoutMs: Int?
        enum CodingKeys: String, CodingKey {
            case provider, apiKey = "api_key", model, language, region, keyterms, punctuate, dictation, numerals, measurements, streaming
            case smartFormat = "smart_format"
            case streamFinalizeTimeoutMs = "stream_finalize_timeout_ms"
        }
    }

    private struct LLM: Decodable {
        let provider: String?
        let apiKey: String?
        let model: String?
        let baseURL: String?
        let enabled: Bool?
        enum CodingKeys: String, CodingKey {
            case provider, apiKey = "api_key", model, baseURL = "base_url", enabled
        }
    }

    private struct Metrics: Decodable {
        let enabled: Bool?
        let historyMaxEntries: Int?
        enum CodingKeys: String, CodingKey {
            case enabled, historyMaxEntries = "history_max_entries"
        }
    }

    private struct HUD: Decodable {
        let showTimer: Bool?
        enum CodingKeys: String, CodingKey {
            case showTimer = "show_timer"
        }
    }

    private struct Output: Decodable {
        let method: String?
        let trailingSpace: Bool?
        enum CodingKeys: String, CodingKey {
            case method, trailingSpace = "trailing_space"
        }
    }

    private struct KeywordDocument: Decodable {
        let version: Int
        let keywords: [String]
    }
}
