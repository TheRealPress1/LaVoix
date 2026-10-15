import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Something that can answer an eval case. Backends only ever see synthetic text.
protocol EvalBackend {
    var name: String { get }
    /// Nil when usable, otherwise why not (model missing, Apple Intelligence off, ...).
    func unavailableReason() async -> String?
    func answer(_ c: EvalCase) async throws -> EvalAnswer
}

// MARK: - Reference backends (validate the scorers themselves)

/// Returns the expected answer: must score 100%.
struct OracleEvalBackend: EvalBackend {
    let name = "oracle"
    func unavailableReason() async -> String? { nil }
    func answer(_ c: EvalCase) async throws -> EvalAnswer { c.expected }
}

/// Always says "nothing / unknown": shows what a do-nothing model scores on the negative cases.
struct EmptyEvalBackend: EvalBackend {
    let name = "empty"
    func unavailableReason() async -> String? { nil }
    func answer(_ c: EvalCase) async throws -> EvalAnswer {
        switch c.task {
        case .mentions: return .mentions(ids: [])
        case .facts: return .facts([])
        case .commitments: return .commitments([])
        case .qa: return .qa(answer: "unknown", answerable: false)
        }
    }
}

// MARK: - Text backends (JSON out of free text)

enum EvalJSON {
    private struct Mentions: Decodable { var ids: [String]? }
    private struct Facts: Decodable { var facts: [EvalFact]? }
    private struct Commitments: Decodable { var items: [EvalCommitment]? }
    private struct QA: Decodable { var answer: String?; var answerable: Bool? }

    static func prompt(_ c: EvalCase) -> String {
        c.system + "\n\nReply with ONLY a JSON object of exactly this shape, no other text: " + c.jsonShape
    }

    static func extractObject(_ raw: String) -> Data? {
        var text = raw
        while let open = text.range(of: "<think>"), let close = text.range(of: "</think>"), open.lowerBound < close.upperBound {
            text.removeSubrange(open.lowerBound ..< close.upperBound)
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start ... end]).data(using: .utf8)
    }

    static func decode(_ task: EvalTask, from raw: String) throws -> EvalAnswer {
        guard let data = extractObject(raw) else { throw EvalError.unparseable(String(raw.prefix(80))) }
        let d = JSONDecoder()
        do {
            switch task {
            case .mentions: return .mentions(ids: try d.decode(Mentions.self, from: data).ids ?? [])
            case .facts: return .facts(try d.decode(Facts.self, from: data).facts ?? [])
            case .commitments: return .commitments(try d.decode(Commitments.self, from: data).items ?? [])
            case .qa:
                let q = try d.decode(QA.self, from: data)
                return .qa(answer: q.answer ?? "", answerable: q.answerable ?? false)
            }
        } catch {
            throw EvalError.unparseable(String(raw.prefix(80)))
        }
    }
}

enum EvalError: Error, CustomStringConvertible {
    case unparseable(String)
    case failed(String)
    var description: String {
        switch self {
        case let .unparseable(s): return "unparseable output: \(s)"
        case let .failed(s): return s
        }
    }
}

/// MLX model run in-process through the same engine dictation cleanup uses.
struct MLXEvalBackend: EvalBackend {
    let modelID: String
    var name: String { "mlx:" + (modelID.split(separator: "/").last.map(String.init) ?? modelID) }

    func unavailableReason() async -> String? {
        do { try await LocalCleanupEngine.shared.prepare(modelID: modelID); return nil } catch { return "\(error)" }
    }

    func answer(_ c: EvalCase) async throws -> EvalAnswer {
        let raw = try await LocalCleanupEngine.shared.generate(
            system: EvalJSON.prompt(c), user: c.input, modelID: modelID, maxTokens: 500, temperature: 0, cachesPrefix: false
        )
        return try EvalJSON.decode(c.task, from: raw)
    }
}

/// The user's own command (e.g. `claude -p`): prompt on stdin, answer on stdout. Cloud ceiling for comparison; it only
/// ever receives the synthetic corpus.
struct CommandEvalBackend: EvalBackend {
    let command: String
    var name: String { "cmd:" + command }

    func unavailableReason() async -> String? { nil }

    func answer(_ c: EvalCase) async throws -> EvalAnswer {
        let prompt = EvalJSON.prompt(c) + "\n\n" + c.input
        let raw = try await Self.run(command: command, stdin: prompt)
        return try EvalJSON.decode(c.task, from: raw)
    }

    static func run(command: String, stdin: String, timeout: TimeInterval = 180) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/zsh")
                p.arguments = ["-lc", command]
                let inPipe = Pipe(), outPipe = Pipe()
                p.standardInput = inPipe
                p.standardOutput = outPipe
                p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(throwing: EvalError.failed("\(error)")); return }
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }
}

// MARK: - Apple on-device model with guided generation

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable struct AppleMentions {
    @Guide(description: "ids of the known people who are clearly mentioned; empty if none")
    var ids: [String]
}

@available(macOS 26.0, *)
@Generable struct AppleFact {
    @Guide(description: "one of: city, employer, birthday, partner, pet")
    var kind: String
    var value: String
}

@available(macOS 26.0, *)
@Generable struct AppleFacts {
    var facts: [AppleFact]
}

@available(macOS 26.0, *)
@Generable struct AppleCommitment {
    @Guide(description: "me or them")
    var owner: String
    var what: String
    @Guide(description: "deadline as yyyy-MM-dd, or an empty string when there is none")
    var due: String
}

@available(macOS 26.0, *)
@Generable struct AppleCommitments {
    var items: [AppleCommitment]
}

@available(macOS 26.0, *)
@Generable struct AppleQA {
    @Guide(description: "short answer, or the word unknown")
    var answer: String
    @Guide(description: "false when the notes do not contain the answer")
    var answerable: Bool
}

@available(macOS 26.0, *)
struct AppleEvalBackend: EvalBackend {
    let name = "apple-foundation"

    func unavailableReason() async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case let .unavailable(reason): return "Apple on-device model unavailable: \(reason)"
        }
    }

    func answer(_ c: EvalCase) async throws -> EvalAnswer {
        let session = LanguageModelSession(instructions: c.system)
        switch c.task {
        case .mentions:
            return .mentions(ids: try await session.respond(to: c.input, generating: AppleMentions.self).content.ids)
        case .facts:
            let r = try await session.respond(to: c.input, generating: AppleFacts.self).content
            return .facts(r.facts.map { EvalFact(kind: $0.kind, value: $0.value) })
        case .commitments:
            let r = try await session.respond(to: c.input, generating: AppleCommitments.self).content
            return .commitments(r.items.map { EvalCommitment(owner: $0.owner, what: $0.what, due: $0.due.isEmpty ? nil : $0.due) })
        case .qa:
            let r = try await session.respond(to: c.input, generating: AppleQA.self).content
            return .qa(answer: r.answer, answerable: r.answerable)
        }
    }
}
#endif
