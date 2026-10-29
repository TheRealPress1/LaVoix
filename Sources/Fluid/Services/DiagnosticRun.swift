import Foundation

/// True when this process was started only to test, probe or render something (an autotest, a notch render, a probe), never to be the real app.
/// Such a run starts the whole app beside the one you are using, so it must not behave like the real one: it must not take the engine's socket,
/// open the local API port or arm the meeting detector against a call that is being recorded by the real engine. (A test run that took the
/// engine's socket while a meeting was being recorded left the engine looking frozen, and the freeze watchdog then quit it mid-recording.)
enum DiagnosticRun {
    private static let suffixes = ["_AUTOTEST", "_E2E", "_SELFTEST", "_PROBE", "_TEST"]

    static func isDiagnostic(environment: [String: String]) -> Bool {
        // The app started by Xcode as a test host is a second copy of the app too.
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return true }
        return environment.contains { key, value in
            guard key.hasPrefix("LAVOIX_"), !value.isEmpty, value != "0" else { return false }
            return self.suffixes.contains { key.hasSuffix($0) } || key == "LAVOIX_NOTCH_RENDER" || key == "LAVOIX_EVAL" || key.hasPrefix("LAVOIX_ATTACH_")
        }
    }

    static let isActive: Bool = DiagnosticRun.isDiagnostic(environment: ProcessInfo.processInfo.environment)
}
