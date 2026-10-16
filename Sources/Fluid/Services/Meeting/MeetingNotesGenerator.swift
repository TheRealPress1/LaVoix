import Foundation

// The note-writing guidance below is adapted from Anarlog's meeting-enhancement prompts
// (https://github.com/fastrepl/anarlog, crates/template-app), used under the MIT License.
// Copyright (c) Fastrepl, Inc. Permission notice: https://github.com/fastrepl/anarlog/blob/main/LICENSE

/// Prompts for turning a meeting transcript (and the user's own notes) into structured notes.
nonisolated enum MeetingNotesPrompt {
    private static let base = """
    You are an expert at writing accurate, specific meeting notes. The transcript is raw speech-to-text, so it \
    may contain recognition errors, filler words and false starts; the user's own notes may contain typos. \
    Make the best of every source.

    Rules:
    - Be concrete: keep names, numbers, dates, decisions and reasons. Avoid vague abstraction.
    - Never invent anything that was not said or written. If something is unclear, leave it out.
    - Write days and times exactly as they were said ("Thursday", "tomorrow", "next Monday", "end of day"). Never turn them into calendar dates. Only write a full date if someone actually said it.
    - The speaker labelled "You" is the person who recorded the meeting and will read these notes. Write "you" for them ("You asked about pricing") and use the other speakers' labels as they appear.
    - Do not add generic openers such as "Overview", "Introduction" or "Participants" unless asked.
    - Output ONLY the notes in Markdown. No preamble, no commentary, no "Here is the summary".
    """

    private static let userNotesGuidance = """

    The user also took their own notes during the meeting. Treat them as a signal of what mattered: make sure \
    everything they wrote is reflected, weave it in naturally, and use the transcript to fill in the detail. \
    Text they emphasised (**bold**, ### headers) is especially important. Do not copy their notes verbatim as a separate block.
    """

    static func system(kind: MeetingSummaryKind, hasUserNotes: Bool) -> String {
        base + (hasUserNotes ? userNotesGuidance : "") + "\n\n" + format(for: kind)
    }

    private static func format(for kind: MeetingSummaryKind) -> String {
        switch kind {
        case .executive:
            return """
            Format: a short executive summary.
            - 4 to 7 bullet points: the outcome, key decisions, and anything that needs attention.
            - Each bullet is one or two specific sentences.
            - Do not add a "Next Steps" section; action items are listed separately.
            """
        case .detailed:
            return """
            Format:
            - Use only "#" (h1) headings, one per main topic, followed by bullet points. Do not use h2 or h3.
            - Each section has at least three detailed bullets covering specific discussion points, decisions and reasoning.
            - Do not nest lists more than one level; start a new "#" section instead.
            - If there are explicit owners, commitments or deadlines, put them in a final "# Next Steps" section.
            """
        case .actions:
            return """
            Format: action items only.
            - One line per item: "- [ ] **Owner** — task (deadline)". Omit the deadline if none was stated.
            - An action item is something a person agreed or was asked to do. Never list decisions, dates of events, prices or facts as action items.
            - Include only commitments that were explicitly made, and every one of them, including small ones ("I'll send the file this afternoon"). Read the whole transcript, not just the closing recap. Use "Unassigned" when no owner is clear.
            - List each task once. Do not add a task just to confirm another one.
            - Do not add follow-up tasks that nobody mentioned.
            - If there are no action items, output exactly: No action items.
            """
        case .decisions:
            return """
            Format: key decisions only.
            - One bullet per decision, stating what was decided and, when given, why.
            - A decision is a choice the group agreed on (a date, a price, an approach). Do not list tasks, assignments or status updates.
            - Include only decisions that were actually made, not options that were merely discussed.
            - If there are none, output exactly: No decisions recorded.
            """
        case .participants:
            return """
            Format: one bullet per person who spoke.
            - "**Name** — what they contributed, raised, or committed to."
            - Use the speaker labels exactly as they appear in the transcript.
            """
        case .topics:
            return """
            Format: a numbered list of the topics discussed, in the order they came up.
            - Each item: a short title in bold, then one or two sentences on what was said.
            """
        }
    }

    /// Your own turns are labelled "Me" in the transcript. A small model reads "Me" as a third person ("Gaspard and Me
    /// agreed"), so the notes are written from a transcript where you are "You". Only the label and the participants line
    /// change, never what anyone said, and the saved transcript is untouched.
    static func relabelingMe(_ line: String) -> String {
        if line.hasPrefix("**Me**:") { return "**You**:" + line.dropFirst("**Me**:".count) }
        if line.hasPrefix("Participants:") {
            let names = line.dropFirst("Participants:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return "Participants: " + names.map { $0 == "Me" ? "You" : $0 }.joined(separator: ", ")
        }
        return line
    }

    static func user(transcript: String, userNotes: String) -> String {
        var text = ""
        let notes = userNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            text += "# User's Notes\n\n\(notes)\n\n"
        }
        text += "# Transcript\n\n\(transcript)"
        return text
    }

    static let chunkSystem = """
    You condense one part of a long meeting transcript into dense factual notes for later summarisation. The transcript \
    is raw speech-to-text and may contain errors.

    Rules:
    - Output a Markdown bullet list. Keep every concrete detail: who said or committed to what, names, numbers, dates, \
    decisions and the reasons behind them.
    - Never invent anything. Skip small talk and filler.
    - Output ONLY the bullet list.
    """
}

