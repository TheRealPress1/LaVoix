import Foundation

/// Whether a meeting is being recorded right now, read from the recorder's own session files rather than by asking the engine, so it still
/// works when the engine cannot be reached. The same rule as myOS's engine keeper (`engine_host.rs recording_in_progress`), the freeze watchdog
/// and the myOS installer: the newest `session.json` is in a live state and was written in the last two minutes (the recorder writes a
/// checkpoint about every ten seconds). An unreadable file that was just written counts as recording, so nothing is ever cut off by mistake.
enum MeetingRecordingGuard {
    /// A session this long without a write is not being recorded any more.
    static let freshSeconds: TimeInterval = 120
    private static let finishedStates: Set<String> = ["completed", "failed", "cancelled", ""]

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FluidVoice/Meetings", isDirectory: true)
    }

    static func isRecordingInProgress(meetingsFolder: URL? = nil, now: Date = Date()) -> Bool {
        let folder = meetingsFolder ?? self.defaultFolder
        guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return false }
        var newest: (modified: Date, url: URL)?
        for entry in entries {
            let file = entry.appendingPathComponent("session.json")
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date else { continue }
            if newest == nil || modified > newest!.modified { newest = (modified, file) }
        }
        guard let newest else { return false }
        let age = now.timeIntervalSince(newest.modified)
        guard age < self.freshSeconds else { return false }
        guard let data = try? Data(contentsOf: newest.url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let state = json["state"] as? String else { return true }
        return !self.finishedStates.contains(state)
    }
}
