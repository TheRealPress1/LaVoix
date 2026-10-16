import CryptoKit
import Foundation

/// Your own corrections, kept on this Mac to train a personal model later. Two folders under
/// `~/Library/Application Support/LaVoix/TrainingData` (owner-only, never in an iCloud folder):
///
/// - `prompts/`: what the model was given and wrote for each set of meeting notes (one small file per set, keyed by a hash of
///   the notes). Needed so a rating can be tied to the exact input. Old ones are removed after 30 days.
/// - `examples/`: the notes you rated, with your rating and, if you fixed them, your corrected version.
///
/// Nothing is collected unless you rate or correct notes, nothing leaves the Mac, and `clear` removes all of it.
nonisolated enum TrainingData {
    static let promptRetention: TimeInterval = 30 * 86_400
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        self.rootOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/LaVoix/TrainingData", isDirectory: true)
    }

    private static var promptsDir: URL { self.root.appendingPathComponent("prompts", isDirectory: true) }
    private static var examplesDir: URL { self.root.appendingPathComponent("examples", isDirectory: true) }
    static var exportDir: URL { self.root.appendingPathComponent("export", isDirectory: true) }

    enum Rating: String, CaseIterable { case good, bad, edited }

    enum Failure: LocalizedError, Equatable {
        case noRecord, emptyText, badRating
        var errorDescription: String? {
            switch self {
            case .noRecord: "These notes were written before feedback was available. Rewrite them, then rate the new version."
            case .emptyText: "The corrected notes can't be empty."
            case .badRating: "The rating must be good, bad or edited."
            }
        }
    }

    // MARK: Files

    private static func prepare(_ dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    private static func write(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func read(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func exampleURL(meeting: UUID, kind: String) -> URL {
        self.examplesDir.appendingPathComponent("\(meeting.uuidString)-\(kind.filter { $0.isLetter || $0.isNumber }).json")
    }

    // MARK: Recording what the model saw

    /// Called each time notes are written. Best effort: a failure here never affects the notes.
    static func recordPrompt(system: String, user: String, model: String, output: String) {
        do {
            try self.prepare(self.promptsDir)
            try self.write(["system": system, "user": user, "model": model, "created": Date().timeIntervalSince1970], to: self.promptsDir.appendingPathComponent("\(self.hash(output)).json"))
            self.pruneOldPrompts()
        } catch {}
    }

    private static func pruneOldPrompts(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: self.promptsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for f in files {
            let modified = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > self.promptRetention { try? fm.removeItem(at: f) }
        }
    }

    // MARK: Rating

    /// Ties a rating (and your corrected notes, for `edited`) to the exact input the model was given. `notes` is what the
    /// notes say now; for a first rating that is the model's own output, and for a later one the example already exists.
    @discardableResult
    static func rate(meeting: UUID, kind: String, rating: Rating, notes: String, corrected: String?) throws -> [String: Any] {
        let fixed = corrected?.trimmingCharacters(in: .whitespacesAndNewlines)
        if rating == .edited, fixed?.isEmpty != false { throw Failure.emptyText }
        try self.prepare(self.examplesDir)
        let url = self.exampleURL(meeting: meeting, kind: kind)
        var example = self.read(url) ?? [:]
        if example["system"] == nil {
            guard let record = self.read(self.promptsDir.appendingPathComponent("\(self.hash(notes)).json")), let system = record["system"], let user = record["user"] else { throw Failure.noRecord }
            example = ["id": "\(meeting.uuidString)-\(kind)", "meeting": meeting.uuidString, "kind": kind, "created": Date().timeIntervalSince1970,
                       "model": record["model"] ?? "", "system": system, "user": user, "output": notes.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        example["rating"] = rating.rawValue
        example["updated"] = Date().timeIntervalSince1970
        example["corrected"] = rating == .edited ? fixed : nil
        try self.write(example, to: url)
        return self.summary(of: example)
    }

    /// The rating on file for a meeting's notes, without any of the text.
    static func rating(meeting: UUID, kind: String) -> String? {
        self.read(self.exampleURL(meeting: meeting, kind: kind))?["rating"] as? String
    }

    /// Whether these notes can be rated (their input was recorded), or already have been.
    static func canRate(meeting: UUID, kind: String, notes: String) -> Bool {
        FileManager.default.fileExists(atPath: self.exampleURL(meeting: meeting, kind: kind).path)
            || FileManager.default.fileExists(atPath: self.promptsDir.appendingPathComponent("\(self.hash(notes)).json").path)
    }

    private static func summary(of example: [String: Any]) -> [String: Any] {
        ["meeting": example["meeting"] ?? "", "kind": example["kind"] ?? "", "rating": example["rating"] ?? ""]
    }

    // MARK: Status, export, clear

    private static func examples() -> [[String: Any]] {
        ((try? FileManager.default.contentsOfDirectory(at: self.examplesDir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.compactMap { self.read($0) }
    }

    /// Numbers only.
    static func status() -> [String: Any] {
        let all = self.examples()
        func count(_ r: Rating) -> Int { all.filter { $0["rating"] as? String == r.rawValue }.count }
        let usable = count(.good) + count(.edited)
        let prompts = ((try? FileManager.default.contentsOfDirectory(at: self.promptsDir, includingPropertiesForKeys: nil)) ?? []).count
        return ["good": count(.good), "bad": count(.bad), "edited": count(.edited), "usable": usable, "unrated_inputs": prompts, "folder": self.root.path]
    }

    /// Writes `train.jsonl` and `valid.jsonl` in the chat format `mlx_lm.lora` reads. Good notes teach the model's own
    /// output, edited notes teach your correction; notes marked bad without a correction are left out. About one in ten
    /// examples goes to validation, chosen by a hash of its id so the split is the same every time.
    static func export() throws -> [String: Any] {
        let usable = self.examples().filter { ($0["rating"] as? String) != "bad" }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        try self.prepare(self.exportDir)
        func line(_ e: [String: Any]) -> String? {
            guard let system = e["system"] as? String, let user = e["user"] as? String,
                  let answer = (e["rating"] as? String == "edited" ? e["corrected"] : e["output"]) as? String, !answer.isEmpty else { return nil }
            let messages: [[String: String]] = [["role": "system", "content": system], ["role": "user", "content": user], ["role": "assistant", "content": answer]]
            return (try? JSONSerialization.data(withJSONObject: ["messages": messages], options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) }
        }
        var train: [String] = [], valid: [String] = []
        for e in usable {
            guard let l = line(e) else { continue }
            let bucket = Int(Array(SHA256.hash(data: Data((e["id"] as? String ?? "").utf8))).first ?? 1) % 10
            if bucket == 0 { valid.append(l) } else { train.append(l) }
        }
        if valid.isEmpty, train.count >= 2 { valid.append(train.removeLast()) }
        try (train.joined(separator: "\n") + (train.isEmpty ? "" : "\n")).write(to: self.exportDir.appendingPathComponent("train.jsonl"), atomically: true, encoding: .utf8)
        try (valid.joined(separator: "\n") + (valid.isEmpty ? "" : "\n")).write(to: self.exportDir.appendingPathComponent("valid.jsonl"), atomically: true, encoding: .utf8)
        for name in ["train.jsonl", "valid.jsonl"] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.exportDir.appendingPathComponent(name).path) }
        return ["train": train.count, "valid": valid.count, "folder": self.exportDir.path]
    }

    /// Removes everything: recorded inputs, ratings, corrections and exports.
    static func clear() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
