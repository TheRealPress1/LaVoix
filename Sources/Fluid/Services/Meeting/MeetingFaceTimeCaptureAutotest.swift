import AppKit
import Foundation

/// `LAVOIX_FACETIME_CAPTURE_AUTOTEST=<seconds>`: records a stand-in app with the FaceTime treatment (the call audio read with a Core Audio tap, the
/// microphone in voice processing) straight through `MeetingCaptureEngine`, with nothing else of the app running, and prints what the recorder
/// reported. FaceTime itself quits when it has no call to show, so `LAVOIX_FACETIME_STANDIN_BUNDLE` (default TextEdit, needs a window, and it must
/// be set for the stand-in to be treated like FaceTime) takes its place. A stand-in has no helper audio to tap: `LAVOIX_FACETIME_TAP_WHOLE_MAC=1` taps
/// the whole Mac instead, so spoken test audio flows through the rest of the path.
/// `LAVOIX_FACETIME_CAPTURE_MIC_UID` picks another input (the Studio Display's, AirPods) instead of the default one.
/// `LAVOIX_FACETIME_CAPTURE_OUT` is the folder the session is written to; read it with audio_levels.py. `LAVOIX_FACETIME_CAPTURE_QUIT_APP=1`
/// quits the stand-in half way, to check that the end of a call ends the recording.
enum MeetingFaceTimeCaptureAutotest {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { self.lock.withLock { self.value = true } }
        var isSet: Bool { self.lock.withLock { self.value } }
    }

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["LAVOIX_FACETIME_CAPTURE_AUTOTEST"], let seconds = Double(text), seconds > 0 else { return }
        Task.detached {
            do {
                try await self.run(seconds: seconds, environment: environment)
                exit(0)
            } catch {
                print("FACETIME CAPTURE AUTOTEST FAILED: \(error)")
                exit(1)
            }
        }
    }

    private static func run(seconds: Double, environment: [String: String]) async throws {
        let bundle = environment["LAVOIX_FACETIME_STANDIN_BUNDLE"] ?? "com.apple.TextEdit"
        let folder = URL(fileURLWithPath: environment["LAVOIX_FACETIME_CAPTURE_OUT"] ?? NSTemporaryDirectory() + "facetime-capture-test")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let applications = try await MeetingCaptureSourceCatalog.availableApplications()
        let application = try MeetingCaptureSourceCatalog.resolveApplication(
            from: applications, preferredBundleIdentifier: bundle, requirePreferredApplication: true
        )
        let microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: environment["LAVOIX_FACETIME_CAPTURE_MIC_UID"])
        let configuration = MeetingCaptureConfiguration(mode: .onlineCall, title: "FaceTime stand-in", application: application, microphone: microphone)
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let session = MeetingSession(
            configuration: configuration,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: mach_absolute_time(), machTimebaseNumerator: info.numer, machTimebaseDenominator: info.denom, firstPresentationTime: nil
            )
        )
        print("stand-in app: \(application.displayName) (\(application.bundleIdentifier)), microphone: \(microphone.displayName) [\(microphone.coreAudioUID ?? "?")]")

        let stopped = Flag()
        let started = Date()
        let engine = MeetingCaptureEngine()
        try await engine.preflightPermissions()
        let result = try await engine.start(
            session: session,
            configuration: configuration,
            sessionDirectory: folder,
            eventHandler: { event in
                let at = String(format: "+%.1fs", Date().timeIntervalSince(started))
                switch event {
                case let .interrupted(kind, _, detail):
                    print("\(at) event: \(kind) \(detail ?? "")")
                    if kind == .captureStoppedUnexpectedly { stopped.set() }
                case let .captureMethodChanged(_, method, _):
                    print("\(at) event: capture method now \(method)")
                case .chunkFinalized, .trackHealth:
                    break
                }
            },
            liveAudioHandler: nil
        )
        print("started: scope=\(String(describing: result.captureScope))")
        for track in result.tracks {
            print("  track \(track.kind): method=\(track.captureMethod) eras=\(track.captureEras?.map { "\($0.method)/\($0.echoProtection)" } ?? [])")
        }
        print("RECORDING for \(Int(seconds)) s into \(folder.path)")

        let quitAt = environment["LAVOIX_FACETIME_CAPTURE_QUIT_APP"] == "1" ? seconds / 2 : nil
        var quitTime: Date?
        while Date().timeIntervalSince(started) < seconds, !stopped.isSet {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let quitAt, quitTime == nil, Date().timeIntervalSince(started) >= quitAt {
                quitTime = Date()
                print(String(format: "+%.1fs quitting the stand-in app (the call ends)", Date().timeIntervalSince(started)))
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).forEach { $0.terminate() }
            }
        }
        if quitTime != nil, !stopped.isSet {
            // Give the recorder time to notice (two window checks, then the rebuild attempts).
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, !stopped.isSet { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        if let quitTime {
            print(stopped.isSet
                ? String(format: "the recording ended %.1f s after the call ended", Date().timeIntervalSince(quitTime))
                : "THE RECORDING DID NOT END after the call ended")
        }
        let final = try await engine.stop(sessionID: session.id)
        for track in final.tracks {
            print("stopped: \(track.kind) chunks=\(track.chunks.count) eras=\(track.captureEras?.map { "\($0.method)/\($0.echoProtection)" } ?? [])")
        }
        print("FACETIME CAPTURE AUTOTEST DONE; folder: \(folder.path)")
    }
}
