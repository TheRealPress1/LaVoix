import Foundation

/// Plain Markdown copies of a meeting, written next to `session.json` so the transcript and the notes can be read,
/// searched and synced without LaVoix: `transcript.md`, `summary.md` (and `summary-<style>.md` for other styles).
nonisolated enum MeetingReadableFiles {
    static func transcriptMarkdown(for session: MeetingSession) -> String {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let turns = session.transcriptSegments
            .filter { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.start.seconds < $1.start.seconds }
            .map { turn in
                let speaker = MeetingTranscriptExporter.speakerLabel(for: turn, in: session, speakerNames: names)
                return "**\(speaker)** · \(MeetingTranscriptExporter.timestampText(turn.start.seconds))\n\(turn.text)"
            }
        return header(for: session) + turns.joined(separator: "\n\n") + "\n"
    }

    static func summaryMarkdown(for session: MeetingSession, text: String, writtenBy: String) -> String {
        header(for: session) + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n---\n_Written by \(writtenBy)._\n"
    }

    static func summaryFileName(for kind: MeetingSummaryKind) -> String {
        kind == .executive ? "summary.md" : "summary-\(kind.rawValue).md"
    }

    static func write(_ text: String, named name: String, in directory: URL) {
        try? text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func header(for session: MeetingSession) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        var facts = [formatter.string(from: session.startedAt)]
        if let end = session.endedAt {
            facts.append("\(max(1, Int((end.timeIntervalSince(session.startedAt) / 60).rounded()))) min")
        }
        let people = session.activeSpeakers.map(\.displayName)
        if !people.isEmpty { facts.append(people.joined(separator: ", ")) }
        return "# \(session.title)\n\n_\(facts.joined(separator: " · "))_\n\n"
    }
}
