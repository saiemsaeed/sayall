import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

struct AudioInputDeviceInfo: Equatable {
    let uniqueID: String
    let name: String
    let isDefault: Bool
}

enum AudioInputDevices {
    static func available() -> [AudioInputDeviceInfo] {
        let defaultID = defaultDeviceID()
        return deviceIDs().compactMap { deviceID in
            guard isEligible(deviceID),
                  let uniqueID = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDeviceInfo(uniqueID: uniqueID, name: name, isDefault: deviceID == defaultID)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func selectedDeviceID(uniqueID: String?) throws -> AudioDeviceID {
        if let uniqueID {
            var uid: CFString = uniqueID as CFString
            var deviceID = kAudioObjectUnknown
            let qualifierSize = UInt32(MemoryLayout<CFString>.size)
            var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let status = withUnsafePointer(to: &uid) { qualifier in
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                    qualifierSize, qualifier, &dataSize, &deviceID)
            }
            guard status == noErr, deviceID != kAudioObjectUnknown, isEligible(deviceID) else {
                throw AudioCapture.CaptureError.deviceUnavailable
            }
            return deviceID
        }
        guard let deviceID = defaultDeviceID(), isEligible(deviceID) else {
            throw AudioCapture.CaptureError.deviceUnavailable
        }
        return deviceID
    }

    private static func defaultDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout.size(ofValue: deviceID))
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices
        ) == noErr else { return [] }
        return devices
    }

    private static func isEligible(_ deviceID: AudioDeviceID) -> Bool {
        guard let alive = uintProperty(
                deviceID, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal
              ), alive != 0,
              let hidden = uintProperty(
                deviceID, selector: kAudioDevicePropertyIsHidden, scope: kAudioObjectPropertyScopeGlobal
              ), hidden == 0,
              let canBeDefault = uintProperty(
                deviceID,
                selector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
                scope: kAudioDevicePropertyScopeInput
              ), canBeDefault != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, memory) == noErr else { return false }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .contains { $0.mNumberChannels > 0 }
    }

    private static func uintProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

enum MicrophoneSelection {
    private static let key = "microphone.unique-id"
    static var uniqueID: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

final class AudioCapture {
    enum CaptureError: Error { case format, deviceUnavailable, tooShort, tooLong }
#if DEBUG
    private static let maximumFixtureBytes: off_t = 100 * 1_024 * 1_024
    private static let fixtureChunkDuration = 0.02

    static func debugFixtureConfigured(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["SAYALL_TEST_AUDIO_FIXTURE"].map { !$0.isEmpty } ?? false
    }

    static func debugFixtureURL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL? {
        guard let path = environment["SAYALL_TEST_AUDIO_FIXTURE"], !path.isEmpty else { return nil }
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CaptureError.format }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 12, info.st_size <= maximumFixtureBytes else { throw CaptureError.format }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CaptureError.format }
        defer { Darwin.close(descriptor) }
        var header = [UInt8](repeating: 0, count: 12)
        guard Darwin.read(descriptor, &header, header.count) == header.count,
              Array(header[0..<4]) == Array("RIFF".utf8),
              Array(header[8..<12]) == Array("WAVE".utf8) else { throw CaptureError.format }
        return URL(fileURLWithPath: path)
    }

    static func debugRecordingRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard debugFixtureConfigured(environment: environment),
              let path = environment["SAYALL_TEST_RECORDING_ROOT"], path.hasPrefix("/"),
              !path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 3,
              !components.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let parent = url.deletingLastPathComponent()
        guard url.lastPathComponent == "recordings",
              parent.lastPathComponent.hasPrefix("sayall-acoustic-e2e-"),
              parent.deletingLastPathComponent().path == "/tmp" else { return nil }
        return url
    }
