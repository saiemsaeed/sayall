import AVFoundation
import Darwin
import Foundation

final class AudioCapture {
    enum CaptureError: Error { case format, tooShort, tooLong }
    struct Recording {
        let directoryURL: URL
        let wavURL: URL
        let pcmURL: URL
        let streamSourceFailed: Bool
    }
    private static let sampleRate = 16_000.0
    private static let minimumFrames: AVAudioFramePosition = 4_800
    private static let maximumFrames: AVAudioFramePosition = 4_800_000
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var pcmFile: FileHandle?
    private var directoryURL: URL?
    private var wavURL: URL?
    private var pcmURL: URL?
    private var tapInstalled = false
    private var framesWritten: AVAudioFramePosition = 0
    private var captureFailed = false
    private var streamSourceFailed = false
    var levelHandler: ((Double) -> Void)?
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
        do {
            guard let canonical = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate, channels: 1, interleaved: true) else {
                throw CaptureError.format
            }
            file = try AVAudioFile(forWriting: wavURL, settings: canonical.settings, commonFormat: .pcmFormatInt16, interleaved: true)
            let input = engine.inputNode, source = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: source, to: canonical) else { throw CaptureError.format }
            input.installTap(onBus: 0, bufferSize: 4096, format: source) { [weak self] buffer, _ in
                guard let self else { return }
                let ratio = canonical.sampleRate / source.sampleRate
                guard let output = AVAudioPCMBuffer(pcmFormat: canonical,
                    frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1) else {
                    self.markCaptureFailed(); return
                }
                var supplied = false
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return buffer
                }
                guard error == nil, status != .error else { self.markCaptureFailed(); return }
                self.write(output)
            }
            tapInstalled = true
            engine.prepare(); try engine.start()
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
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        engine.stop()
        lock.lock()
        file = nil
        try? pcmFile?.synchronize()
        try? pcmFile?.close()
        pcmFile = nil
        let directory = directoryURL
        lock.unlock()
        if deleteFile, let directory { try? FileManager.default.removeItem(at: directory) }
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
