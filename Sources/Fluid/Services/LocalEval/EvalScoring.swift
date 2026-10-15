import Foundation

struct EvalScore {
    var pass: Bool
    /// 0...1, partial credit (recall/precision style) for reading trends; `pass` is the strict verdict.
    var value: Double
    var note: String
}

enum EvalScoring {
    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func score(_ c: EvalCase, answer: EvalAnswer) -> EvalScore {
        switch (c.expected, answer) {
        case let (.mentions(want), .mentions(got)):
            let w = Set(want), g = Set(got)
            if w == g { return EvalScore(pass: true, value: 1, note: "") }
            let hit = Double(w.intersection(g).count)
            let p = g.isEmpty ? 0 : hit / Double(g.count)
            let r = w.isEmpty ? 0 : hit / Double(w.count)
            let f1 = (p + r) == 0 ? 0 : 2 * p * r / (p + r)
            return EvalScore(pass: false, value: f1, note: "want \(want.sorted()) got \(got.sorted())")

        case let (.facts(want), .facts(got)):
            var matched = 0
            for w in want where got.contains(where: { $0.kind == w.kind && norm($0.value).contains(norm(w.value)) }) { matched += 1 }
            let wrong = got.filter { g in !want.contains(where: { $0.kind == g.kind && norm(g.value).contains(norm($0.value)) }) }
            let recall = want.isEmpty ? 1.0 : Double(matched) / Double(want.count)
            let precision = got.isEmpty ? 1.0 : Double(got.count - wrong.count) / Double(got.count)
            let pass = matched == want.count && wrong.isEmpty
            let value = want.isEmpty && got.isEmpty ? 1 : (recall + precision) / 2
            return EvalScore(pass: pass, value: pass ? 1 : value, note: pass ? "" : "missing \(want.count - matched), wrong \(wrong.map { "\($0.kind)=\($0.value)" })")

        case let (.commitments(want), .commitments(got)):
            var matched = 0
            var used = Set<Int>()
            for w in want {
                if let i = got.indices.first(where: { !used.contains($0) && got[$0].owner == w.owner && got[$0].due == w.due && keywordMatch(got[$0].what, w.what) }) {
                    used.insert(i); matched += 1
                }
            }
            let extra = got.count - used.count
            let pass = matched == want.count && extra == 0
            let recall = want.isEmpty ? 1.0 : Double(matched) / Double(want.count)
            let precision = got.isEmpty ? 1.0 : Double(used.count) / Double(got.count)
            let value = (recall + precision) / 2
            return EvalScore(pass: pass, value: pass ? 1 : value, note: pass ? "" : "matched \(matched)/\(want.count), extra \(extra); got \(got.map { "\($0.owner):\($0.due ?? "nil")" })")

        case let (.qa(_, wantAnswerable), .qa(answer, gotAnswerable)):
            if !wantAnswerable {
                let ok = !gotAnswerable
                return EvalScore(pass: ok, value: ok ? 1 : 0, note: ok ? "" : "invented an answer: \(answer.prefix(60))")
            }
            guard gotAnswerable else { return EvalScore(pass: false, value: 0, note: "said unanswerable") }
            let missing = c.requiredWords.filter { !norm(answer).contains(norm($0)) }
            return EvalScore(pass: missing.isEmpty, value: missing.isEmpty ? 1 : 0, note: missing.isEmpty ? "" : "missing \(missing) in: \(answer.prefix(80))")

        default:
            return EvalScore(pass: false, value: 0, note: "answer shape does not match task")
        }
    }

    private static func keywordMatch(_ got: String, _ want: String) -> Bool {
        let g = norm(got)
        return norm(want).split(separator: " ").contains { w in g.contains(w) }
    }
}
