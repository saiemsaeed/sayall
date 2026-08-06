import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization

final class AudioInputDeviceMonitor {
    private let queue = DispatchQueue(label: "pro.leets.sayall.audio-device-monitor")
    private let listener: AudioObjectPropertyListenerBlock
    private var addresses: [AudioObjectPropertyAddress] = []

    init(changed: @escaping @Sendable () -> Void) {
        listener = { _, _ in changed() }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            ) == noErr {
                addresses.append(address)
            }
        }
    }

    deinit {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
            )
        }
    }
}

/// Input-only AUHAL. The render thread only renders into preallocated storage and publishes a slot.
final class AUHALInput {
    enum Failure: Error { case unavailable, format, audioUnit(OSStatus) }

    private static let slots = 16
    private let unit: AudioUnit
    let sampleRate: Double
    let channelCount: Int
    private let capacity: Int
    private var storage: [UnsafeMutablePointer<Float>] = []
    private var bufferLists: [UnsafeMutableAudioBufferListPointer] = []
    private var lengths = [Int](repeating: 0, count: slots)
    private let produced = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let running = Atomic<Bool>(false)
    private let healthArmed = Atomic<Bool>(false)
    private let renderFailed = Atomic<Bool>(false)
    private let callbacksInFlight = Atomic<Int>(0)
    private let disposed = Atomic<Bool>(false)
    private let queue = DispatchQueue(label: "pro.leets.sayall.auhal-processing", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var lastObservedWrite = 0
    private var stalledPolls = 0
    private var failureDelivered = false
    var framesHandler: ((UnsafePointer<Float>, Int, Int, Int, Double) -> Void)?
    var failureHandler: (() -> Void)?

    init(deviceID: AudioDeviceID, maximumFrames: UInt32 = 8_192) throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure.unavailable }
        var maybeUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &maybeUnit))
        guard let created = maybeUnit else { throw Failure.unavailable }
        unit = created
        var unitMaximumFrames = maximumFrames
        var maximumFramesSize = UInt32(MemoryLayout.size(ofValue: unitMaximumFrames))
        if AudioUnitGetProperty(
            created,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &unitMaximumFrames,
            &maximumFramesSize
        ) != noErr {
            unitMaximumFrames = maximumFrames
        }
        capacity = Int(max(maximumFrames, unitMaximumFrames))
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: hardware))
        do {
            var one: UInt32 = 1
            var zero: UInt32 = 0
            try Self.set(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one)
            try Self.set(created, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero)
            var device = deviceID
            try Self.set(created, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device)
            try Self.check(AudioUnitGetProperty(created, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 1, &hardware, &size))
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else { throw Failure.format }
            sampleRate = hardware.mSampleRate
            channelCount = Int(hardware.mChannelsPerFrame)
            var client = AudioStreamBasicDescription(mSampleRate: hardware.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: hardware.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
            try Self.set(created, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client)
            storage = (0..<Self.slots).map { _ in .allocate(capacity: capacity * Int(hardware.mChannelsPerFrame)) }
            bufferLists = (0..<Self.slots).map { slot in
                let list = AudioBufferList.allocate(maximumBuffers: Int(hardware.mChannelsPerFrame))
                for channel in 0..<Int(hardware.mChannelsPerFrame) {
                    list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity) * 4,
                        mData: storage[slot].advanced(by: channel * capacity))
                }
                return list
            }
            var callback = AURenderCallbackStruct(inputProc: AUHALInput.render,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try Self.set(created, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback)
            try Self.check(AudioUnitInitialize(created))
        } catch {
            AudioComponentInstanceDispose(created)
            bufferLists.forEach { free($0.unsafeMutablePointer) }
            bufferLists.removeAll()
            storage.forEach { $0.deallocate() }
            storage.removeAll()
            throw error
        }
    }

    deinit {
        if stop() {
            bufferLists.forEach { free($0.unsafeMutablePointer) }
            storage.forEach { $0.deallocate() }
        }
    }

    func start() throws {
        renderFailed.store(false, ordering: .relaxed)
        lastObservedWrite = 0
        stalledPolls = 0
        failureDelivered = false
        running.store(true, ordering: .releasing)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in
            self?.drain()
            self?.checkHealth()
        }
        timer = source
        source.resume()
        do {
            try Self.check(AudioOutputUnitStart(unit))
            healthArmed.store(true, ordering: .releasing)
        }
        catch { stop(); throw error }
    }

    @discardableResult
    func stop() -> Bool {
        healthArmed.store(false, ordering: .releasing)
        let wasRunning = running.exchange(false, ordering: .acquiringAndReleasing)
        if wasRunning { AudioOutputUnitStop(unit) }
        if !disposed.exchange(true, ordering: .acquiringAndReleasing) {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        var attempts = 0
        while callbacksInFlight.load(ordering: .acquiring) != 0, attempts < 2_000 {
            usleep(1_000)
            attempts += 1
        }
        let quiesced = callbacksInFlight.load(ordering: .acquiring) == 0
        timer?.cancel()
        timer = nil
        queue.sync { drain() }
        return quiesced
    }

    private func drain() {
        while true {
            let read = consumed.load(ordering: .relaxed)
            let write = produced.load(ordering: .acquiring)
            guard read < write else { return }
            let slot = read % Self.slots
            let frames = lengths[slot]
            if frames > 0 { framesHandler?(UnsafePointer(storage[slot]), frames, channelCount, capacity, sampleRate) }
            consumed.store(read + 1, ordering: .releasing)
        }
    }

    private func checkHealth() {
        guard running.load(ordering: .acquiring), healthArmed.load(ordering: .acquiring), !failureDelivered else {
            return
        }
        let write = produced.load(ordering: .acquiring)
        if write != lastObservedWrite {
            lastObservedWrite = write
            stalledPolls = 0
        } else {
            stalledPolls += 1
        }
        guard renderFailed.load(ordering: .acquiring) || stalledPolls >= 200 else { return }
        failureDelivered = true
        failureHandler?()
    }

    private static let render: AURenderCallback = { ref, flags, time, bus, frames, _ in
        let capture = Unmanaged<AUHALInput>.fromOpaque(ref).takeUnretainedValue()
        _ = capture.callbacksInFlight.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer { _ = capture.callbacksInFlight.wrappingSubtract(1, ordering: .acquiringAndReleasing) }
        guard capture.running.load(ordering: .acquiring) else { return noErr }
        guard Int(frames) <= capture.capacity else {
            capture.renderFailed.store(true, ordering: .releasing)
            return kAudio_ParamError
        }
        let write = capture.produced.load(ordering: .relaxed)
        guard write - capture.consumed.load(ordering: .acquiring) < slots else {
            capture.renderFailed.store(true, ordering: .releasing)
            return noErr
        }
        let slot = write % slots
        let abl = capture.bufferLists[slot]
        for channel in 0..<capture.channelCount { abl[channel].mDataByteSize = frames * 4 }
        let status = AudioUnitRender(capture.unit, flags, time, 1, frames, abl.unsafeMutablePointer)
        if status == noErr {
            capture.lengths[slot] = Int(frames)
            capture.produced.store(write + 1, ordering: .releasing)
        } else {
            capture.renderFailed.store(true, ordering: .releasing)
        }
        return status
    }

    private static func check(_ status: OSStatus) throws { if status != noErr { throw Failure.audioUnit(status) } }
    private static func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
        _ element: AudioUnitElement, _ value: inout T) throws {
        let status = withUnsafeBytes(of: &value) { bytes in
            AudioUnitSetProperty(unit, property, scope, element, bytes.baseAddress, UInt32(bytes.count))
        }
        try check(status)
    }
}
