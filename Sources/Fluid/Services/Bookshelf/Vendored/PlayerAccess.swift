// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.

nonisolated extension MusicPlayerKind {
    /// Stable bundle identity used to discover a running player without first
    /// sending an Apple Event to System Events. Process names are presentation;
    /// bundle identifiers are what Launch Services and NSRunningApplication use.
    var applicationBundleIdentifier: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .appleMusic: "com.apple.Music"
        }
    }
}

/// The local result of asking a desktop music player for one observation.
///
/// Playback snapshots remain the public API and wire model. This wrapper stays
/// inside the app's Automation boundary so a denied grant and a transient
/// metadata gap no longer become the same anonymous `.unavailable` snapshot.
nonisolated enum PlaybackReadResult: Equatable, Sendable {
    case success(PlaybackSnapshot)
    case permissionDenied(provider: MusicPlayerKind)
    case metadataUnavailable(state: PlaybackState, provider: MusicPlayerKind)
    case scriptFailure(code: Int?, provider: MusicPlayerKind)

    var provider: MusicPlayerKind {
        switch self {
        case .success(let snapshot):
            snapshot.provider
        case .permissionDenied(let provider),
             .metadataUnavailable(_, let provider),
             .scriptFailure(_, let provider):
            provider
        }
    }

    /// State projection used only to decide whether another supported player
    /// could currently be the one producing music.
    var state: PlaybackState {
        switch self {
        case .success(let snapshot):
            snapshot.state
        case .metadataUnavailable(let state, _):
            state
        case .permissionDenied, .scriptFailure:
            .unavailable
        }
    }
}

import AppKit
import Foundation

nonisolated enum AppleScriptExecutionResult: Equatable, Sendable {
    case success(stringValue: String?, data: Data?)
    case failure(code: Int?, message: String?)
}

nonisolated protocol AppleScriptExecuting: Sendable {
    func execute(_ source: String) -> AppleScriptExecutionResult
}

nonisolated struct SystemAppleScriptExecutor: AppleScriptExecuting {
    func execute(_ source: String) -> AppleScriptExecutionResult {
        guard let script = NSAppleScript(source: source) else {
            return .failure(
                code: nil,
                message: "Bookshelf could not prepare the AppleScript."
            )
        }

        var details: NSDictionary?
        let descriptor = script.executeAndReturnError(&details)
        if let details {
            let code = (details[NSAppleScript.errorNumber] as? NSNumber)?.intValue
            let message = Self.errorMessage(from: details)
            return .failure(code: code, message: message)
        }
        return .success(stringValue: descriptor.stringValue, data: descriptor.data)
    }

    private static func errorMessage(from details: NSDictionary) -> String? {
        let message = (details[NSAppleScript.errorMessage] as? String)
            ?? (details[NSAppleScript.errorBriefMessage] as? String)
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

nonisolated protocol PlayerApplicationDetecting: Sendable {
    func isRunning(bundleIdentifier: String) -> Bool
}

nonisolated struct SystemPlayerApplicationDetector: PlayerApplicationDetecting {
    func isRunning(bundleIdentifier: String) -> Bool {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { !$0.isTerminated }
    }
}

