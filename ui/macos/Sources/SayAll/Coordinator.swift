import AppKit
import AVFoundation

@MainActor
final class Coordinator {
    var state: DictationState { machine.state }
    private(set) var message = "Ready — Control+/ to start"
    private(set) var audioLevel = 0.0
    private var machine = StateMachine()
    private let capture = AudioCapture()
    private var beginTask: Task<Void, Never>?, task: Task<Void, Never>?
    private var maximumTimer: Timer?, operationID: UUID?
    private var streamSession: StreamingHelperSession?
    private var operationConfig: ProviderSettings?
    private let configuration: ConfigurationLoader
    private let changed: () -> Void

    init(configuration: ConfigurationLoader, changed: @escaping () -> Void) {
        self.configuration = configuration
        self.changed = changed
        capture.levelHandler = { [weak self] level in
            DispatchQueue.main.async {
                guard let self, self.state == .recording else { return }
                self.audioLevel = level
                self.changed()
            }
        }
    }
    func trigger() {
        switch state {
        case .idle:
            guard operationID == nil else { return }
            let id = UUID()
            operationID = id
            beginTask = Task { await begin(id) }
        case .recording: stop()
        default: break
        }
    }
    private func set(_ next: DictationState, _ message: String) {
        do { try machine.transition(to: next) }
        catch { assertionFailure("Illegal dictation transition: \(state) → \(next)"); return }
        self.message = message
        changed()
    }
    private func reset(after delay: TimeInterval = 1.5) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, [.success, .error, .cancelled].contains(self.state) else { return }
            self.set(.idle, "Ready — Control+/ to start")
        }
    }
    private func finish(_ id: UUID, as terminalState: DictationState, message: String, resetAfter delay: TimeInterval = 1.5) {
        guard operationID == id else { return }
        set(terminalState, message)
        operationConfig = nil
        operationID = nil
        reset(after: delay)
    }
    private func completeAndHide(_ id: UUID) {
        guard operationID == id else { return }
        operationConfig = nil
        operationID = nil
        set(.idle, "Ready — Control+/ to start")
    }
    private func begin(_ id: UUID) async {
        do { operationConfig = try configuration.load() }
        catch {
            finish(id, as: .error, message: Self.message(for: error, path: configuration.url.path), resetAfter: 8)
            return
        }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard operationID == id, !Task.isCancelled else { return }
        guard allowed else {
            finish(id, as: .error, message: "Microphone access is required — open System Settings", resetAfter: 3)
            return
        }
        do {
            let recording = try capture.start()
            guard let config = operationConfig else { throw HelperFailure.launch }
            var session: StreamingHelperSession?
            if config.streamingEnabled {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall-process")
                session = try await HelperRunner(executableURL: helper).launchStreaming(
                    StreamingHelperRequest(version: 1, wavPath: recording.wavURL.path, pcmPath: recording.pcmURL.path,
                        deepgramAPIKey: config.deepgramAPIKey, deepgramModel: config.deepgramModel,
                        deepgramLanguage: config.deepgramLanguage, deepgramRegion: config.deepgramRegion,
                        deepgramKeyterms: config.deepgramKeyterms,
                        streamFinalizeTimeoutMs: config.streamFinalizeTimeoutMs,
                        groqAPIKey: config.groqAPIKey, groqModel: config.groqModel,
                        groqBaseURL: config.groqBaseURL, cleanupEnabled: config.cleanupEnabled)
                )
            }
            guard operationID == id, !Task.isCancelled else {
                await session?.cancelAndWait()
                capture.cancel()
                return
            }
            streamSession = session
            set(.recording, "Recording — Control+/ to stop")
            maximumTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in Task { @MainActor in self?.stop() } }
        } catch let failure as HelperFailure {
            capture.cancel()
            finish(id, as: .error, message: Self.message(for: failure), resetAfter: 8)
        } catch {
            capture.cancel()
            finish(id, as: .error, message: "Could not start the default microphone", resetAfter: 3)
        }
    }
    private func stop() {
        guard let id = operationID else { return }
        audioLevel = 0
        set(.stopping, "Stopping recording…"); maximumTimer?.invalidate(); maximumTimer = nil
        let streamHelper = streamSession
        streamSession = nil
        let recording: AudioCapture.Recording
        do { recording = try capture.stop() }
        catch AudioCapture.CaptureError.tooShort {
            task = Task {
                await streamHelper?.cancelAndWait()
                finish(id, as: .error, message: "Recording was too short")
            }
            return
        }
        catch {
            task = Task {
                await streamHelper?.cancelAndWait()
                finish(id, as: .error, message: "Could not prepare the recording", resetAfter: 3)
            }
            return
        }
        set(.processing, "Transcribing with Deepgram…")
        task = Task {
            let processingStarted = Date()
            defer {
                try? FileManager.default.removeItem(at: recording.directoryURL)
            }
            guard operationID == id, !Task.isCancelled else {
                await streamHelper?.cancelAndWait()
                return
            }
            guard let config = operationConfig else {
                finish(id, as: .error, message: "SayAll configuration is unavailable")
                return
            }
            let request = HelperRequest(version: 1, wavPath: recording.wavURL.path, deepgramAPIKey: config.deepgramAPIKey,
                deepgramModel: config.deepgramModel, deepgramLanguage: config.deepgramLanguage,
                deepgramRegion: config.deepgramRegion, deepgramKeyterms: config.deepgramKeyterms,
                groqAPIKey: config.groqAPIKey, groqModel: config.groqModel,
                groqBaseURL: config.groqBaseURL, cleanupEnabled: config.cleanupEnabled)
            do {
                let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall-process")
                let result: HelperResult
                if let stream = streamHelper {
                    do {
                        result = try await stream.finish(forceRest: recording.streamSourceFailed,
                            timeout: Self.remainingProcessingTime(since: processingStarted))
                    } catch let failure as HelperFailure {
                        guard Self.shouldFallBackToBatch(after: failure) else { throw failure }
                        guard !Task.isCancelled else { throw CancellationError() }
                        result = try await HelperRunner(executableURL: helperURL).run(request,
                            timeout: Self.remainingProcessingTime(since: processingStarted))
                    }
                } else {
                    result = try await HelperRunner(executableURL: helperURL).run(request,
                        timeout: Self.remainingProcessingTime(since: processingStarted))
                }
                guard operationID == id, !Task.isCancelled else { return }
                guard result.status == .success, let text = result.text, !text.isEmpty else {
                    finish(id, as: .success, message: "No speech detected", resetAfter: 2)
                    return
                }
                set(.delivering, "Delivering transcript…")
                let delivery = TextDelivery.deliver(text)
                let warning = result.warning == "cleanup_failed" ? " Groq cleanup failed; used raw transcript." : ""
                switch delivery {
                case .pasteCommandPosted:
                    if warning.isEmpty {
                        completeAndHide(id)
                    } else {
                        finish(id, as: .success, message: "Pasted raw transcript — Groq cleanup failed", resetAfter: 3)
                    }
                case .copied:
                    finish(id, as: .success, message: "Copied to clipboard; grant Accessibility to paste automatically.\(warning)", resetAfter: 3)
                case .failed:
                    finish(id, as: .error, message: "Could not copy or paste the transcript", resetAfter: 3)
                }
            } catch is CancellationError { finish(id, as: .cancelled, message: "Dictation cancelled") }
            catch let HelperFailure.unsuccessful(code) { finish(id, as: .error, message: Self.message(for: code), resetAfter: 3) }
            catch let failure as HelperFailure {
                finish(id, as: .error, message: Self.message(for: failure), resetAfter: 8)
            }
            catch { finish(id, as: .error, message: "Processing failed; try again", resetAfter: 8) }
        }
    }
    func cancel() {
        let hadOperation = operationID != nil
        let starting = beginTask
        let work = task
        let session = streamSession
        operationID = nil
        operationConfig = nil
        maximumTimer?.invalidate()
        beginTask = nil; task = nil; streamSession = nil
        starting?.cancel(); work?.cancel(); capture.cancel()
        if hadOperation && [.idle, .recording, .stopping, .processing, .delivering].contains(state) {
            set(.cancelled, "Dictation cancelled")
            Task {
                await starting?.value
                await work?.value
                await session?.cancelAndWait()
                guard state == .cancelled else { return }
                reset(after: 0)
            }
        }
    }

    private static func message(for code: String) -> String {
        switch code {
        case "deepgram_unauthorized": return "Deepgram rejected the API key"
        case "deepgram_rate_limited": return "Deepgram rate limit reached; try later"
        case "deepgram_server", "deepgram_network": return "Deepgram is unavailable; check your connection"
        case "audio_too_short": return "Recording was too short"
        case "audio_too_long": return "Recording exceeded five minutes"
        case "invalid_audio": return "The recording could not be processed"
        default: return "Processing failed (\(code))"
        }
    }

    private static func message(for failure: HelperFailure) -> String {
        switch failure {
        case .launch: return "Could not start the transcription helper"
        case .invalidSignature: return "The bundled transcription helper could not be verified"
        case .timeout: return "Deepgram timed out after 45 seconds"
        case .oversizedRequest: return "The transcription request was too large"
        case .streamUnavailableBeforeFinish: return "The streaming helper stopped unexpectedly"
        case .oversizedOutput, .malformedOutput, .unsupportedVersion:
            return "The transcription helper returned an invalid response"
        case .unsuccessful(let code): return message(for: code)
        }
    }

    nonisolated static func shouldFallBackToBatch(after failure: HelperFailure) -> Bool {
        failure == .streamUnavailableBeforeFinish
    }

    nonisolated static func remainingProcessingTime(since started: Date, now: Date = Date()) throws -> TimeInterval {
        let remaining = 45 - now.timeIntervalSince(started)
        guard remaining > 0 else { throw HelperFailure.timeout }
        return remaining
    }

    private static func message(for error: Error, path: String) -> String {
        switch error as? ConfigurationError {
        case .missing: return "Create \(path) with stt.api_key"
        case .oversized: return "SayAll config.json exceeds 1 MiB"
        case .malformed: return "SayAll config.json is not valid JSON"
        case .missingDeepgramKey: return "Set stt.api_key or DEEPGRAM_API_KEY in \(path)"
        case .invalidProvider: return "Use a valid stt.model, stt.language, and global/eu/au region"
        case .invalidSecret: return "Provider API keys cannot contain whitespace"
        case nil: return "Could not load SayAll config.json"
        }
    }
}