#endif
    final class AudioResampler {
        private var sourceFormat: AVAudioFormat?
        private var converter: AVAudioConverter?
        private(set) var converterGeneration = 0

        func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let canonical = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: AudioCapture.sampleRate,
                channels: 1,
                interleaved: true
            ) else { return nil }
            if sourceFormat?.isEqual(input.format) != true {
                sourceFormat = input.format
                converter = AVAudioConverter(from: input.format, to: canonical)
                converterGeneration += 1
            }
            guard let converter else { return nil }
            let ratio = canonical.sampleRate / input.format.sampleRate
            guard let output = AVAudioPCMBuffer(
                pcmFormat: canonical,
                frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
            ) else { return nil }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, status != .error else { return nil }
            return output
        }

        func reset() {
            sourceFormat = nil
            converter = nil
        }
    }

    struct Recording {
        let directoryURL: URL
        let wavURL: URL
        let pcmURL: URL
        let streamSourceFailed: Bool
        let startTiming: StartTiming?
        let captureGeneration: UUID?
    }
    struct StartTiming {
        let filePreparationMs: Int
        let deviceResolutionMs: Int
        let inputInitializationMs: Int
        let inputStartMs: Int
    }
    private static let sampleRate = 16_000.0
    private static let minimumFrames: AVAudioFramePosition = 4_800
    private static let maximumFrames: AVAudioFramePosition = 4_800_000
    private let resampler = AudioResampler()
    private var inputUnit: AUHALInput?
#if DEBUG
    private var fixtureTimer: DispatchSourceTimer?
    private var fixtureFile: AVAudioFile?
    private let fixtureQueueKey = DispatchSpecificKey<Void>()
    private lazy var fixtureQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "pro.leets.sayall.audio-fixture")
        queue.setSpecific(key: fixtureQueueKey, value: ())
        return queue
    }()
