@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Darwin
import Foundation

/// Reads the audio a system process plays with a Core Audio tap (macOS 14.2+), without muting it, and hands it on as 48 kHz stereo
/// `CMSampleBuffer`s stamped on the same host-time clock as the microphone.
///
/// Built for FaceTime: its call audio is played by the system helper `avconferenced`, not by the FaceTime app, and ScreenCaptureKit's
/// whole-Mac sound does not carry it, so both of those record the other person as digital silence. A tap on the helper does (measured on a
/// live call 2026-10-29: speech level on the process tap, identical on a whole-Mac tap).
final nonisolated class MeetingCallAudioTap: @unchecked Sendable {
    enum Source: Equatable, Sendable {
        /// The audio the helper at this path plays.
        case process(String)
        /// Everything the Mac plays except this app: the fallback when the helper has no audio object to tap.
        case wholeMac
    }

    enum TapError: LocalizedError {
        case noOutputDevice
        case coreAudio(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noOutputDevice:
                return "There is no output device to read the call audio from."
            case let .coreAudio(step, status):
                return "Call audio could not be read (\(step) failed, OSStatus \(status)). System audio recording may not be allowed for this app."
            }
        }
    }

    private struct Rig {
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        let outputUID: String
        let generation: UInt64
        let sampleRate: Double
        let source: Source
    }

    private static let canonicalSampleRate: Double = 48_000
    /// ~100 ms: the writer's pending budget is a few dozen buffers, and an IO cycle is ~10 ms.
    private static let windowFrames = 4800
    private static let stallSeconds: TimeInterval = 3
    /// A silence between two cycles longer than this is a pause, not jitter.
    private static let pauseNanos: UInt64 = 400_000_000

    // Fixed Float32 stereo PCM at 48 kHz is valid by construction.
    // swiftlint:disable:next force_unwrapping
    private static let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!

    private let helperPath: String
    private let forceWholeMac: Bool
    private let onSample: @Sendable (CMSampleBuffer, UInt64) -> Void
    private let ioQueue = DispatchQueue(label: "com.myos.meeting.callaudiotap", qos: .userInteractive)

    private let lock = NSLock()
    private var rig: Rig?
    private var running = false
    private var generation: UInt64 = 0
    private var lastBufferAt = Date()

    // Touched on `ioQueue` only (and reset by `reset()` on the same queue).
    private var resampler: AVAudioConverter?
    private var resamplerRate: Double = 0
    private var left: [Float] = []
    private var right: [Float] = []
    private var windowHostTime: UInt64?
    private var lastCallbackEndNanos: UInt64?
    private var clock = MeetingMicrophonePTSClock()

    /// `forceWholeMac` exists for diagnostic runs only (a stand-in app has no helper audio to tap).
    init(helperPath: String, forceWholeMac: Bool = false, onSample: @escaping @Sendable (CMSampleBuffer, UInt64) -> Void) {
        self.helperPath = helperPath
        self.forceWholeMac = forceWholeMac
        self.onSample = onSample
    }

    var currentSource: Source? { self.lock.withLock { self.rig?.source } }

    /// For the log: what the tap is reading and at which rate.
    var currentSampleRate: Double? { self.lock.withLock { self.rig?.sampleRate } }

    @discardableResult
    func start() throws -> Source {
        self.lock.withLock { self.running = true }
        do {
            return try self.install()
        } catch {
            self.lock.withLock { self.running = false }
            throw error
        }
    }

    func stop() {
        let old = self.lock.withLock { () -> Rig? in
            self.running = false
            defer { self.rig = nil }
            return self.rig
        }
        if let old { Self.teardown(old) }
        self.ioQueue.sync { self.reset() }
    }

    /// Called about once a second by the owner: rebuilds the tap when the output device changed (the aggregate is clocked by it) or the
    /// stream went quiet, and retries when an earlier rebuild failed. Returns the reason when it rebuilt.
    @discardableResult
    func restartIfNeeded() -> String? {
        let (running, rig, last) = self.lock.withLock { (self.running, self.rig, self.lastBufferAt) }
        guard running else { return nil }
        var reason: String?
        if let rig {
            if Self.defaultOutputUID() != rig.outputUID {
                reason = "the output device changed"
            } else if let rate = Self.nominalSampleRate(of: rig.aggregateID), abs(rate - rig.sampleRate) > 1 {
                reason = "the device sample rate changed from \(Int(rig.sampleRate)) to \(Int(rate)) Hz"
            } else if Date().timeIntervalSince(last) > Self.stallSeconds {
                reason = "no audio buffers for \(Int(Self.stallSeconds)) s"
            }
        } else {
            reason = "an earlier rebuild failed"
        }
        guard let reason else { return nil }
        if let rig {
            self.lock.withLock { self.rig = nil }
            Self.teardown(rig)
        }
        self.ioQueue.sync { self.reset() }
        do {
            try self.install()
            return reason
        } catch {
            return "\(reason); the rebuild failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Building

    @discardableResult
    private func install() throws -> Source {
        guard let outputUID = Self.defaultOutputUID() else { throw TapError.noOutputDevice }
        let generation = self.lock.withLock { () -> UInt64 in
            self.generation &+= 1
            return self.generation
        }

        let description: CATapDescription
        let source: Source
        let helperObjects = self.forceWholeMac ? [] : Self.processObjects { $0.path == self.helperPath }
        if helperObjects.isEmpty {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.processObjects { $0.pid == getpid() })
            source = .wholeMac
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: helperObjects)
            source = .process(self.helperPath)
        }
        description.name = "myOS call audio"
        description.isPrivate = true
        // Never take the call's sound away from the speakers.
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw TapError.coreAudio("creating the tap", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "myOS call audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.coreAudio("creating the aggregate device", status)
        }

        // The IO cycles arrive at the aggregate device's clock (the output device's, which voice processing can change), NOT at the 48 kHz the tap
        // reports for itself: measured 44.1 kHz on the speakers and about twice that while this process ran voice processing, where the tap's
        // audio comes upsampled by repetition. Labelling it 48 kHz stretched the audio and its timeline.
        let sampleRate = Self.nominalSampleRate(of: aggregateID) ?? Self.canonicalSampleRate

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, self.ioQueue) { [weak self] _, input, inputTime, _, _ in
            self?.handle(input, time: inputTime, generation: generation, sampleRate: sampleRate)
        }
        guard status == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.coreAudio("creating the IO proc", status)
        }
        let rig = Rig(
            tapID: tapID, aggregateID: aggregateID, procID: procID, outputUID: outputUID,
            generation: generation, sampleRate: sampleRate, source: source
        )
        self.lock.withLock { self.lastBufferAt = Date() }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            Self.teardown(rig)
            throw TapError.coreAudio("starting the tap", status)
        }
        let keep = self.lock.withLock { () -> Bool in
            guard self.running else { return false }
            self.rig = rig
            return true
        }
        if !keep { Self.teardown(rig) }
        return source
    }

    private static func teardown(_ rig: Rig) {
        AudioDeviceStop(rig.aggregateID, rig.procID)
        AudioDeviceDestroyIOProcID(rig.aggregateID, rig.procID)
        AudioHardwareDestroyAggregateDevice(rig.aggregateID)
        AudioHardwareDestroyProcessTap(rig.tapID)
    }

    // MARK: - Audio path (ioQueue)

    private func reset() {
        self.resampler = nil
        self.resamplerRate = 0
        self.left.removeAll(keepingCapacity: true)
        self.right.removeAll(keepingCapacity: true)
        self.windowHostTime = nil
        self.lastCallbackEndNanos = nil
        // A rebuild leaves a gap: anchor again so the writer sees it as one instead of a silently shortened track.
        self.clock = MeetingMicrophonePTSClock()
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        self.lock.withLock { self.running && self.generation == generation }
    }

    private func handle(
        _ list: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>, generation: UInt64, sampleRate: Double
    ) {
        guard self.isCurrent(generation) else { return }
        self.lock.withLock { self.lastBufferAt = Date() }
        guard var stereo = Self.stereoSamples(list), !stereo.left.isEmpty else { return }
        // The tap's cycles only arrive while the Mac is playing something (a call keeps them coming). After a pause, stamp again from the host
        // clock so the track keeps its place on the meeting's timeline and the writer sees the pause as a gap.
        let hostNanos: UInt64? = time.pointee.mFlags.contains(.hostTimeValid) ? AudioConvertHostTimeToNanos(time.pointee.mHostTime) : nil
        if let hostNanos, let end = self.lastCallbackEndNanos, hostNanos > end + Self.pauseNanos {
            if !self.left.isEmpty { self.flush(generation: generation) }
            self.clock = MeetingMicrophonePTSClock()
        }
        if let hostNanos {
            self.lastCallbackEndNanos = hostNanos + UInt64(Double(stereo.left.count) / sampleRate * 1_000_000_000)
        }
        if abs(sampleRate - Self.canonicalSampleRate) > 0.5 {
            guard let resampled = self.resample(stereo, from: sampleRate) else { return }
            stereo = resampled
        }
        if self.left.isEmpty {
            self.windowHostTime = time.pointee.mFlags.contains(.hostTimeValid) ? time.pointee.mHostTime : nil
        }
        self.left.append(contentsOf: stereo.left)
        self.right.append(contentsOf: stereo.right)
        if self.left.count >= Self.windowFrames { self.flush(generation: generation) }
    }

    /// One IO cycle of the tap as two planar channels. The aggregate's input list holds the sub-device's streams first and the tap's stream last:
    /// one buffer (2 channels, interleaved) normally, but two while this process runs voice processing, where the output device also exposes a
    /// 6-channel input stream (measured). Reading the first buffer there recorded silence on one side and the interleaved pairs on the other.
    private static func stereoSamples(_ list: UnsafePointer<AudioBufferList>) -> (left: [Float], right: [Float])? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let tapBuffer = buffers.last, let data = tapBuffer.mData?.assumingMemoryBound(to: Float.self) else { return nil }
        let channels = max(1, Int(tapBuffer.mNumberChannels))
        guard channels <= 2 else { return nil }
        let frames = Int(tapBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return nil }
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            left[frame] = data[frame * channels]
            right[frame] = channels > 1 ? data[frame * channels + 1] : left[frame]
        }
        return (left, right)
    }

    /// Streaming stereo resample to 48 kHz (the converter keeps its state between cycles).
    private func resample(_ stereo: (left: [Float], right: [Float]), from rate: Double) -> (left: [Float], right: [Float])? {
        if self.resampler == nil || self.resamplerRate != rate {
            guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false),
                  let converter = AVAudioConverter(from: source, to: Self.canonicalFormat)
            else { return nil }
            self.resampler = converter
            self.resamplerRate = rate
        }
        guard let converter = self.resampler else { return nil }
        let frames = stereo.left.count
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: converter.outputFormat,
                  frameCapacity: AVAudioFrameCount((Double(frames) * Self.canonicalSampleRate / rate).rounded(.up)) + 64
              ),
              let inputData = input.floatChannelData
        else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        Self.copy(stereo.left, to: inputData[0])
        Self.copy(stereo.right, to: inputData[1])
        var conversionError: NSError?
        var consumed = false
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        guard conversionError == nil, output.frameLength > 0, let outputData = output.floatChannelData else { return nil }
        let count = Int(output.frameLength)
        return (
            Array(UnsafeBufferPointer(start: outputData[0], count: count)),
            Array(UnsafeBufferPointer(start: outputData[1], count: count))
        )
    }

    private func flush(generation: UInt64) {
        let frames = self.left.count
        let outcome = self.clock.stamp(hostTime: self.windowHostTime, frameCount: frames)
        let samplesLeft = self.left
        let samplesRight = self.right
        self.left.removeAll(keepingCapacity: true)
        self.right.removeAll(keepingCapacity: true)
        self.windowHostTime = nil
        // Over the cap: leave the gap visible rather than writing a flawless but shortened track.
        guard case let .emitted(pts, _, _, _) = outcome,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalFormat, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData
        else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        Self.copy(samplesLeft, to: data[0])
        Self.copy(samplesRight, to: data[1])
        guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else { return }
        self.onSample(sampleBuffer, generation)
    }

    // MARK: - Core Audio lookups

    private static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown)
        else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    /// Core Audio's process objects (every process that has audio objects), narrowed by pid or executable path.
    private static func processObjects(where matches: ((pid: pid_t, path: String)) -> Bool) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return false }
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            return matches((pid, length > 0 ? String(cString: pathBuffer) : ""))
        }
    }

    private static func copy(_ samples: [Float], to destination: UnsafeMutablePointer<Float>) {
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { destination.update(from: base, count: samples.count) }
        }
    }
}
