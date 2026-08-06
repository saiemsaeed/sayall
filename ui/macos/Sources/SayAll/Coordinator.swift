import AppKit
import AVFoundation
import SayAllControl

@MainActor
final class Coordinator {
    enum TriggerSource { case shortcut, menu, control }

    private struct StartupTiming {
        let source: TriggerSource
        let started: UInt64
        var hudPresented: UInt64?
        var targetCaptureMs = 0
        var configLoadMs = 0
        var microphonePermissionMs = 0
        var compatibilityMs = 0
        var audioStartMs = 0
        var streamReadyMs = 0
    }

    var state: DictationState { machine.state }
    private(set) var message = "Ready — Control+/ to start"
    private(set) var audioLevel = 0.0
    private(set) var showTimer = true
    private var machine = StateMachine()
    private let capture = AudioCapture()
    private var beginTask: Task<Void, Never>?, task: Task<Void, Never>?
    private var maximumTimer: Timer?, operationID: UUID?
    private var streamSession: StreamingHelperSession?
    private var operationConfig: ProviderSettings?
    private var deliveryTarget: TextDelivery.Target?
    private var pendingWarning: String?
    private var startupTiming: StartupTiming?
    private let startupMetrics = StartupMetricsStore()
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
        capture.failureHandler = { [weak self] in
            DispatchQueue.main.async { self?.audioCaptureFailed() }
        }
    }
    func trigger(source: TriggerSource = .menu) {
        switch state {
        case .idle:
            guard operationID == nil else { return }
            let started = DispatchTime.now().uptimeNanoseconds
            let id = UUID()
            operationID = id
            deliveryTarget = nil
            startupTiming = StartupTiming(source: source, started: started)
            set(.starting, "Starting recording…")
            var phaseStarted = DispatchTime.now().uptimeNanoseconds
            do {
                operationConfig = try configuration.load()
                showTimer = operationConfig?.showTimer ?? true
                startupTiming?.configLoadMs = Self.elapsedMilliseconds(since: phaseStarted)
            } catch {
                finish(id, as: .error, message: Self.message(for: error, path: configuration.url.path), resetAfter: 8)
                return
            }
            phaseStarted = DispatchTime.now().uptimeNanoseconds
            if operationConfig?.outputMethod != .clipboard {
                deliveryTarget = TextDelivery.captureTarget()
            }
            startupTiming?.targetCaptureMs = Self.elapsedMilliseconds(since: phaseStarted)
            beginTask = Task { await begin(id) }
        case .recording: stop()
        default: break
        }
    }

    func markHUDPresented() {
        guard state == .starting, startupTiming?.hudPresented == nil else { return }
        startupTiming?.hudPresented = DispatchTime.now().uptimeNanoseconds
    }

    var hostControlState: HostControlState {
        switch state {
        case .idle: return .idle
        case .starting: return .starting
        case .recording: return .recording
        case .stopping: return .stopping
        case .processing: return .processing
        case .delivering: return .delivering
        case .success: return .success
        case .error: return .error
        case .cancelled: return .cancelled
        }
    }
    var controlState: String { hostControlState.rawValue }

    func takePendingWarning() -> String? {
        defer { pendingWarning = nil }
        return pendingWarning
    }

    func handleControl(_ method: ControlMethod) -> ControlResponse {
        switch method {
        case .status:
            return ControlResponse(ok: true, state: controlState)
        case .toggle:
            guard state == .idle || state == .recording else {
                return ControlResponse(ok: false, state: controlState,
                                       error: "busy: SayAll is \(controlState)")
            }
            guard !(state == .idle && operationID != nil) else {
                return ControlResponse(ok: false, state: controlState, error: "busy: SayAll is starting")
            }
            trigger(source: .control)
            return ControlResponse(ok: true, state: controlState)
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
        deliveryTarget = nil
        operationID = nil
        reset(after: delay)
    }
    private func completeAndHide(_ id: UUID) {
        guard operationID == id else { return }
        operationConfig = nil
        deliveryTarget = nil
        operationID = nil
        set(.idle, "Ready — Control+/ to start")
    }
    private func audioCaptureFailed() {
        guard let id = operationID, state == .starting || state == .recording else { return }
        audioLevel = 0
        maximumTimer?.invalidate()
        maximumTimer = nil
        let activeStream = streamSession
        streamSession = nil
        capture.cancel()
        persistStartup(outcome: "audio_device_interrupted")
        finish(id, as: .error, message: "Microphone disconnected or stopped — choose an available input from the SayAll menu", resetAfter: 5)
        task = Task { await activeStream?.cancelAndWait() }
    }
    private func begin(_ id: UUID) async {
        pendingWarning = nil
        var phaseStarted = DispatchTime.now().uptimeNanoseconds
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        startupTiming?.microphonePermissionMs = Self.elapsedMilliseconds(since: phaseStarted)
        guard operationID == id, !Task.isCancelled else { return }
        guard allowed else {
            persistStartup(outcome: "permission_denied")
            finish(id, as: .error, message: "Microphone access is required — open System Settings", resetAfter: 3)
            return
        }
        do {
            guard let config = operationConfig else { throw HelperFailure.launch }
            let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall-process")
            let helper = HelperRunner(executableURL: helperURL)
            phaseStarted = DispatchTime.now().uptimeNanoseconds
            let compatibility = try await helper.compatibilityPreflight()
            startupTiming?.compatibilityMs = Self.elapsedMilliseconds(since: phaseStarted)
            guard operationID == id, !Task.isCancelled else { return }
            phaseStarted = DispatchTime.now().uptimeNanoseconds
            let recording = try capture.start()
            startupTiming?.audioStartMs = Self.elapsedMilliseconds(since: phaseStarted)
            var session: StreamingHelperSession?
            if config.streamingEnabled {
                phaseStarted = DispatchTime.now().uptimeNanoseconds
                session = try await helper.launchStreaming(
                    StreamingHelperRequest(version: 1, wavPath: recording.wavURL.path, pcmPath: recording.pcmURL.path,
                        deepgramAPIKey: config.deepgramAPIKey, deepgramModel: config.deepgramModel,
                        deepgramLanguage: config.deepgramLanguage, deepgramRegion: config.deepgramRegion,
                        deepgramKeyterms: config.deepgramKeyterms,
                        streamFinalizeTimeoutMs: config.streamFinalizeTimeoutMs,
                        groqAPIKey: config.groqAPIKey, groqModel: config.groqModel,
                        groqBaseURL: config.groqBaseURL, cleanupEnabled: config.cleanupEnabled),
                    compatibility: compatibility)
                startupTiming?.streamReadyMs = Self.elapsedMilliseconds(since: phaseStarted)
            }
            guard operationID == id, !Task.isCancelled else {
                await session?.cancelAndWait()
                capture.cancel()
                return
            }
            streamSession = session
            set(.recording, "Recording — Control+/ to stop")
            persistStartup(outcome: "recording_ready", recordingReady: true)
            maximumTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in Task { @MainActor in self?.stop() } }
        } catch let failure as HelperFailure {
            capture.cancel()
            persistStartup(outcome: "helper_error")
            finish(id, as: .error, message: Self.message(for: failure), resetAfter: 8)
        } catch AudioCapture.CaptureError.deviceUnavailable {
            capture.cancel()
            persistStartup(outcome: "audio_device_unavailable")
            finish(id, as: .error, message: "Selected microphone is unavailable — choose another input from the SayAll menu", resetAfter: 5)
        } catch {
            capture.cancel()
            persistStartup(outcome: "audio_error")
            finish(id, as: .error, message: "Could not start the selected microphone", resetAfter: 3)
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
                    completeAndHide(id)
                    return
                }
                set(.delivering, "Delivering transcript…")
                let deliveredText = config.trailingSpace ? text + " " : text
                let delivery = TextDelivery.deliver(deliveredText, method: config.outputMethod, to: deliveryTarget)
                if result.warning == "cleanup_failed" {
                    pendingWarning = "Groq cleanup failed; used the raw transcript."
                }
                switch delivery {
                case .typeCommandPosted, .pasteCommandPosted:
                    completeAndHide(id)
                case .copied:
                    finish(id, as: .success, message: "Copied to clipboard", resetAfter: 3)
                case .copiedFallback:
                    let action = config.outputMethod == .type ? "Type" : "Paste"
                    let deliveryWarning = "\(action) failed; the transcript was copied to the clipboard. Check SayAll's Accessibility permission and keep a text field in the original app window focused."
                    pendingWarning = [pendingWarning, deliveryWarning].compactMap { $0 }.joined(separator: " ")
                    finish(id, as: .success, message: "Copied to clipboard", resetAfter: 3)
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
        if hadOperation && state == .starting { persistStartup(outcome: "cancelled") }
        operationID = nil
        operationConfig = nil
        deliveryTarget = nil
        maximumTimer?.invalidate()
        beginTask = nil; task = nil; streamSession = nil
        starting?.cancel(); work?.cancel(); capture.cancel()
        if hadOperation && [.starting, .recording, .stopping, .processing, .delivering].contains(state) {
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

    private func persistStartup(outcome: String, recordingReady: Bool = false) {
        guard let timing = startupTiming, let config = operationConfig else {
            startupTiming = nil
            return
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        let shortcut = timing.source == .shortcut
        let sample = StartupMetricSample(
            shortcutToHUDMs: shortcut ? timing.hudPresented.map {
                Self.elapsedMilliseconds(from: timing.started, to: $0)
            } : nil,
            shortcutToRecordingReadyMs: shortcut && recordingReady
                ? Self.elapsedMilliseconds(from: timing.started, to: finished) : nil,
            targetCaptureMs: timing.targetCaptureMs,
            configLoadMs: timing.configLoadMs,
            microphonePermissionMs: timing.microphonePermissionMs,
            compatibilityMs: timing.compatibilityMs,
            audioStartMs: timing.audioStartMs,
            streamReadyMs: timing.streamReadyMs,
            outcome: outcome
        )
        startupTiming = nil
        Task {
            await startupMetrics.record(sample, enabled: config.metricsEnabled,
                limit: config.metricsHistoryMaxEntries)
        }
    }

    private nonisolated static func elapsedMilliseconds(since started: UInt64) -> Int {
        elapsedMilliseconds(from: started, to: DispatchTime.now().uptimeNanoseconds)
    }

    private nonisolated static func elapsedMilliseconds(from started: UInt64, to finished: UInt64) -> Int {
        Int((finished >= started ? finished - started : 0) / 1_000_000)
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
        case .incompatibleBuild: return "The bundled transcription helper does not match this version of SayAll"
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
        case .invalidOutputMethod: return "Set output.method to type, paste, or clipboard"
        case .invalidMetrics: return "Set metrics.history_max_entries between 0 and 100000"
        case .invalidSecret: return "Provider API keys cannot contain whitespace"
        case nil: return "Could not load SayAll config.json"
        }
    }
}
