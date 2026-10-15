import Foundation

/// Prompt variants for small local models. `base` is the plain instruction in the corpus; `tuned` adds definitions, worked
/// examples and (for dates) a calendar table the app computes, because small models are bad at weekday arithmetic.
/// The worked examples are deliberately worded unlike the corpus templates, so a gain is not just memorisation.
enum EvalPrompts {
    static var variant: String { ProcessInfo.processInfo.environment["LAVOIX_EVAL_PROMPT"] ?? "base" }

    static func render(_ c: EvalCase) -> (system: String, user: String) {
        var shape = "\n\nReply with ONLY a JSON object of exactly this shape, no other text: " + c.jsonShape
        guard self.variant == "tuned" else { return (c.system + shape, c.input) }
        switch c.task {
        case .mentions:
            shape = "\n\nReply with ONLY a JSON object of exactly this shape, no other text, copying each quote exactly from the transcript: " + #"{"matches": [{"id": "p-...", "quote": "words from the transcript that name this person"}]}"#
            return (self.mentions + shape, c.input)
        case .facts: return (self.facts + shape, c.input)
        case .commitments: return (self.commitments + shape, self.withCalendar(c.input))
        case .qa: return (self.qa + shape, c.input)
        }
    }

    // MARK: - Prompts

    static let mentions = """
    You find which known people are mentioned in a meeting transcript. You get a list of known people (id, full name, \
    organisation) and the transcript.

    Work like this, for every name that appears in the transcript:
    1. Is it a person's name here, or an ordinary word (will, may, mark, grace, bill)? Ordinary words are not names.
    2. Which known people could it be? Match on the first name or the full name.
    3. If exactly ONE known person fits, include their id.
    4. If TWO OR MORE known people fit (same first name), include one only if the transcript also gives their surname or \
    their organisation. A bare first name shared by two known people is NOT enough: include nobody.
    5. A name that matches no known person is ignored.
    For every id you return, give the exact words from the transcript that name that person.

    Example. Known: p1 Ana Ruiz (Vega), p2 Ben Ruiz (Orion), p3 Ana Fox (Zed). Transcript: "Ana said Ben will join; I will \
    ask Ana from Zed too." -> Ben is unique (p2). "Ana" alone is shared by p1 and p3 so it is skipped, but "Ana from Zed" is p3. \
    The word "will" is not a name. Answer: {"matches": [{"id": "p2", "quote": "Ben will join"}, {"id": "p3", "quote": "Ana from Zed"}]}
    Example. Transcript: "Priya Shah wants the report by May." with no Priya or Shah among the known people -> {"matches": []}
    """

    static let facts = """
    You read a text-message thread between "Me" and "Them" and extract lasting facts about THEM only.

    Kinds, exactly these:
    - city: the city THEY live in now. Not a city they visit, plan to move to, or where someone else lives.
    - employer: the company THEY work for now ("I work at X", "I started at X"). Not one they left.
    - birthday: their own birthday, as month and day, like "March 3".
    - partner: the first name of their spouse, husband, wife, boyfriend, girlfriend or partner. A pet is never a partner.
    - pet: the name of their dog, cat or other pet.

    Rules: facts about other people (their sister, a friend, a colleague) are not facts about them. If something changed, \
    give only the latest value. Only extract what the thread states; never guess. Small talk has no facts: return an empty list.

    Example thread:
    Them: my wife Lucia is off work so we're taking Rex to the lake
    Me: nice, is that still Boston weather?
    Them: ha, I live in Denver now, my brother is the one in Boston
    Answer: {"facts": [{"kind": "partner", "value": "Lucia"}, {"kind": "pet", "value": "Rex"}, {"kind": "city", "value": "Denver"}]}
    Example thread:
    Me: coffee Thursday?
    Them: works for me
    Answer: {"facts": []}
    """

    static let commitments = """
    You read a text-message thread between "Me" and "Them" and list OPEN commitments: things someone said they WILL do and \
    has not yet done.

    Go through the thread line by line. For each line ask: does this person promise or agree to do something? If yes, it is a \
    commitment, unless a later line says it is done. owner is "me" when I promise, "them" when they promise. "what" is a few words.
    - A request is a commitment only when the other person agrees to it ("sure", "yes", "I'll do it").
    - "Soon", "we should", "let me think" are not commitments.
    - A promise without a date is still a commitment: due is null.
    - due is yyyy-MM-dd. Use the calendar table to turn "tomorrow", "Friday", "Sunday" into a date. A weekday name means the \
    first such day in the table.
    - If a later message says it was done ("sent", "paid", "done"), leave it out.

    Example (today 2026-03-02 Mon):
    Them: can you review the draft?
    Me: yes, I'll do it Wednesday
    Them: I'll send the budget to you tomorrow
    Me: thanks
    Answer: {"items": [{"owner": "me", "what": "review the draft", "due": "2026-03-04"}, {"owner": "them", "what": "send the budget", "due": "2026-03-03"}]}
    Example:
    Me: I'll pay you back tonight
    Me: just sent it
    Answer: {"items": []}
    """