#endif
    private var captureGeneration: UUID?
    private var selectedChannel = 0
    private var channelCandidate = 0
    private var candidateWins = 0
    private var intentionalTeardown = false
    private var failureReported = false
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var pcmFile: FileHandle?
    private var directoryURL: URL?
    private var wavURL: URL?
    private var pcmURL: URL?
    private var framesWritten: AVAudioFramePosition = 0
    private var firstPCMWriteUptimeNanoseconds: UInt64?
    private var captureFailed = false
    private var streamSourceFailed = false
    var levelHandler: ((Double) -> Void)?
    var failureHandler: (() -> Void)?
    var firstPCMWriteHandler: ((UUID, UInt64) -> Void)?
    private static var root: URL {
#if DEBUG
        if let override = debugRecordingRoot() { return override }
#endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SayAll/Recordings", isDirectory: true)
    }

    static func removeStaleFiles() {
#if DEBUG
        if debugFixtureConfigured() { return }
#endif
        try? FileManager.default.removeItem(at: root)
    }

    func start() throws -> Recording {
#if DEBUG
        if Self.debugFixtureConfigured(), Self.debugRecordingRoot() == nil { throw CaptureError.format }
#endif
        var phaseStarted = DispatchTime.now().uptimeNanoseconds
        Self.removeStaleFiles()
        try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let directory = Self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let wavURL = directory.appendingPathComponent("audio.wav")
        let pcmURL = directory.appendingPathComponent("audio.pcm")
        let wavDescriptor = Darwin.open(wavURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard wavDescriptor >= 0 else { throw CaptureError.format }
        Darwin.close(wavDescriptor)
        let pcmDescriptor = Darwin.open(pcmURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard pcmDescriptor >= 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw CaptureError.format
        }
        directoryURL = directory
        self.wavURL = wavURL
        self.pcmURL = pcmURL
        pcmFile = FileHandle(fileDescriptor: pcmDescriptor, closeOnDealloc: true)
        framesWritten = 0
        firstPCMWriteUptimeNanoseconds = nil
        captureFailed = false
        streamSourceFailed = false
        failureReported = false
        intentionalTeardown = false
        do {
            guard let canonical = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true) else {
                throw CaptureError.format
            }
            file = try AVAudioFile(forWriting: wavURL, settings: canonical.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let filePreparationMs = Self.elapsedMilliseconds(since: phaseStarted)
#if DEBUG
            if let fixtureURL = try Self.debugFixtureURL() {
                let generation = UUID()
                captureGeneration = generation
                try startFixture(url: fixtureURL, generation: generation)
                return Recording(directoryURL: directory, wavURL: wavURL, pcmURL: pcmURL,
                    streamSourceFailed: false,
                    startTiming: StartTiming(filePreparationMs: filePreparationMs, deviceResolutionMs: 0,
                        inputInitializationMs: 0, inputStartMs: 0), captureGeneration: generation)
            }
#endif
            phaseStarted = DispatchTime.now().uptimeNanoseconds
            let deviceID = try AudioInputDevices.selectedDeviceID(uniqueID: MicrophoneSelection.uniqueID)
            let deviceResolutionMs = Self.elapsedMilliseconds(since: phaseStarted)
            phaseStarted = DispatchTime.now().uptimeNanoseconds
            let inputUnit: AUHALInput
            do { inputUnit = try AUHALInput(deviceID: deviceID) }
            catch AUHALInput.Failure.unavailable { throw CaptureError.deviceUnavailable }
            catch { throw CaptureError.format }
            let inputInitializationMs = Self.elapsedMilliseconds(since: phaseStarted)
            self.inputUnit = inputUnit
            let generation = UUID()
            captureGeneration = generation
            inputUnit.framesHandler = { [weak self] samples, frames, channels, frameStride, rate in
                guard let self,
                      let monoInput = self.monoBuffer(
                        samples: samples, frames: frames, channels: channels, frameStride: frameStride, rate: rate
                      ),
                      let converted = self.resampler.convert(monoInput) else {
                    self?.markCaptureFailed()
                    return
                }
                self.write(converted)
            }
            inputUnit.failureHandler = { [weak self] in self?.markUnexpectedFailure(generation: generation) }
            phaseStarted = DispatchTime.now().uptimeNanoseconds
            try inputUnit.start()
            let timing = StartTiming(
                filePreparationMs: filePreparationMs,
                deviceResolutionMs: deviceResolutionMs,
                inputInitializationMs: inputInitializationMs,
                inputStartMs: Self.elapsedMilliseconds(since: phaseStarted)
            )
            return Recording(directoryURL: directory, wavURL: wavURL, pcmURL: pcmURL,
                streamSourceFailed: false, startTiming: timing, captureGeneration: generation)
        } catch {
            cleanup(deleteFile: true)
            throw error
        }
    }

    func stop() throws -> Recording {
        guard let directoryURL, let wavURL, let pcmURL else { throw CaptureError.format }
        cleanup(deleteFile: false)
        lock.lock()
        let frames = framesWritten
        let failed = captureFailed
        let streamFailed = streamSourceFailed
        self.directoryURL = nil; self.wavURL = nil; self.pcmURL = nil; framesWritten = 0
        lock.unlock()
        do { try Self.validateCapture(frames: frames, failed: failed) }
        catch { try? FileManager.default.removeItem(at: directoryURL); throw error }
        return Recording(directoryURL: directoryURL, wavURL: wavURL, pcmURL: pcmURL,
            streamSourceFailed: streamFailed, startTiming: nil, captureGeneration: nil)
    }

    static func validateCapture(frames: AVAudioFramePosition, failed: Bool) throws {
        if failed { throw CaptureError.format }
        if frames < minimumFrames { throw CaptureError.tooShort }
        if frames > maximumFrames { throw CaptureError.tooLong }
    }

    func cancel() {
        cleanup(deleteFile: true)
        lock.lock()
        directoryURL = nil; wavURL = nil; pcmURL = nil; framesWritten = 0; firstPCMWriteUptimeNanoseconds = nil
        lock.unlock()
    }

    private func cleanup(deleteFile: Bool) {
        lock.withLock { intentionalTeardown = true }
#if DEBUG
        fixtureTimer?.cancel()
        fixtureTimer = nil
        if DispatchQueue.getSpecific(key: fixtureQueueKey) != nil { fixtureFile = nil }
        else { fixtureQueue.sync { fixtureFile = nil } }
#endif
        let activeInput = inputUnit
        activeInput?.stop()
        resampler.reset()
        lock.lock()
        file = nil
        try? pcmFile?.synchronize()
        try? pcmFile?.close()
        pcmFile = nil
        let directory = directoryURL
        lock.unlock()
        inputUnit = nil
        lock.withLock { captureGeneration = nil }
        if deleteFile, let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func markUnexpectedFailure(generation: UUID) {
        let shouldReport = lock.withLock { () -> Bool in
            guard captureGeneration == generation, !intentionalTeardown else { return false }
            captureFailed = true
            guard !failureReported else { return false }
            failureReported = true
            return true
        }
        if shouldReport { failureHandler?() }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        var firstWrite: (UUID, UInt64)?
        lock.lock()
        guard let file, framesWritten < Self.maximumFrames else { lock.unlock(); return }
        let remaining = Self.maximumFrames - framesWritten
        if AVAudioFramePosition(buffer.frameLength) > remaining { buffer.frameLength = AVAudioFrameCount(remaining) }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            captureFailed = true
        }
        if let pcmFile, let samples = buffer.int16ChannelData?[0] {
            do {
                try pcmFile.write(contentsOf: Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size))
                if firstPCMWriteUptimeNanoseconds == nil, let generation = captureGeneration {
                    let timestamp = DispatchTime.now().uptimeNanoseconds
                    firstPCMWriteUptimeNanoseconds = timestamp
                    firstWrite = (generation, timestamp)
                }
            }
            catch { streamSourceFailed = true }
        } else {
            streamSourceFailed = true
        }
        lock.unlock()
        if let firstWrite { firstPCMWriteHandler?(firstWrite.0, firstWrite.1) }
        reportLevel(buffer)
    }

    private func markCaptureFailed() {
        lock.withLock { captureFailed = true }
    }

