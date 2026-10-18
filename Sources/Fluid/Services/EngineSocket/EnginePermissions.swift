import ApplicationServices
import AVFoundation
import Contacts
import CoreGraphics
import Foundation

/// What macOS lets the engine do, so myOS can show real toggles. Status is read-only; a request asks macOS to show its own question
/// where it has one (microphone, contacts, accessibility, input monitoring) and does nothing for Full Disk Access, which can only be
/// switched on by the user in System Settings.
nonisolated protocol EnginePermissionsProviding: Sendable {
    func status() async -> [String: String]
    func request(_ name: String) async throws
}

nonisolated enum EnginePermissionsError: Error { case unknown, notPromptable }

nonisolated enum EnginePermissionState {
    static let granted = "granted"
    static let denied = "denied"
    /// macOS has not asked yet, so a request will show its question.
    static let notAsked = "not_asked"

    static func map(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: self.granted
        case .notDetermined: self.notAsked
        default: self.denied
        }
    }

    static func map(_ status: CNAuthorizationStatus) -> String {
        switch status {
        case .authorized: self.granted
        case .notDetermined: self.notAsked
        default: self.denied
        }
    }

    static func map(trusted: Bool) -> String { trusted ? self.granted : self.denied }
}

nonisolated enum EnginePermissionNames {
    static let all = ["microphone", "accessibility", "input_monitoring", "contacts", "full_disk_access"]
}

nonisolated struct LiveEnginePermissions: EnginePermissionsProviding {
    func status() async -> [String: String] {
        [
            "microphone": EnginePermissionState.map(AVCaptureDevice.authorizationStatus(for: .audio)),
            "accessibility": EnginePermissionState.map(trusted: AXIsProcessTrusted()),
            "input_monitoring": EnginePermissionState.map(trusted: CGPreflightListenEventAccess()),
            "contacts": EnginePermissionState.map(CNContactStore.authorizationStatus(for: .contacts)),
            "full_disk_access": Self.canReadMessages() ? EnginePermissionState.granted : EnginePermissionState.denied,
        ]
    }

    func request(_ name: String) async throws {
        switch name {
        case "microphone": _ = await AVCaptureDevice.requestAccess(for: .audio)
        case "contacts": _ = try? await CNContactStore().requestAccess(for: .contacts)
        case "accessibility": _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case "input_monitoring": _ = CGRequestListenEventAccess()
        case "full_disk_access": throw EnginePermissionsError.notPromptable
        default: throw EnginePermissionsError.unknown
        }
    }

    /// Full Disk Access has no API: it shows as granted once the Messages database can be opened. Only opened, never read.
    private static func canReadMessages() -> Bool {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return false
    }
}
