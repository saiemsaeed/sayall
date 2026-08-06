import AVFoundation
import CoreMedia
import Darwin
import Foundation

struct AudioInputDeviceInfo: Equatable {
    let uniqueID: String
    let name: String
    let isDefault: Bool
}

enum AudioInputDevices {
    static func available() -> [AudioInputDeviceInfo] {
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return captureDevices().map {
            AudioInputDeviceInfo(uniqueID: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }.sorted {
            if $0.isDefault != $1.isDefault { return $0.isDefault }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func selectedDevice(uniqueID: String?) throws -> AVCaptureDevice {
        if let uniqueID {
            guard let device = captureDevices().first(where: { $0.uniqueID == uniqueID }) else {
                throw AudioCapture.CaptureError.deviceUnavailable
            }
            return device
        }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw AudioCapture.CaptureError.deviceUnavailable
        }
        return device
    }

    private static func captureDevices() -> [AVCaptureDevice] {
        var devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone], mediaType: .audio, position: .unspecified
        ).devices
        if let systemDefault = AVCaptureDevice.default(for: .audio),
           !devices.contains(where: { $0.uniqueID == systemDefault.uniqueID }) {
            devices.append(systemDefault)
        }
        return devices
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

final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
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
    private let captureQueue = DispatchQueue(label: "pro.leets.sayall.audio-capture", qos: .userInitiated)
    private let resampler = AudioResampler()
    private var session: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var sessionObservers: [NSObjectProtocol] = []
    private var captureGeneration: UUID?
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
            let device = try AudioInputDevices.selectedDevice(uniqueID: MicrophoneSelection.uniqueID)
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: true,
            ]
            output.setSampleBufferDelegate(self, queue: captureQueue)
            let session = AVCaptureSession()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else { throw CaptureError.format }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            self.session = session
            audioOutput = output
            let generation = UUID()
            captureGeneration = generation
            observe(session: session, device: device, generation: generation)
            session.startRunning()
            guard session.isRunning else { throw CaptureError.format }
            return Recording(directoryURL: directory, wavURL: wavURL, pcmURL: pcmURL, streamSourceFailed: false)
        } catch {
            cleanup(deleteFile: true)
            throw error
        }
    }

    func stop() throws -> Recording {
        guard let directoryURL, let wavURL, let pcmURL else { throw CaptureError.format }
        if session?.isRunning == false { markCaptureFailed() }
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
        removeSessionObservers()
        let activeSession = session
        activeSession?.stopRunning()
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        captureQueue.sync { resampler.reset() }
        lock.lock()
        file = nil
        try? pcmFile?.synchronize()
        try? pcmFile?.close()
        pcmFile = nil
        let directory = directoryURL
        lock.unlock()
        audioOutput = nil
        session = nil
        lock.withLock { captureGeneration = nil }
        if deleteFile, let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func observe(session: AVCaptureSession, device: AVCaptureDevice, generation: UUID) {
        let center = NotificationCenter.default
        for name in [
            AVCaptureSession.runtimeErrorNotification,
            AVCaptureSession.wasInterruptedNotification,
            AVCaptureSession.didStopRunningNotification,
        ] {
            sessionObservers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.markUnexpectedFailure(generation: generation)
            })
        }
        sessionObservers.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: device,
            queue: nil
        ) { [weak self] _ in
            self?.markUnexpectedFailure(generation: generation)
        })
    }

    private func removeSessionObservers() {
        let center = NotificationCenter.default
        sessionObservers.forEach(center.removeObserver)
        sessionObservers.removeAll()
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let source = Self.copyPCMBuffer(from: sampleBuffer),
              let monoInput = Self.activeChannelMonoBuffer(from: source),
              let converted = resampler.convert(monoInput) else {
            markCaptureFailed()
            return
        }
        write(converted)
    }

    private static func copyPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription),
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return nil }
        var requiredSize = 0
        var blockBuffer: CMBlockBuffer?
        let flags = kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: flags,
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: 16)
        defer { memory.deallocate() }
        let bufferList = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: flags,
            blockBufferOut: &blockBuffer
        ) == noErr else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        copy.frameLength = frameCount
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }
        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData,
                  source.mDataByteSize <= destinationBuffers[index].mDataByteSize else { return nil }
            memcpy(destinationData, sourceData, Int(source.mDataByteSize))
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
        }
        return copy
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

    static func activeChannelMonoBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.frameLength > 0,
              let channels = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1,
                interleaved: false
              ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?[0] else { return nil }
        var selectedChannel = 0
        var selectedEnergy = -1.0
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
        mono.frameLength = buffer.frameLength
        destination.update(from: channels[selectedChannel], count: Int(buffer.frameLength))
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
