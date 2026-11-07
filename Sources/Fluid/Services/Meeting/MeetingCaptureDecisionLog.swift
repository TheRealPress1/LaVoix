import CoreAudio
import Foundation

/// One line, written when a recording starts, that says what the recorder decided and what it saw. A 76 minute call on 2026-11-06 recorded
/// nothing usable and the log had no line about the capture at all (the one existing message was compiled out of release builds), so the
/// cause had to be rebuilt from the saved session afterwards. Never contains titles or names of people or windows: only app ids, device
/// names, ids and yes/no facts about the route.
nonisolated enum MeetingCaptureDecisionLog {
    struct Facts: Equatable, Sendable {
        var mode: MeetingCaptureMode
        var applicationBundleIdentifier: String?
        var applicationProcessID: Int32?
        var applicationDisplayID: UInt32?
        var microphoneName: String
        var microphoneIsBuiltIn: Bool
        var outputRoute: MeetingOutputRouteSnapshot
        /// "voiceProcessing" or "screenCaptureKit".
        var path: String
        /// Why the screenCaptureKit path was chosen (nil for voice processing).
        var pathReason: String?
        var directAEC3Enabled: Bool
        /// How the other side of the call is recorded: "tap" (a Core Audio tap on the process that plays it), "screenCaptureKit" or "none".
        var callAudioSource: String
        /// "window" or "display" for a ScreenCaptureKit stream; nil when none runs.
        var captureScope: String?
    }

    static func line(_ facts: Facts) -> String {
        let route = facts.outputRoute
        var parts: [String] = [
            "Meeting capture decisions:",
            "mode=\(facts.mode.rawValue)",
            "app=\(facts.applicationBundleIdentifier ?? "none")",
            "appPID=\(facts.applicationProcessID.map(String.init) ?? "none")",
            "appDisplayID=\(facts.applicationDisplayID.map(String.init) ?? "none")",
            "mic=\"\(facts.microphoneName)\"",
            "micBuiltIn=\(Self.yesNo(facts.microphoneIsBuiltIn))",
            "outputExists=\(Self.yesNo(route.deviceExists))",
            "outputBuiltIn=\(Self.yesNo(route.isBuiltIn))",
            "outputBluetooth=\(Self.yesNo(route.isBluetooth))",
            "outputHeadphones=\(Self.yesNo(route.isHeadphonesDataSource || route.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones)))",
            "path=\(facts.path)",
        ]
        if let reason = facts.pathReason, !reason.isEmpty { parts.append("pathReason=\"\(reason)\"") }
        parts.append("directAEC3=\(facts.directAEC3Enabled ? "enabled" : "disabled")")
        parts.append("callAudio=\(facts.callAudioSource)")
        parts.append("scope=\(facts.captureScope ?? "none")")
        return parts.joined(separator: " ")
    }

    private static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }
}
