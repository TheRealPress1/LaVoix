import Foundation

/// Small models sometimes resolve "Thursday" or "in two days" into a specific calendar date that nobody said.
/// A wrong date in meeting notes is worse than no date, so any month-and-day in the output that the
/// speakers (or the user's notes) never actually said is removed.
nonisolated enum MeetingNotesDateGuard {
    private static let months = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    private static let ones: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
    ]

    private static let simple: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
    ]

    private static func isMonth(_ token: String) -> Bool {
        self.months.contains(token) || ["jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"].contains(token)
    }

    static func apply(to output: String, source: String) -> String {
        let spoken = self.datesSaid(in: source)
        let sourceLower = source.lowercased()
        var result = output

        // 1. "Thursday, November 12": the speaker said the weekday; keep only that.
        let withWeekday = #"\b((?:Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day),? ("# + self.monthPattern + #") (\d{1,2})(?:st|nd|rd|th)?(?:,? \d{4})?"#
        result = self.replace(withWeekday, in: result) { groups in
            let key = "\(Self.monthKey(groups[2]))-\(groups[3])"
            return spoken.contains(key) ? nil : groups[1]
        }

        // 2. Any other "Month day[, year]" that was never said is dropped along with its lead-in word.
        let plain = #"(?:\b(?:by|on|for|before|until|through|due|from) )?\b("# + self.monthPattern + #") (\d{1,2})(?:st|nd|rd|th)?(,? \d{4})?"#
        result = self.replace(plain, in: result) { groups in
            let key = "\(Self.monthKey(groups[1]))-\(groups[2])"
            guard spoken.contains(key) else { return "" }
            // The date was said; the year was probably inferred.
            if !groups[3].isEmpty, !sourceLower.contains(groups[3].trimmingCharacters(in: CharacterSet(charactersIn: ", "))) {
                return String(groups[0].dropLast(groups[3].count))
            }
            return nil
        }

        return result.replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
    }

    // MARK: - Reading dates out of the source

    /// Every month-and-day that appears in the source, as "november-22", including spoken forms.
    static func datesSaid(in source: String) -> Set<String> {
        let tokens = source.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var found = Set<String>()
        for (index, token) in tokens.enumerated() where self.isMonth(token) {
            var rest = Array(tokens[(index + 1)...].prefix(3))
            if rest.first == "the" { rest.removeFirst() }
            if let day = self.day(from: rest) { found.insert("\(Self.monthKey(token))-\(day)") }
        }
        // "the twenty second of November" / "22nd of november"
        for (index, token) in tokens.enumerated() where token == "of" && index + 1 < tokens.count && self.isMonth(tokens[index + 1]) {
            let before = Array(tokens[max(0, index - 2) ..< index])
            if let day = self.day(fromTrailing: before) { found.insert("\(Self.monthKey(tokens[index + 1]))-\(day)") }
        }
        return found
    }

    private static func day(from words: [String]) -> Int? {
        guard let first = words.first else { return nil }
        if let number = self.digits(first) { return number }
        if let tens = self.simple[first] {
            if (first == "twenty" || first == "thirty"), words.count > 1, let unit = self.ones[words[1]] { return tens + unit }
            return tens
        }
        return self.ones[first]
    }

    private static func day(fromTrailing words: [String]) -> Int? {
        if words.count == 2, let tens = self.simple[words[0]], tens == 20 || tens == 30, let unit = self.ones[words[1]] { return tens + unit }
        guard let last = words.last else { return nil }
        return self.digits(last) ?? self.simple[last] ?? self.ones[last]
    }

    private static func digits(_ token: String) -> Int? {
        let stripped = token.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
        guard let value = Int(stripped), (1 ... 31).contains(value) else { return nil }
        return value
    }

    // MARK: - Regex helper

    private static var monthPattern: String {
        "January|February|March|April|May|June|July|August|September|October|November|December"
            + "|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
    }

    /// "November", "Nov" and "nov." all map to "nov".
    private static func monthKey(_ month: String) -> String {
        String(month.lowercased().prefix(3))
    }

    /// Replaces each match with `transform(groups)`; returning nil keeps the original text.
    private static func replace(_ pattern: String, in text: String, transform: ([String]) -> String?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            var groups: [String] = []
            for index in 0 ..< match.numberOfRanges {
                groups.append(Range(match.range(at: index), in: result).map { String(result[$0]) } ?? "")
            }
            guard let whole = Range(match.range, in: result), let replacement = transform(groups) else { continue }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
}
