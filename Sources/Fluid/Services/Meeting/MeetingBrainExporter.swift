import Foundation
import SQLite3

/// Writes a finished meeting into myOS's Brain as a plain Markdown note, so it shows up next to the rest of the notes.
///
/// Brain is a flat folder of `.md` files whose title is the first line, so the note starts with `# Title` and carries no
/// YAML frontmatter. LaVoix owns only the block between the summary markers; anything the user writes outside them
/// survives later rewrites, and a note whose markers were deleted is left alone.
nonisolated enum MeetingBrainExporter {
    static let beginMarker = "<!-- lavoix:summary -->"
    static let endMarker = "<!-- /lavoix:summary -->"

    /// Where myOS keeps its bootstrap pointer to the data folder.
    static var defaultBootstrapDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/myOS/bootstrap.db")
    }

    /// myOS's `brain/` folder: the override if one is set, else the data folder myOS itself recorded. Nil when myOS isn't
    /// set up here.
    static func brainDirectory(override: String?, bootstrapDatabase: URL = defaultBootstrapDatabase) -> URL? {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard let dataDir = self.myOSDataDirectory(bootstrapDatabase: bootstrapDatabase) else { return nil }
        return dataDir.appendingPathComponent("brain", isDirectory: true)
    }

    static func myOSDataDirectory(bootstrapDatabase: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: bootstrapDatabase.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(bootstrapDatabase.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM _system_meta WHERE key = 'data_dir'", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        let path = String(cString: text)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Stable per meeting, so a re-run updates the same note instead of adding another.
    static func fileName(for session: MeetingSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let slug = session.title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let shortSlug = String(slug.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = session.id.uuidString.lowercased().prefix(8)
        return "meeting-\(formatter.string(from: session.startedAt))-\(shortSlug.isEmpty ? "meeting" : shortSlug)-\(id).md"
    }

    static func summaryBlock(_ summary: String?) -> String {
        let body = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (body?.isEmpty == false) ? body! : "_No summary yet._"
        return "\(beginMarker)\n## Summary\n\n\(text)\n\(endMarker)"
    }

    static func render(session: MeetingSession, summary: String?, userNotes: String, transcriptPath: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var facts = [formatter.string(from: session.startedAt)]
        if let end = session.endedAt {
            facts.append("\(max(1, Int((end.timeIntervalSince(session.startedAt) / 60).rounded()))) min")
        }
        if let app = session.capturedApplication?.displayName, !app.isEmpty { facts.append(app) }
        let people = session.activeSpeakers.map(\.displayName).filter { !$0.isEmpty }
        if !people.isEmpty { facts.append(people.joined(separator: ", ")) }

        var lines = [
            "# \(session.title)",
            "",
            "_\(facts.joined(separator: " · "))_",
            "",
            "<!-- lavoix:meeting id=\(session.id.uuidString.lowercased()) -->",
            "",
            self.summaryBlock(summary),
        ]
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { lines += ["", "## My notes", "", notes] }
        if let transcriptPath { lines += ["", "Transcript: `\(transcriptPath)`"] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Creates the note, or refreshes only the summary block of an existing one. Returns false when nothing was written.
    @discardableResult
    static func upsert(
        session: MeetingSession, summary: String?, userNotes: String, transcriptPath: String?, brainDirectory: URL
    ) throws -> Bool {
        let manager = FileManager.default
        try manager.createDirectory(at: brainDirectory, withIntermediateDirectories: true)
        let name = self.fileName(for: session)
        let target = brainDirectory.appendingPathComponent(name)
        let content: String
        if manager.fileExists(atPath: target.path) {
            guard summary != nil else { return false }
            let existing = try String(contentsOf: target, encoding: .utf8)
            guard let begin = existing.range(of: beginMarker),
                  let end = existing.range(of: endMarker, range: begin.upperBound..<existing.endIndex) else { return false }
            content = existing.replacingCharacters(in: begin.lowerBound..<end.upperBound, with: self.summaryBlock(summary))
            if content == existing { return false }
        } else {
            content = self.render(session: session, summary: summary, userNotes: userNotes, transcriptPath: transcriptPath)
        }
        // Temp file in the same folder, then rename, so myOS's watcher never reads half a note. The dot prefix keeps the
        // temp file out of Brain's list.
        let temp = brainDirectory.appendingPathComponent(".\(name).tmp")
        try content.write(to: temp, atomically: false, encoding: .utf8)
        _ = try manager.replaceItemAt(target, withItemAt: temp)
        return true
    }
}
