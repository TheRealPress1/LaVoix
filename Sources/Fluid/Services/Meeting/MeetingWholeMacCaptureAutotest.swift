import AppKit
import AVFoundation
import Foundation

/// `LAVOIX_WHOLE_MAC_CAPTURE_AUTOTEST=<seconds>`: records the WHOLE MAC straight through `MeetingCaptureEngine` (no app named, the same identity a call gets by
/// default now) while a system sound is played by ANOTHER process (`afplay`, so it is not this app's own audio, which is left out), then reads the saved call-audio
/// track and says how loud it is. A track at digital silence means the display-wide capture did not carry the sound. It opens the microphone for the same few seconds
/// (a call recording always does) and plays a short chime on the speakers; nothing is kept: the folder it writes to is deleted at the end.
enum MeetingWholeMacCaptureAutotest {
    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["LAVOIX_WHOLE_MAC_CAPTURE_AUTOTEST"], let seconds = Double(text), seconds > 0 else { return }
        Task.detached {
            do {
                let ok = try await self.run(seconds: seconds)
                exit(ok ? 0 : 1)
            } catch {
                print("WHOLE MAC CAPTURE AUTOTEST FAILED: \(error)")
                exit(1)
            }
        }
    }

    private static func run(seconds: Double) async throws -> Bool {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("whole-mac-capture-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: nil)
        let application = MeetingApplicationIdentity.wholeMac
        let configuration = MeetingCaptureConfiguration(mode: .onlineCall, title: "Whole Mac test", application: application, microphone: microphone)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let session = MeetingSession(
            configuration: configuration,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: mach_absolute_time(), machTimebaseNumerator: info.numer, machTimebaseDenominator: info.denom, firstPresentationTime: nil
            )
        )
        print("target: \(application.displayName) (\(application.bundleIdentifier)), microphone: \(microphone.displayName)")

        let started = Date()
        let engine = MeetingCaptureEngine()
        try await engine.preflightPermissions()
        let result = try await engine.start(
            session: session,
            configuration: configuration,
            sessionDirectory: folder,
            eventHandler: { event in
                if case let .interrupted(kind, _, detail) = event {
                    print(String(format: "+%.1fs event: %@ %@", Date().timeIntervalSince(started), "\(kind)", detail ?? ""))
                }
            },
            liveAudioHandler: nil
        )
        print("started: scope=\(String(describing: result.captureScope)) (expect display)")

        // The sound comes from another process: two short chimes, a second apart.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        for _ in 0 ..< 2 {
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try? player.run()
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        while Date().timeIntervalSince(started) < seconds { try await Task.sleep(nanoseconds: 200_000_000) }
        let final = try await engine.stop(sessionID: session.id)

        var callPeak: Float = 0
        var sawCallTrack = false
        for track in final.tracks {
            var peak: Float = 0
            var squares: Double = 0
            var frames: Double = 0
            for chunk in track.chunks {
                let url = folder.appendingPathComponent(chunk.relativeFilePath)
                guard let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { continue }
                for index in 0 ..< Int(buffer.frameLength) {
                    let sample = data[0][index]
                    peak = max(peak, abs(sample))
                    squares += Double(sample * sample)
                    frames += 1
                }
            }
            let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -120
            let rmsDB = frames > 0 && squares > 0 ? 10 * log10(squares / frames) : -120
            print(String(format: "track %@: chunks=%d peak=%.1f dBFS rms=%.1f dBFS", "\(track.kind)", track.chunks.count, peakDB, rmsDB))
            if track.kind == .applicationAudio { sawCallTrack = true; callPeak = peak }
        }
        let callPeakDB = callPeak > 0 ? 20 * log10(Double(callPeak)) : -120
        let ok = sawCallTrack && callPeakDB > -45
        print(ok ? "WHOLE MAC CAPTURE AUTOTEST PASSED: the sound played by another process is in the call-audio track (peak \(Int(callPeakDB)) dBFS)"
                 : "WHOLE MAC CAPTURE AUTOTEST FAILED: the call-audio track is silent or missing (peak \(Int(callPeakDB)) dBFS)")
        return ok
    }
}
