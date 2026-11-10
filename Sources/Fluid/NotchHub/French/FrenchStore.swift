import Combine
import Foundation
import NaturalLanguage

/// The French tab's switch. The correcting itself is done by myOS (through the user's Claude login), so the tab only shows when myOS is installed.
enum NotchFrenchSettings {
    private static let enabledKey = "LaVoixNotchFrenchEnabled"

    private static let targetKey = "LaVoixNotchProofreadTarget"
    private static let toneKey = "LaVoixNotchTranslateTone"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    /// The language the tab writes in (chosen at the top right of the tab), kept between launches. French until another is chosen.
    static var targetLanguage: CorrectionLanguage {
        get { UserDefaults.standard.string(forKey: self.targetKey).flatMap(CorrectionLanguage.init(rawValue:)) ?? .french }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: self.targetKey) }
    }
}

extension NotchFrenchSettings {
    /// How formal a translation should be, kept between launches. Automatic until another is chosen.
    static var tone: FrenchTone {
        get { UserDefaults.standard.string(forKey: self.toneKey).flatMap(FrenchTone.init(rawValue:)) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: self.toneKey) }
    }
}

/// How formal a translation is. Automatic keeps the level the text shows (and is polite when it shows none); the other two ask for the formal or the
/// informal way of addressing someone (vous or tu, Sie or du, usted or tú). It only applies to a translation: a correction keeps the writer's own voice.
enum FrenchTone: String, CaseIterable {
    case auto, formal, casual

    var label: String {
        switch self {
        case .auto: "Auto"
        case .formal: "Formal"
        case .casual: "Casual"
        }
    }

    /// The next one when the tone button is pressed.
    var next: FrenchTone {
        switch self {
        case .auto: .formal
        case .formal: .casual
        case .casual: .auto
        }
    }

    /// What goes to myOS: nothing for automatic.
    var wire: String { self == .auto ? "" : self.rawValue }
}

/// A language the tab writes in: the destination chosen at the top right. What is typed can be in any language (the tab detects it, and so does Claude);
/// it comes out in this one, corrected if it is already in it and translated if it is not. The raw value is the name myOS accepts and sends to Claude
/// (myOS refuses any other: its list is `LANGUAGES` in french.rs), so a language added here is added there too, and the order here is the order of the list.
enum CorrectionLanguage: String, CaseIterable, Identifiable {
    case french = "French"
    case english = "English"
    case spanish = "Spanish"
    case german = "German"
    case italian = "Italian"
    case portuguese = "Portuguese"

    var id: String { self.rawValue }
    var name: String { self.rawValue }

    /// Two letters, for the language bar.
    var code: String {
        switch self {
        case .french: "FR"
        case .english: "EN"
        case .spanish: "ES"
        case .german: "DE"
        case .italian: "IT"
        case .portuguese: "PT"
        }
    }

    /// The voice that reads a text in this language aloud.
    var voiceLanguage: String {
        switch self {
        case .french: "fr-FR"
        case .english: "en-US"
        case .spanish: "es-ES"
        case .german: "de-DE"
        case .italian: "it-IT"
        case .portuguese: "pt-BR"
        }
    }

    /// The language a name (as Claude writes it: "English", "french") stands for, when it is one of these.
    static func named(_ name: String?) -> CorrectionLanguage? {
        let clean = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return self.allCases.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }
    }

    var recognizerLanguage: NLLanguage {
        switch self {
        case .french: return .french
        case .english: return .english
        case .spanish: return .spanish
        case .german: return .german
        case .italian: return .italian
        case .portuguese: return .portuguese
        }
    }
}

/// One correction Claude made, with the rule behind it in a few words.
struct FrenchChange: Equatable, Identifiable {
    let id: Int
    let before: String
    let after: String
    let why: String
}

struct FrenchResult: Equatable {
    let corrected: String
    let changes: [FrenchChange]
    /// Something Claude wanted to say about the text as a whole (for instance an ambiguity it had to settle).
    let note: String?
    /// Set when the text was in another language and this is its translation (the language Claude named): there are no corrections to list or mark.
    var translatedFrom: String? = nil
}

/// A finished translation or correction, kept in memory only (until the notch restarts) so it can be brought back.
struct FrenchRecent: Identifiable, Equatable {
    let id = UUID()
    let input: String
    let result: FrenchResult
    let target: CorrectionLanguage
    /// The language the text was in, when it is one of the six.
    let source: CorrectionLanguage?
    let at: Date
}

enum FrenchPhase: Equatable {
    case idle
    case working
    /// The first time: say what is sent and ask. Nothing has been sent yet.
    case needsAllow
    case done(FrenchResult)
    case failed(String)
}

