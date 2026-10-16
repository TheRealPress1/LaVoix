import Foundation

/// `LAVOIX_ATTACH_TRANSCRIPT=1 LAVOIX_ATTACH_SESSION=<session uuid> LAVOIX_ATTACH_FILE=<recovered transcript .md>`
/// Attaches a transcript produced outside the normal pipeline (for example one recovered from a session's saved microphone
/// audio) to that session, so the Meetings page shows it. Quit LaVoix first: the running app keeps sessions in memory.
/// The file is the recovered-transcript Markdown: `## MM:00` blocks (about ten minutes each) of plain text. Timing inside a
/// block is spread by position, so it is approximate. `session.json` is copied to `session.json.before-recovery` first.
nonisolated enum MeetingTranscriptAttachTool {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["LAVOIX_ATTACH_TRANSCRIPT"] == "1" else { return }
        Task.detached {
            func out(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
            do {
                guard let idText = env["LAVOIX_ATTACH_SESSION"], let id = UUID(uuidString: idText), let file = env["LAVOIX_ATTACH_FILE"] else {
                    out("ATTACH FAILED: set LAVOIX_ATTACH_SESSION and LAVOIX_ATTACH_FILE"); exit(1)
                }
                let store = MeetingSessionStore.shared
                guard var session = try await store.load(id: id) else { out("ATTACH FAILED: no such session"); exit(1) }
                // LAVOIX_ATTACH_SUMMARY_FILE=<text> saves that text as the session's executive notes (what the Meet Summary
                // tab shows). On a session that already has its transcript attached, that is all the tool does.
                if let summaryFile = env["LAVOIX_ATTACH_SUMMARY_FILE"], !session.transcriptSegments.isEmpty {
                    let text = try String(contentsOfFile: summaryFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, let directory = try await store.existingSessionDirectory(for: id) else { out("ATTACH FAILED: empty summary or no folder"); exit(1) }
                    let transcript = MeetingSummaryInput.transcript(for: session)
                    let notes = (try? String(contentsOf: directory.appendingPathComponent("notes.md"), encoding: .utf8)) ?? ""
                    let saved = MeetingNotesViewModel.Saved(
                        transcriptHash: MeetingSummaryInput.fingerprint(transcript + "\n[notes]\n" + notes), modelID: "recovered", text: text
                    )
                    try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-executive.json"), options: .atomic)
                    out("SUMMARY SAVED (\(text.count) characters)")
                    exit(0)
                }
                guard session.transcriptSegments.isEmpty else { out("ATTACH FAILED: the session already has a transcript"); exit(1) }
                guard let mic = session.audioTracks.first(where: { $0.kind == .microphone }) else { out("ATTACH FAILED: no microphone track"); exit(1) }

                let directory = try await store.sessionDirectory(for: id)
                let manifest = directory.appendingPathComponent("session.json")
                let backup = directory.appendingPathComponent("session.json.before-recovery")
                if !FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.copyItem(at: manifest, to: backup) }

                let markdown = try String(contentsOfFile: file, encoding: .utf8)
                let blocks = Self.blocks(in: markdown)
                guard !blocks.isEmpty else { out("ATTACH FAILED: no ## MM:00 blocks in the file"); exit(1) }

                let speakerID = UUID()
                session.speakers.append(MeetingSessionSpeaker(
                    id: speakerID, displayName: "Me", diarizationClusterID: nil, trackKind: .microphone, isLocalUser: true, identityCandidates: []
                ))
                let total = max(session.duration, (blocks.last?.start ?? 0) + 60)
                var made = 0
                for (index, block) in blocks.enumerated() {
                    let end = index + 1 < blocks.count ? blocks[index + 1].start : total
                    let parts = Self.paragraphs(block.text, target: 380)
                    let characters = max(1, parts.reduce(0) { $0 + $1.count })
                    var offset = 0
                    for part in parts {
                        let a = block.start + (end - block.start) * Double(offset) / Double(characters)
                        offset += part.count
                        let b = block.start + (end - block.start) * Double(offset) / Double(characters)
                        session.transcriptSegments.append(MeetingTranscriptSegment(
                            id: UUID(), start: Self.time(a), end: Self.time(b), sourceTrackID: mic.id, speakerID: speakerID, text: part,
                            revision: 0, status: .final, overlap: .none, completeness: .complete, isLikelyEcho: false
                        ))
                        made += 1
                    }
                }
                // Times are seconds from the meeting's start; say so, or a one-time migration would reinterpret them.
                session.transcriptTimeDomain = .meetingRelative
                session.updatedAt = Date()
                try await store.save(session)

                let reloaded = try await store.load(id: id)
                out("ATTACHED \(made) segments in \(blocks.count) blocks; reload sees \(reloaded?.transcriptSegments.count ?? -1) segments, \(reloaded?.activeSpeakers.count ?? -1) speaker(s)")
                exit(0)
            } catch {
                out("ATTACH FAILED: \(error)")
                exit(1)
            }
        }
    }

    private static func time(_ seconds: TimeInterval) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((max(0, seconds) * 1000).rounded()), timescale: 1000)
    }

    struct Block { var start: TimeInterval; var text: String }

    /// `## 10:00` headings followed by their text.
    static func blocks(in markdown: String) -> [Block] {
        var result: [Block] = []
        var current: (start: TimeInterval, lines: [String])?
        func flush() {
            if let current { result.append(Block(start: current.start, text: current.lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## "), let colon = line.firstIndex(of: ":"), let minutes = Double(line[line.index(line.startIndex, offsetBy: 3)..<colon]) {
                flush()
                current = (minutes * 60, [])
            } else if current != nil {
                current?.lines.append(String(line))
            }
        }
        flush()
        return result.filter { !$0.text.isEmpty }
    }

    /// Splits at sentence ends into pieces of about `target` characters.
    static func paragraphs(_ text: String, target: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        var previous: Character = " "
        for character in text {
            current.append(character)
            if ".?!".contains(previous), character == " ", current.count >= target {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
            previous = character
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }
}
