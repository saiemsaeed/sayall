import Darwin
import Foundation

struct StartupMetricSample: Codable, Equatable {
    let shortcutToHUDMs: Int?
    let shortcutToRecordingReadyMs: Int?
    let targetCaptureMs: Int
    let configLoadMs: Int
    let microphonePermissionMs: Int
    let compatibilityMs: Int
    let audioStartMs: Int
    let streamReadyMs: Int
    let outcome: String

    enum CodingKeys: String, CodingKey {
        case shortcutToHUDMs = "shortcut_to_hud_ms"
        case shortcutToRecordingReadyMs = "shortcut_to_recording_ready_ms"
        case targetCaptureMs = "target_capture_ms"
        case configLoadMs = "config_load_ms"
        case microphonePermissionMs = "microphone_permission_ms"
        case compatibilityMs = "compatibility_ms"
        case audioStartMs = "audio_start_ms"
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