/// What the tab sends to myOS.
struct FrenchRequest: Equatable {
    let id: Int
    let text: String
    /// "Allow and correct": the one-time yes for sending what is typed here to Claude.
    let allow: Bool
    /// The language it should come out in (a `CorrectionLanguage` name).
    var target: String = CorrectionLanguage.french.rawValue
    /// "formal" or "casual" for a translation; empty leaves it to Claude (an older myOS ignores it).
    var tone = ""

    var json: String {
        var object: [String: Any] = ["id": self.id, "text": self.text, "allow": self.allow, "target": self.target]
        if !self.tone.isEmpty { object["tone"] = self.tone }
        guard let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Requests waiting for myOS, handed over by the `french.wait` long poll (the same way Look's events are). myOS asks again as soon as it has one.
actor FrenchRequests {
    static let shared = FrenchRequests()
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var token = 0
    private var lastActivity = Date.distantPast

    func push(_ json: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: json)
        } else {
            self.queue.append(json)
            if self.queue.count > 5 { self.queue.removeFirst() }
        }
    }

    /// The next request, or nil after `timeout` seconds.
    func next(timeout: TimeInterval) async -> String? {
        self.lastActivity = Date()
        if !self.queue.isEmpty { return self.queue.removeFirst() }
        if let old = self.waiter {
            self.waiter = nil
            old.resume(returning: nil)
        }
        self.token += 1
        let mine = self.token
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            self.waiter = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(mine)
            }
        }
    }

    private func expire(_ mine: Int) {
        guard mine == self.token, let waiter else { return }
        self.waiter = nil
        self.lastActivity = Date()
        waiter.resume(returning: nil)
    }

    /// Is myOS there to take a request? It is waiting now, or it only just stopped waiting (it asks again at once).
    func isListening() -> Bool {
        self.waiter != nil || Date().timeIntervalSince(self.lastActivity) < 6
    }
}

/// The text being corrected, and what came back. Nothing here is written to disk or logged.
@MainActor
final class FrenchStore: ObservableObject {
    static let shared = FrenchStore()

    @Published var input = "" {
        didSet { if self.input != oldValue { self.detected = Self.detect(self.input) } }
    }
    /// The language the typed text looks like, worked out on this Mac as it is typed (Claude names the real one in its answer). Nil when there is too
    /// little text or it does not clearly look like one of the languages the tab writes in.
    @Published private(set) var detected: CorrectionLanguage?
    /// The language it will come out in.
    @Published private(set) var destination: CorrectionLanguage
    @Published private(set) var phase: FrenchPhase = .idle
    @Published private(set) var tone: FrenchTone
    /// The language the text in the shown result was in, when it is one of the six: what the swap button turns the destination into.
    @Published private(set) var resultSource: CorrectionLanguage?
    /// The last finished results, newest first. In memory only: nothing of what is typed is written anywhere.
    @Published private(set) var recent: [FrenchRecent] = []
    static let maxRecent = 8
    private var detectedAtRequest: CorrectionLanguage?
    /// What the shown result was made from (so the words that changed can be marked).
    @Published private(set) var correctedFrom = ""

    private var requestID = 0
    private var timeout: Task<Void, Never>?
    static let maxCharacters = 6000
    /// How long a correction may take before the tab gives up.
    static let giveUpAfter: TimeInterval = 90

    /// Keeps the chosen destination between launches. Tests replace this so they never touch the real setting.
    var persist: (CorrectionLanguage) -> Void = { NotchFrenchSettings.targetLanguage = $0 }
    var persistTone: (FrenchTone) -> Void = { NotchFrenchSettings.tone = $0 }

    init(destination: CorrectionLanguage = NotchFrenchSettings.targetLanguage, tone: FrenchTone = NotchFrenchSettings.tone) {
        self.destination = destination
        self.tone = tone
    }

    /// How a request reaches myOS. Tests replace this.
    var send: (FrenchRequest) -> Void = { request in
        Task { await FrenchRequests.shared.push(request.json) }
    }
    /// Is myOS listening for requests? Tests replace this.
    var isListening: () async -> Bool = { await FrenchRequests.shared.isListening() }

    var phaseIsDone: Bool {
        if case .done = self.phase { return true }
        return false
    }

    /// Will pressing the button translate (the text looks like another language than the destination) rather than correct?
    var willTranslate: Bool {
        guard let detected = self.detected else { return false }
        return detected != self.destination
    }