    static let qa = """
    You answer a question about one person using ONLY the dated notes. Lines are tagged with their date; the newest line wins \
    when notes disagree. Quote the value from the notes, never use outside knowledge, never guess.

    Steps: find the note lines that bear on the question. If none state the answer, set answerable to false and answer \
    "unknown". Note that a related topic is not an answer (knowing where someone works does not tell you their salary).
    For an open question like "what's going on", mention the latest news AND any promise someone made that is still pending. \
    Keep it under 25 words.

    Example notes: [2026-01-04 text] Leo: just joined Nova as designer. [2026-02-10 meeting] Leo will share mockups next week.
    Question: What's going on with Leo? -> {"answer": "Joined Nova as designer; promised to share mockups.", "answerable": true}
    Question: What is Leo's phone number? -> {"answer": "unknown", "answerable": false}
    """

    // MARK: - Calendar helper

    /// Appends a table of the next 8 days with weekday names, computed from the "Reference date (today): yyyy-MM-dd" line.
    static func withCalendar(_ input: String) -> String {
        guard let line = input.split(separator: "\n").first(where: { $0.hasPrefix("Reference date (today): ") }),
              let today = EvalCorpus.isoDay.date(from: String(line.dropFirst("Reference date (today): ".count)))
        else { return input }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        var rows: [String] = []
        for offset in 0 ... 8 {
            let d = cal.date(byAdding: .day, value: offset, to: today)!
            let label = offset == 0 ? "today" : (offset == 1 ? "tomorrow" : "")
            rows.append("\(names[cal.component(.weekday, from: d) - 1]) \(EvalCorpus.isoDay.string(from: d))\(label.isEmpty ? "" : " (\(label))")")
        }
        return input + "\n\nCalendar: " + rows.joined(separator: "; ")
    }
}

/// Code-side check of the model's mention matches. The model proposes (id + quote); a match survives only if the quote is
/// really in the transcript, names the person with capital letters, and is specific enough when the first name is shared
/// or is also an ordinary word. Small models invent matches; this is cheap, deterministic and testable.
enum EvalMentionVerifier {
    static let ordinaryWords: Set<String> = ["will", "may", "mark", "grace", "bill", "april", "june", "august", "rose", "hope", "joy", "dawn", "faith", "chase", "art", "pat", "sue", "jack", "frank", "van"]

    struct Known { var id: String, first: String, last: String, org: String }

    static func parseKnown(_ input: String) -> [Known] {
        input.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- "), let colon = line.firstIndex(of: ":") else { return nil }
            let id = String(line[line.index(line.startIndex, offsetBy: 2) ..< colon])
            let rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard let paren = rest.lastIndex(of: "(") else { return nil }
            let name = rest[..<paren].trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard name.count >= 2 else { return nil }
            let org = rest[rest.index(after: paren)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
            return Known(id: id, first: name[0], last: name.dropFirst().joined(separator: " "), org: org)
        }
    }

    static func hasWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil
    }

    /// matches: (id, quote) pairs from the model.
    static func verify(matches: [(id: String, quote: String)], input: String) -> [String] {
        let known = self.parseKnown(input)
        let transcript = input.components(separatedBy: "Transcript:").last ?? input
        var ids: [String] = []
        for m in matches {
            guard let p = known.first(where: { $0.id == m.id }), transcript.contains(m.quote) else { continue }
            let quote = m.quote
            let hasFull = quote.contains(p.first + " " + p.last) || (hasWord(transcript, p.first + " " + p.last))
            let hasFirst = hasWord(quote, p.first)
            let hasLast = hasWord(quote, p.last)
            let sharesFirst = known.filter { $0.first == p.first }.count > 1
            let hasOrg = quote.contains(p.org) && hasFirst
            if hasFull || hasLast || hasOrg {
                ids.append(m.id)
            } else if hasFirst && !sharesFirst && !ordinaryWords.contains(p.first.lowercased()) {
                ids.append(m.id)
            }
        }
        return Array(Set(ids)).sorted()
    }
}
