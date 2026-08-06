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
    }
    private static let sampleRate = 16_000.0
    private static let minimumFrames: AVAudioFramePosition = 4_800
    private static let maximumFrames: AVAudioFramePosition = 4_800_000
    private let resampler = AudioResampler()
    private var inputUnit: AUHALInput?
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
    private var captureFailed = false
    private var streamSourceFailed = false
    var levelHandler: ((Double) -> Void)?
    var failureHandler: (() -> Void)?
    private static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SayAll/Recordings", isDirectory: true)
    }()

    static func removeStaleFiles() {
        try? FileManager.default.removeItem(at: root)
    }

    func start() throws -> Recording {
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
        captureFailed = false
        streamSourceFailed = false
        failureReported = false
        intentionalTeardown = false
        do {
            guard let canonical = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true) else {
                throw CaptureError.format
            }
            file = try AVAudioFile(forWriting: wavURL, settings: canonical.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let deviceID = try AudioInputDevices.selectedDeviceID(uniqueID: MicrophoneSelection.uniqueID)
            let inputUnit: AUHALInput
            do { inputUnit = try AUHALInput(deviceID: deviceID) }
            catch AUHALInput.Failure.unavailable { throw CaptureError.deviceUnavailable }
            catch { throw CaptureError.format }
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
            try inputUnit.start()
            return Recording(directoryURL: directory, wavURL: wavURL, pcmURL: pcmURL, streamSourceFailed: false)
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
        return Recording(directoryURL: directoryURL, wavURL: wavURL, pcmURL: pcmURL, streamSourceFailed: streamFailed)
    }

    static func validateCapture(frames: AVAudioFramePosition, failed: Bool) throws {
        if failed { throw CaptureError.format }
        if frames < minimumFrames { throw CaptureError.tooShort }
        if frames > maximumFrames { throw CaptureError.tooLong }
    }

    func cancel() {
        cleanup(deleteFile: true)
        lock.lock()
        directoryURL = nil; wavURL = nil; pcmURL = nil; framesWritten = 0
        lock.unlock()
    }

    private func cleanup(deleteFile: Bool) {
        lock.withLock { intentionalTeardown = true }
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
            do { try pcmFile.write(contentsOf: Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)) }
            catch { streamSourceFailed = true }
        } else {
            streamSourceFailed = true
        }
        lock.unlock()
        reportLevel(buffer)
    }

    private func markCaptureFailed() {
        lock.withLock { captureFailed = true }
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