    /// Which of the languages the tab writes in the text looks like, or nil when it cannot tell (too little text, or no clear winner).
    nonisolated static func detect(_ text: String) -> CorrectionLanguage? {
        let sample = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(800))
        guard sample.filter(\.isLetter).count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = CorrectionLanguage.allCases.map(\.recognizerLanguage)
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.6 else { return nil }
        return CorrectionLanguage.allCases.first { $0.recognizerLanguage == best.key }
    }

    var canCorrect: Bool {
        if case .working = self.phase { return false }
        return !self.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Sends what is typed. The first time myOS answers that it needs a yes, and the tab asks; `allow` is that yes.
    func correct(allow: Bool = false) {
        guard self.canCorrect else { return }
        let text = String(self.input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxCharacters))
        self.requestID += 1
        let id = self.requestID
        self.correctedFrom = text
        self.detectedAtRequest = self.detected
        self.phase = .working
        // The tone only matters when the text is turned into another language.
        self.send(FrenchRequest(id: id, text: text, allow: allow, target: self.destination.rawValue, tone: self.willTranslate ? self.tone.wire : ""))
        self.timeout?.cancel()
        self.timeout = Task { [weak self] in
            // myOS not being there is the common reason for silence: say so quickly instead of after a minute and a half.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled, self.requestID == id, self.phase == .working else { return }
            if await !self.isListening() {
                self.finish(id: id, .failed("myOS isn't running, and it does the correcting. Open myOS and try again."))
                return
            }
            try? await Task.sleep(nanoseconds: UInt64((Self.giveUpAfter - 4) * 1_000_000_000))
            guard !Task.isCancelled, self.requestID == id, self.phase == .working else { return }
            self.finish(id: id, .failed("Claude took too long. Try again."))
        }
    }

    private func finish(id: Int, _ phase: FrenchPhase) {
        guard id == self.requestID else { return }
        self.timeout?.cancel()
        self.phase = phase
    }

    /// myOS's answer. False when it is for a request that is no longer the current one (the text was corrected again since).
    @discardableResult
    func receive(_ object: [String: Any]) -> Bool {
        guard let id = (object["id"] as? NSNumber)?.intValue, id == self.requestID, self.phase == .working else { return false }
        if object["needs_allow"] as? Bool == true {
            self.finish(id: id, .needsAllow)
        } else if let error = object["error"] as? String, !error.isEmpty {
            self.finish(id: id, .failed(String(error.prefix(300))))
        } else if let corrected = object["corrected"] as? String {
            // A translation is one piece of new text, not a list of fixes, whatever the answer lists.
            let translated = (object["mode"] as? String) == "translated"
            let source = (object["source"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 }
            let raw = translated ? [] : (object["changes"] as? [[String: Any]] ?? [])
            let changes = raw.prefix(40).enumerated().compactMap { index, c -> FrenchChange? in
                guard let before = c["before"] as? String, let after = c["after"] as? String, before != after else { return nil }
                return FrenchChange(id: index, before: String(before.prefix(200)), after: String(after.prefix(200)), why: String((c["why"] as? String ?? "").prefix(200)))
            }
            let note = (object["note"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String($0.prefix(300)) }
            let result = FrenchResult(corrected: corrected, changes: changes, note: note, translatedFrom: translated ? (source ?? "another language") : nil)
            // A correction is in the language it comes out in; a translation was in the language Claude named (else the one the typing looked like).
            self.resultSource = translated ? (CorrectionLanguage.named(source) ?? self.detectedAtRequest) : self.destination
            self.finish(id: id, .done(result))
            self.remember(FrenchRecent(input: self.correctedFrom, result: result, target: self.destination, source: self.resultSource, at: Date()))
        } else {
            self.finish(id: id, .failed("myOS sent an answer this tab could not read."))
        }
        return true
    }

    private func remember(_ item: FrenchRecent) {
        // The same text into the same language again replaces its earlier entry instead of stacking up.
        self.recent.removeAll { $0.input == item.input && $0.target == item.target }
        self.recent.insert(item, at: 0)
        if self.recent.count > Self.maxRecent { self.recent.removeLast(self.recent.count - Self.maxRecent) }
    }

    /// Brings an earlier result back, with the text and the language it was made for.
    func restore(_ item: FrenchRecent) {
        if case .working = self.phase { return }
        self.timeout?.cancel()
        self.requestID += 1
        if item.target != self.destination {
            self.destination = item.target
            self.persist(item.target)
        }
        self.input = item.input
        self.correctedFrom = item.input
        self.resultSource = item.source
        self.phase = .done(item.result)
    }

    func clearRecent() { self.recent = [] }

    /// Is there a translation that can be turned round: the text it was made from was in one of the languages, and not the one it came out in.
    var canSwap: Bool {
        guard case .done = self.phase, let source = self.resultSource else { return false }
        return source != self.destination
    }

    /// Puts the translation in the box and makes the language it came from the destination, so the same text goes back the other way (and a reply to
    /// it goes out in the language it arrived in).
    func swapLanguages() {
        guard self.canSwap, case let .done(result) = self.phase, let back = self.resultSource else { return }
        self.timeout?.cancel()
        self.requestID += 1
        self.destination = back
        self.persist(back)
        self.input = result.corrected
        self.correctedFrom = ""
        self.resultSource = nil
        self.phase = .idle
    }

    /// The tone button: automatic, then formal, then casual.
    func cycleTone() {
        self.tone = self.tone.next
        self.persistTone(self.tone)
    }

    /// Puts the corrected text into the box, to go on editing it.
    func keepEditing() {
        guard case let .done(result) = self.phase else { return }
        self.input = result.corrected
        self.phase = .idle
    }

    /// A result is for the language it was made in, so choosing another destination puts the shown result away.
    func select(_ language: CorrectionLanguage) {
        guard language != self.destination else { return }
        self.destination = language
        self.persist(language)
        self.dismissResult()
    }

    func clear() {
        self.timeout?.cancel()
        self.requestID += 1
        self.input = ""
        self.correctedFrom = ""
        self.resultSource = nil
        self.phase = .idle
    }

    /// For previews and tests: shows a phase without sending anything.
    func debugShow(_ phase: FrenchPhase, from text: String = "", source: CorrectionLanguage? = nil) {
        self.phase = phase
        self.correctedFrom = text
        self.resultSource = source
    }

    /// For previews: fills the recent list without sending anything.
    func debugRecent(_ items: [FrenchRecent]) { self.recent = items }

    /// Back to the typed text, with whatever was shown put away (a result is for the text it was made from).
    func dismissResult() {
        if self.phase != .working { self.phase = .idle }
    }
}

/// Which words of a corrected text are not in the text it came from, so they can be marked. Spaces are never marked: French typography moves
/// them around (a thin space before a colon), and that is not a mistake the writer made.
nonisolated enum FrenchDiff {
    private enum Kind { case word, space, mark }
    private struct Token { let text: String; let kind: Kind; let range: Range<String.Index> }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var i = text.startIndex
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace {
                var j = text.index(after: i)
                while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
                result.append(Token(text: " ", kind: .space, range: i..<j))
                i = j
            } else if isWordCharacter(c) {
                var j = text.index(after: i)
                while j < text.endIndex {
                    let d = text[j]
                    if isWordCharacter(d) { j = text.index(after: j); continue }
                    // An apostrophe or a hyphen between two letters stays inside the word (l'équipe, peut-être).
                    if d == "'" || d == "\u{2019}" || d == "-", text.index(after: j) < text.endIndex, isWordCharacter(text[text.index(after: j)]) {
                        j = text.index(after: j)
                        continue
                    }
                    break
                }
                result.append(Token(text: String(text[i..<j]), kind: .word, range: i..<j))
                i = j
            } else {
                let j = text.index(after: i)
                result.append(Token(text: String(c), kind: .mark, range: i..<j))
                i = j
            }
        }
        return result
    }

    static let maxTokens = 1500

    /// The stretches of `new` that were not in `old` (words and punctuation, not spaces). Empty when the texts are too long to compare.
    static func changedRanges(old: String, new: String) -> [Range<String.Index>] {
        let a = self.tokens(old), b = self.tokens(new)
        guard !a.isEmpty, !b.isEmpty, a.count <= self.maxTokens, b.count <= self.maxTokens else { return [] }
        func same(_ x: Token, _ y: Token) -> Bool { x.kind == y.kind && (x.kind == .space || x.text == y.text) }
        // Longest common subsequence of the two token lists.
        let n = a.count, m = b.count
        var table = [UInt16](repeating: 0, count: (n + 1) * (m + 1))
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i * (m + 1) + j] = same(a[i], b[j])
                    ? table[(i + 1) * (m + 1) + j + 1] + 1
                    : max(table[(i + 1) * (m + 1) + j], table[i * (m + 1) + j + 1])
            }
        }
        var kept = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if same(a[i], b[j]) { kept.insert(j); i += 1; j += 1 }
            else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] { i += 1 }
            else { j += 1 }
        }
        var ranges: [Range<String.Index>] = []
        for (index, token) in b.enumerated() where !kept.contains(index) && token.kind != .space {
            // Neighbouring changed words become one stretch, so "les meilleurs délais" is marked once, not word by word with gaps.
            if let last = ranges.last, index >= 2, !kept.contains(index - 2), b[index - 1].kind == .space, last.upperBound == b[index - 2].range.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<token.range.upperBound
            } else {
                ranges.append(token.range)
            }
        }
        return ranges
    }
}
