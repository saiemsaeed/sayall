import Foundation
import Darwin

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
    let llmAPIKey: String
    let llmModel: String
    let llmBaseURL: String
    let processingProfile: ProcessingProfile
    let showTimer: Bool
    let outputMethod: OutputMethod
    let trailingSpace: Bool
    let metricsEnabled: Bool
    let metricsHistoryMaxEntries: Int
}

enum ConfigurationError: Error, Equatable {
    case missing, oversized, malformed, missingDeepgramKey, invalidProvider, invalidProcessingMode
    case missingCerebrasKey, unsupportedPlannerModel, invalidOutputMethod, invalidMetrics, invalidSecret, writeFailed
}

struct ConfigurationLoader {
    private static let maximumBytes = 1_048_576
    private static let supportedPlannerModels = ["gpt-oss-120b"]
    private let environment: [String: String]
    private let homeDirectory: URL
    private let prePublication: (() throws -> Void)?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        prePublication: (() throws -> Void)? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.prePublication = prePublication
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
            document = Document(stt: nil, llm: nil, processing: nil, output: nil, metrics: nil, hud: nil)
        }
        return try settings(from: document)
    }

    func setProcessingMode(_ mode: ProcessingMode) throws {
        let directory = try openMutationDirectory()
        defer { Darwin.close(directory) }
        let lock = Darwin.openat(directory, ".config.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var lockStatus = stat()
        guard lock >= 0, Darwin.fstat(lock, &lockStatus) == 0,
              (lockStatus.st_mode & S_IFMT) == S_IFREG,
              lockStatus.st_uid == Darwin.geteuid(), (lockStatus.st_mode & 0o077) == 0,
              setLock(lock, type: F_WRLCK, command: F_SETLKW) else {
            if lock >= 0 { Darwin.close(lock) }
            throw ConfigurationError.writeFailed
        }
        defer { _ = setLock(lock, type: F_UNLCK, command: F_SETLK); Darwin.close(lock) }

        let original = try mutationSource(in: directory)
        let object: [String: Any]
        if let original {
            guard let decoded = try? JSONSerialization.jsonObject(with: original.bytes) as? [String: Any] else {
                throw ConfigurationError.malformed
            }
            object = decoded
        } else {
            object = [:]
        }
        var updated = object
        var processing: [String: Any]
        if let existing = updated["processing"] {
            guard let object = existing as? [String: Any] else { throw ConfigurationError.invalidProcessingMode }
            processing = object
        } else {
            processing = [:]
        }
        processing["mode"] = mode.rawValue
        updated["processing"] = processing
        guard JSONSerialization.isValidJSONObject(updated),
              let data = try? JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys]),
              data.count <= Self.maximumBytes,
              let stagedDocument = try? JSONDecoder().decode(Document.self, from: data) else {
            throw ConfigurationError.malformed
        }
        _ = try settings(from: stagedDocument)
        let temporary = ".config.json.\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(directory, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ConfigurationError.writeFailed }
        var published = false
        defer {
            Darwin.close(descriptor)
            if !published { Darwin.unlinkat(directory, temporary, 0) }
        }
        try write(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw ConfigurationError.writeFailed }
        try prePublication?()
        guard try mutationSource(in: directory) == original,
              Darwin.renameat(directory, temporary, directory, "config.json") == 0 else {
            throw ConfigurationError.writeFailed
        }
        published = true
    }

    private func settings(from document: Document) throws -> ProviderSettings {
        let deepgram = resolve(document.stt?.apiKey, override: "DEEPGRAM_API_KEY")
        let legacyCloudConfig = document.llm?.provider == "groq" ||
            document.llm?.baseURL == "https://api.groq.com/openai/v1/chat/completions"
        let cerebras = resolve(legacyCloudConfig ? nil : document.llm?.apiKey,
            override: "CEREBRAS_API_KEY")
        let model = document.stt?.model ?? "nova-3"
        let language = document.stt?.language ?? "en"
        let region = document.stt?.region ?? "global"
        let keyterms = try loadKeyterms(fallback: document.stt?.keyterms ?? [])
        let streaming = document.stt?.streaming ?? true
        let finalizeTimeout = document.stt?.streamFinalizeTimeoutMs ?? 2_000
        let llmModel = legacyCloudConfig ? "gpt-oss-120b" : document.llm?.model ?? "gpt-oss-120b"
        let llmBaseURL = legacyCloudConfig ? "https://api.cerebras.ai/v1/chat/completions" :
            document.llm?.baseURL ?? "https://api.cerebras.ai/v1/chat/completions"
        let configuredMode: ProcessingMode?
        if let rawMode = document.processing?.mode {
            guard let mode = ProcessingMode(rawValue: rawMode) else { throw ConfigurationError.invalidProcessingMode }
            configuredMode = mode
        } else {
            configuredMode = nil
        }
        let processingProfile: ProcessingProfile
        if let mode = configuredMode {
            processingProfile = ProcessingProfile(rawValue: mode.rawValue)!
        } else {
            processingProfile = document.llm?.enabled == true ? .legacyV1 : .verbatim
        }
        guard let outputMethod = OutputMethod(rawValue: document.output?.method ?? "type") else {
            throw ConfigurationError.invalidOutputMethod
        }
        guard (0...100_000).contains(document.metrics?.historyMaxEntries ?? 1_000) else {
            throw ConfigurationError.invalidMetrics
        }
        guard !deepgram.isEmpty else { throw ConfigurationError.missingDeepgramKey }
        guard Self.safeSecret(deepgram), Self.safeSecret(cerebras) else { throw ConfigurationError.invalidSecret }
        guard Self.safeLLMModel(llmModel) else { throw ConfigurationError.invalidProvider }
        guard Self.supportedPlannerModels.contains(llmModel) else {
            throw ConfigurationError.unsupportedPlannerModel
        }
        if configuredMode == .polished || configuredMode == .aiOnly {
            guard !cerebras.isEmpty else { throw ConfigurationError.missingCerebrasKey }
        }
        guard (document.stt?.provider ?? "deepgram") == "deepgram",
              legacyCloudConfig || (document.llm?.provider ?? "cerebras") == "cerebras",
              Self.safeProviderValue(model), Self.safeProviderValue(language),
              ["global", "eu", "au"].contains(region),
              (250...10_000).contains(finalizeTimeout),
              !(document.stt?.dictation ?? false) || (document.stt?.punctuate ?? false),
              llmBaseURL == "https://api.cerebras.ai/v1/chat/completions",
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
            llmAPIKey: cerebras,
            llmModel: llmModel,
            llmBaseURL: llmBaseURL,
            processingProfile: processingProfile,
            showTimer: document.hud?.showTimer ?? true,
            outputMethod: outputMethod,
            trailingSpace: document.output?.trailingSpace ?? true,
            metricsEnabled: document.metrics?.enabled ?? true,
            metricsHistoryMaxEntries: document.metrics?.historyMaxEntries ?? 1_000
        )
    }

    private struct SourceIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    private struct SourceSnapshot: Equatable {
        let identity: SourceIdentity
        let bytes: Data
    }

    private func openMutationDirectory() throws -> Int32 {
        let parent = url.deletingLastPathComponent()
        var status = stat()
        if Darwin.lstat(parent.path, &status) != 0 {
            guard errno == ENOENT else { throw ConfigurationError.writeFailed }
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch {
                throw ConfigurationError.writeFailed
            }
        }
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ConfigurationError.writeFailed }
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == Darwin.geteuid(),
              (status.st_mode & 0o077) == 0 else {
            Darwin.close(descriptor)
            throw ConfigurationError.writeFailed
        }
        return descriptor
    }

    private func mutationSource(in directory: Int32) throws -> SourceSnapshot? {
        let descriptor = Darwin.openat(directory, "config.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ConfigurationError.writeFailed
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == Darwin.geteuid(),
              status.st_size <= Self.maximumBytes else {
            throw ConfigurationError.writeFailed
        }
        let identity = sourceIdentity(status)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ConfigurationError.writeFailed }
            if count == 0 { break }
            bytes.append(buffer, count: count)
            guard bytes.count <= Self.maximumBytes else { throw ConfigurationError.oversized }
        }
        guard Darwin.fstat(descriptor, &status) == 0, sourceIdentity(status) == identity else {
            throw ConfigurationError.writeFailed
        }
        return SourceSnapshot(identity: identity, bytes: bytes)
    }

    private func sourceIdentity(_ status: stat) -> SourceIdentity {
        SourceIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size),
            modifiedSeconds: Int64(status.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec))
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), rawBuffer.count - written)
                guard count > 0 else { throw ConfigurationError.writeFailed }
                written += count
            }
        }
    }

    private func setLock(_ descriptor: Int32, type: Int32, command: Int32) -> Bool {
        var lock = flock()
        lock.l_type = Int16(type)
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, command, &lock) == 0
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
        let processing: Processing?
        let output: Output?
        let metrics: Metrics?
        let hud: HUD?
    }

    private struct Processing: Decodable {
        let mode: String?
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
