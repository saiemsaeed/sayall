import Darwin
import Foundation

struct StartupMetricSample: Codable, Equatable {
    let correlationID: String?
    let shortcutToHUDMs: Int?
    let shortcutToFirstPCMWriteMs: Int?
    let shortcutToRecordingReadyMs: Int?
    let targetCaptureMs: Int
    let configLoadMs: Int
    let microphonePermissionMs: Int
    let compatibilityMs: Int
    let audioStartMs: Int
    let audioFilePreparationMs: Int?
    let audioDeviceResolutionMs: Int?
    let audioInputInitializationMs: Int?
    let audioInputStartMs: Int?
    let streamReadyMs: Int
    let outcome: String

    init(correlationID: String? = nil, shortcutToHUDMs: Int?, shortcutToFirstPCMWriteMs: Int? = nil,
         shortcutToRecordingReadyMs: Int?, targetCaptureMs: Int,
         configLoadMs: Int, microphonePermissionMs: Int, compatibilityMs: Int, audioStartMs: Int,
         audioFilePreparationMs: Int? = nil, audioDeviceResolutionMs: Int? = nil,
         audioInputInitializationMs: Int? = nil, audioInputStartMs: Int? = nil,
         streamReadyMs: Int, outcome: String) {
        self.correlationID = correlationID
        self.shortcutToHUDMs = shortcutToHUDMs
        self.shortcutToFirstPCMWriteMs = shortcutToFirstPCMWriteMs
        self.shortcutToRecordingReadyMs = shortcutToRecordingReadyMs
        self.targetCaptureMs = targetCaptureMs
        self.configLoadMs = configLoadMs
        self.microphonePermissionMs = microphonePermissionMs
        self.compatibilityMs = compatibilityMs
        self.audioStartMs = audioStartMs
        self.audioFilePreparationMs = audioFilePreparationMs
        self.audioDeviceResolutionMs = audioDeviceResolutionMs
        self.audioInputInitializationMs = audioInputInitializationMs
        self.audioInputStartMs = audioInputStartMs
        self.streamReadyMs = streamReadyMs
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey {
        case correlationID = "correlation_id"
        case shortcutToHUDMs = "shortcut_to_hud_ms"
        case shortcutToFirstPCMWriteMs = "shortcut_to_first_pcm_write_ms"
        case shortcutToRecordingReadyMs = "shortcut_to_recording_ready_ms"
        case targetCaptureMs = "target_capture_ms"
        case configLoadMs = "config_load_ms"
        case microphonePermissionMs = "microphone_permission_ms"
        case compatibilityMs = "compatibility_ms"
        case audioStartMs = "audio_start_ms"
        case audioFilePreparationMs = "audio_file_preparation_ms"
        case audioDeviceResolutionMs = "audio_device_resolution_ms"
        case audioInputInitializationMs = "audio_input_initialization_ms"
        case audioInputStartMs = "audio_input_start_ms"
        case streamReadyMs = "stream_ready_ms"
        case outcome
    }
}

actor StartupMetricsStore {
    private struct State: Codable, Equatable {
        var version = 1
        var samples: [StartupMetricSample]
    }

    private static let maximumBytes = 1_048_576
    private let url: URL
    private let maximumBytes: Int

    init(url: URL? = nil, maximumBytes: Int = StartupMetricsStore.maximumBytes) {
        self.maximumBytes = maximumBytes
        if let url {
            self.url = url
        } else {
#if DEBUG
            if let path = ProcessInfo.processInfo.environment["SAYALL_TEST_STARTUP_METRICS_PATH"],
               path.hasPrefix("/") {
                self.url = URL(fileURLWithPath: path)
                return
            }
#endif
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = support.appendingPathComponent("SayAll/startup-metrics-v1.json")
        }
    }

    func record(_ sample: StartupMetricSample, enabled: Bool, limit: Int) {
        guard enabled else { return }
        guard limit > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        var state = load() ?? State(samples: [])
        if state.version != 1 { state = State(samples: []) }
        state.samples.append(sample)
        if state.samples.count > limit {
            state.samples.removeFirst(state.samples.count - limit)
        }
        let encoder = JSONEncoder()
        var data: Data
        while true {
            guard let encoded = try? encoder.encode(state) else { return }
            if encoded.count <= maximumBytes {
                data = encoded
                break
            }
            guard state.samples.count > 1 else { return }
            state.samples.removeFirst()
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Metrics are best-effort and must never prevent dictation.
        }
    }

    func samplesForTesting() -> [StartupMetricSample] { load()?.samples ?? [] }

    private func load() -> State? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.version == 1 else { return nil }
        return state
    }
}

struct PipelineMetricSample: Codable, Equatable {
    let correlationID: String
    let deepgramConnectMs: Int?
    let deepgramStopToFinalMs: Int?
    let restSTTMs: Int?
    let deterministicProcessingMs: Int?
    let plannerMs: Int?
    let processingTotalMs: Int?
    let helperFinishMs: Int
    let deliveryMs: Int?
    let stopToDeliveredMs: Int?
    let outcome: String
    let profile: ProcessingProfile
    let transport: HelperResult.Transport?

    enum CodingKeys: String, CodingKey {
        case correlationID = "correlation_id"
        case deepgramConnectMs = "deepgram_connect_ms"
        case deepgramStopToFinalMs = "deepgram_stop_to_final_ms"
        case restSTTMs = "rest_stt_ms"
        case deterministicProcessingMs = "deterministic_processing_ms"
        case plannerMs = "planner_ms"
        case processingTotalMs = "processing_total_ms"
        case helperFinishMs = "helper_finish_ms"
        case deliveryMs = "delivery_ms"
        case stopToDeliveredMs = "stop_to_delivered_ms"
        case outcome, profile, transport
    }
}

actor PipelineMetricsStore {
    private struct State: Codable { var version = 1; var samples: [PipelineMetricSample] }
    private static let maximumBytes = 1_048_576
    private let url: URL
    private let maximumBytes: Int

    init(url: URL? = nil, maximumBytes: Int = PipelineMetricsStore.maximumBytes) {
        self.maximumBytes = maximumBytes
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
#if DEBUG
        if url == nil,
           let path = ProcessInfo.processInfo.environment["SAYALL_TEST_PIPELINE_METRICS_PATH"],
           path.hasPrefix("/") {
            self.url = URL(fileURLWithPath: path)
            return
        }
#endif
        self.url = url ?? support.appendingPathComponent("SayAll/pipeline-metrics-v1.json")
    }

    func record(_ sample: PipelineMetricSample, enabled: Bool, limit: Int) {
        guard enabled else { return }
        guard limit > 0 else { try? FileManager.default.removeItem(at: url); return }
        var state = load() ?? State(samples: [])
        state.samples.append(sample)
        if state.samples.count > limit { state.samples.removeFirst(state.samples.count - limit) }
        var data: Data
        while true {
            guard let encoded = try? JSONEncoder().encode(state) else { return }
            if encoded.count <= maximumBytes { data = encoded; break }
            guard state.samples.count > 1 else { return }
            state.samples.removeFirst()
        }
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Metrics must never affect dictation. */ }
    }

    func samplesForTesting() -> [PipelineMetricSample] { load()?.samples ?? [] }
    private func load() -> State? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes,
              let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1 else { return nil }
        return state
    }
}
