import Foundation

/// Headless evaluation of on-device models on the synthetic corpus. Run the app binary with `LAVOIX_EVAL=1`:
///   LAVOIX_EVAL_BACKENDS   comma list of: oracle, empty, apple, mlx[:<hf repo>], cmd[:<shell command>]  (default oracle,empty)
///   LAVOIX_EVAL_N          cases per task (default 8, which covers every variant once)
///   LAVOIX_EVAL_SEED       corpus seed (default 1)
///   LAVOIX_EVAL_OUT        write the full results as JSON to this path
///   LAVOIX_EVAL_PROMPT     base (default) or tuned: prompt variant for the text backends (mlx, cmd)
///   LAVOIX_EVAL_TASKS      comma list to restrict to (mentions,facts,commitments,qa)
///   LAVOIX_EVAL_DUMP       comma list of case ids to print (input + expected) instead of running
///   LAVOIX_EVAL_VERBOSE=1  print every failing case, not just the first few per task
/// The oracle backend must score 100% (it checks the scorers); the empty backend shows the floor.
enum EvalRunner {
    struct CaseResult: Codable {
        var id: String, task: String, variant: String
        var pass: Bool, value: Double, seconds: Double, note: String
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["LAVOIX_EVAL"] == "1" else { return }
        Task.detached {
            func out(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
            let n = Int(env["LAVOIX_EVAL_N"] ?? "") ?? 8
            let seed = UInt64(env["LAVOIX_EVAL_SEED"] ?? "") ?? 1
            let verbose = env["LAVOIX_EVAL_VERBOSE"] == "1"
            let only = env["LAVOIX_EVAL_TASKS"]?.split(separator: ",").map(String.init)
            let cases = EvalCorpus.cases(seed: seed, perTask: n).filter { only == nil || only!.contains($0.task.rawValue) }
            out("corpus: \(cases.count) synthetic cases, seed \(seed)")
            if let dump = env["LAVOIX_EVAL_DUMP"] {
                for c in cases where dump.split(separator: ",").contains(Substring(c.id)) { out("\n--- \(c.id) [\(c.variant)]\n\(c.input)\nEXPECTED: \(c.expected)") }
                exit(0)
            }

            var backends: [EvalBackend] = []
            for spec in (env["LAVOIX_EVAL_BACKENDS"] ?? "oracle,empty").split(separator: ",").map(String.init) {
                let (kind, arg) = spec.split(separator: ":", maxSplits: 1).map(String.init).splitHead()
                switch kind {
                case "oracle": backends.append(OracleEvalBackend())
                case "empty": backends.append(EmptyEvalBackend())
                case "mlx": backends.append(MLXEvalBackend(modelID: arg ?? LocalCleanupProvider.defaultModelID))
                case "cmd": backends.append(CommandEvalBackend(command: arg ?? "claude -p"))
                case "apple":
                    #if canImport(FoundationModels)
                    if #available(macOS 26.0, *) { backends.append(AppleEvalBackend()) } else { out("apple: needs macOS 26") }
                    #else
                    out("apple: FoundationModels not in this SDK")
                    #endif
                default: out("unknown backend '\(spec)'")
                }
            }

            var all: [String: [CaseResult]] = [:]
            for backend in backends {
                out("\n=== \(backend.name)")
                if let why = await backend.unavailableReason() { out("  skipped: \(why)"); continue }
                var results: [CaseResult] = []
                for c in cases {
                    let start = Date()
                    var r = CaseResult(id: c.id, task: c.task.rawValue, variant: c.variant, pass: false, value: 0, seconds: 0, note: "")
                    do {
                        let score = EvalScoring.score(c, answer: try await backend.answer(c))
                        r.pass = score.pass; r.value = score.value; r.note = score.note
                    } catch {
                        r.note = "error: \(error)"
                    }
                    r.seconds = Date().timeIntervalSince(start)
                    results.append(r)
                }
                all[backend.name] = results
                for task in EvalTask.allCases {
                    let rs = results.filter { $0.task == task.rawValue }
                    guard !rs.isEmpty else { continue }
                    let passed = rs.filter(\.pass).count
                    let avg = rs.map(\.seconds).reduce(0, +) / Double(rs.count)
                    out(String(format: "  %-12@ pass %2d/%-2d  score %.2f  avg %.2fs", task.rawValue as NSString, passed, rs.count, rs.map(\.value).reduce(0, +) / Double(rs.count), avg))
                    for f in rs.filter({ !$0.pass }).prefix(verbose ? 100 : 3) { out("      FAIL \(f.id) [\(f.variant)] \(f.note)") }
                }
                let passed = results.filter(\.pass).count
                out(String(format: "  TOTAL        pass %d/%d (%.0f%%)", passed, results.count, 100 * Double(passed) / Double(max(results.count, 1))))
            }

            if let path = env["LAVOIX_EVAL_OUT"], let data = try? JSONEncoder().encode(all) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            // The oracle exists to prove the scorers work: anything below 100% is a harness bug.
            if let oracle = all["oracle"], oracle.contains(where: { !$0.pass }) {
                out("\nEVAL HARNESS BROKEN: oracle did not score 100%")
                exit(1)
            }
            out("\nEVAL DONE")
            exit(0)
        }
    }
}

private extension Array where Element == String {
    func splitHead() -> (String, String?) { (first ?? "", count > 1 ? self[1] : nil) }
}