#if DEBUG
    private func startFixture(url: URL, generation: UUID) throws {
        let source = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        guard source.length > 0,
              source.processingFormat.sampleRate == Self.sampleRate,
              source.processingFormat.channelCount == 1,
              Double(source.length) / source.processingFormat.sampleRate <= Double(Self.maximumFrames) / Self.sampleRate
        else {
            throw CaptureError.format
        }
        let chunkFrames = AVAudioFrameCount(max(1,
            (source.processingFormat.sampleRate * Self.fixtureChunkDuration).rounded()))
        fixtureFile = source
        let timer = DispatchSource.makeTimerSource(queue: fixtureQueue)
        fixtureTimer = timer
        timer.schedule(deadline: .now() + Self.fixtureChunkDuration,
            repeating: Self.fixtureChunkDuration, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let source = self.fixtureFile else { timer?.cancel(); return }
            let remaining = source.length - source.framePosition
            guard remaining > 0 else { timer?.cancel(); return }
            let requestedFrames = min(chunkFrames, AVAudioFrameCount(remaining))
            guard let input = AVAudioPCMBuffer(
                pcmFormat: source.processingFormat, frameCapacity: requestedFrames
            ) else { self.markUnexpectedFailure(generation: generation); timer?.cancel(); return }
            do { try source.read(into: input, frameCount: requestedFrames) }
            catch { self.markUnexpectedFailure(generation: generation); timer?.cancel(); return }
            guard input.frameLength > 0 else { timer?.cancel(); return }
            self.write(input)
        }
        timer.resume()
    }