nonisolated enum MeetingNotesError: LocalizedError {
    case emptyTranscript
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "There's no transcript to summarize yet."
        case .emptyOutput: return "The on-device model returned no notes. Try again."
        }
    }
}

/// Generates meeting notes with the on-device model. Long meetings are condensed in chunks first.
nonisolated enum MeetingNotesGenerator {
    /// About 11k tokens. Above this, summarising directly gets slow and loses detail.
    nonisolated(unsafe) static var directCharacterLimit = 40_000
    nonisolated(unsafe) static var chunkCharacterTarget = 24_000

    static func generate(
        transcript: String,
        kind: MeetingSummaryKind,
        userNotes: String,
        modelID: String,
        command: String? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // The meeting's own date is withheld so the model has nothing to turn "Thursday" or "tomorrow" into.
        let body = transcript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("Date:") && !$0.hasPrefix("Time:") }
            .map { MeetingNotesPrompt.relabelingMe(String($0)) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw MeetingNotesError.emptyTranscript }

        if let command, !command.isEmpty {
            // The user's own model decides how much it can read, so there is no chunking.
            progress?("Writing notes…")
            let system = MeetingNotesPrompt.system(
                kind: kind, hasUserNotes: !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            let user = MeetingNotesPrompt.user(transcript: body, userNotes: userNotes)
            let output = try await MeetingNotesCommand.run(command: command, input: system + "\n\n---\n\n" + user)
            let cleaned = MeetingNotesDateGuard.apply(to: output, source: body + "\n" + userNotes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { throw MeetingNotesError.emptyOutput }
            return cleaned
        }

        var source = body
        if body.count > directCharacterLimit {
            let chunks = Self.chunks(of: body)
            var condensed: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                progress?("Reading part \(index + 1) of \(chunks.count)…")
                let part = try await LocalCleanupEngine.shared.generate(
                    system: MeetingNotesPrompt.chunkSystem,
                    user: chunk,
                    modelID: modelID,
                    maxTokens: 1200,
                    temperature: 0.2,
                    cachesPrefix: false
                )
                condensed.append("## Part \(index + 1)\n\(part)")
            }
            source = condensed.joined(separator: "\n\n")
        }

        try Task.checkCancellation()
        progress?("Writing notes…")
        let finalSystem = MeetingNotesPrompt.system(
            kind: kind,
            hasUserNotes: !userNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
        let finalUser = MeetingNotesPrompt.user(transcript: source, userNotes: userNotes)
        let output = try await LocalCleanupEngine.shared.generate(
            system: finalSystem,
            user: finalUser,
            modelID: modelID,
            maxTokens: kind == .detailed ? 2000 : 1000,
            temperature: 0.2,
            cachesPrefix: false
        )
        let cleaned = MeetingNotesDateGuard.apply(to: output, source: body + "\n" + userNotes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MeetingNotesError.emptyOutput }
        TrainingData.recordPrompt(system: finalSystem, user: finalUser, model: modelID, output: cleaned)
        return cleaned
    }

    /// Splits on line boundaries so a speaker turn is never cut in half.
    static func chunks(of text: String, target: Int? = nil) -> [String] {
        let target = target ?? chunkCharacterTarget
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.count + line.count + 1 > target, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