#endif

    private static func elapsedMilliseconds(since started: UInt64) -> Int {
        let finished = DispatchTime.now().uptimeNanoseconds
        return Int((finished >= started ? finished - started : 0) / 1_000_000)
    }

    private func monoBuffer(
        samples: UnsafePointer<Float>, frames: Int, channels: Int, frameStride: Int, rate: Double
    ) -> AVAudioPCMBuffer? {
        guard frames > 0, channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData?[0] else { return nil }
        var energies = [Double](repeating: 0, count: channels)
        for channel in 0..<channels {
            let source = samples.advanced(by: channel * frameStride)
            for frame in stride(from: 0, to: frames, by: 4) { energies[channel] += Double(source[frame] * source[frame]) }
        }
        let winner = energies.indices.max(by: { energies[$0] < energies[$1] }) ?? 0
        if selectedChannel >= channels { selectedChannel = winner }
        if winner != selectedChannel && energies[winner] > energies[selectedChannel] * 1.8 {
            if channelCandidate == winner { candidateWins += 1 } else { channelCandidate = winner; candidateWins = 1 }
            if candidateWins >= 4 { selectedChannel = winner; candidateWins = 0 }
        } else { candidateWins = 0 }
        destination.update(from: samples.advanced(by: selectedChannel * frameStride), count: frames)
        output.frameLength = AVAudioFrameCount(frames)
        return output
    }

    static func activeChannelMonoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let monoFormat = AVAudioFormat(
                commonFormat: buffer.format.commonFormat,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return nil }
        var selectedChannel = 0
        var selectedEnergy = -1.0
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let destination = mono.floatChannelData?[0] else { return nil }
            if buffer.format.isInterleaved {
                guard let samples = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first?.mData?
                    .assumingMemoryBound(to: Float.self) else { return nil }
                let channelCount = Int(buffer.format.channelCount)
                for channel in 0..<channelCount {
                    var energy = 0.0
                    for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                        let sample = Double(samples[frame * channelCount + channel])
                        energy += sample * sample
                    }
                    if energy > selectedEnergy {
                        selectedChannel = channel
                        selectedEnergy = energy
                    }
                }
                for frame in 0..<Int(buffer.frameLength) {
                    destination[frame] = samples[frame * channelCount + selectedChannel]
                }
                break
            }
            guard let channels = buffer.floatChannelData else { return nil }
            for channel in 0..<Int(buffer.format.channelCount) {
                var energy = 0.0
                for index in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                    let sample = Double(channels[channel][index])
                    energy += sample * sample
                }
                if energy > selectedEnergy {
                    selectedChannel = channel
                    selectedEnergy = energy
                }
            }
            destination.update(from: channels[selectedChannel], count: Int(buffer.frameLength))
        case .pcmFormatInt16:
            guard let destination = mono.int16ChannelData?[0] else { return nil }
            if buffer.format.isInterleaved {
                guard let samples = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList).first?.mData?
                    .assumingMemoryBound(to: Int16.self) else { return nil }
                let channelCount = Int(buffer.format.channelCount)
                for channel in 0..<channelCount {
                    var energy = 0.0
                    for frame in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                        let sample = Double(samples[frame * channelCount + channel])
                        energy += sample * sample
                    }
                    if energy > selectedEnergy {
                        selectedChannel = channel
                        selectedEnergy = energy
                    }
                }
                for frame in 0..<Int(buffer.frameLength) {
                    destination[frame] = samples[frame * channelCount + selectedChannel]
                }
                break
            }
            guard let channels = buffer.int16ChannelData else { return nil }
            for channel in 0..<Int(buffer.format.channelCount) {
                var energy = 0.0
                for index in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
                    let sample = Double(channels[channel][index])
                    energy += sample * sample
                }
                if energy > selectedEnergy {
                    selectedChannel = channel
                    selectedEnergy = energy
                }
            }
            destination.update(from: channels[selectedChannel], count: Int(buffer.frameLength))
        default:
            return nil
        }
        mono.frameLength = buffer.frameLength
        return mono
    }

    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.int16ChannelData?[0], buffer.frameLength > 0 else { return }
        var sum = 0.0
        for index in stride(from: 0, to: Int(buffer.frameLength), by: 4) {
            let sample = Double(samples[index]) / Double(Int16.max)
            sum += sample * sample
        }
        let count = max(1, Int(buffer.frameLength) / 4)
        let rms = sqrt(sum / Double(count))
        let decibels = 20 * log10(max(rms, 0.000_01))
        levelHandler?(min(max((decibels + 55) / 55, 0), 1))
    }
}
