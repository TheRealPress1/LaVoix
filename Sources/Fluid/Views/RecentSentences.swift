import Foundation
import NaturalLanguage
import SwiftUI

/// The newest sentences of a transcript that is still being spoken, for the line of text under the notch while you dictate: the two most recent
/// sentences, the older one quieter than the one being said now, never more than will fit in about three lines.
nonisolated enum RecentSentences {
    struct Parts: Equatable {
        /// The sentence before the newest, possibly cut at its start; "" when there is none or no room for it.
        var older: String
        /// The newest sentence, the one being said now, cut at its start with an ellipsis when it alone is longer than the room.
        var latest: String
    }

    /// About three lines of the notch's text at its width (a little under, so the newest words are never the ones cut off).
    static let defaultMaxCharacters = 112

    static func parts(of text: String, maxCharacters: Int = defaultMaxCharacters) -> Parts {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return Parts(older: "", latest: "") }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = flat
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: flat.startIndex..<flat.endIndex) { range, _ in
            let sentence = String(flat[range]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }
        guard let newest = sentences.last else { return Parts(older: "", latest: self.tail(flat, maxCharacters)) }
        let latest = self.tail(newest, maxCharacters)
        var older = sentences.count >= 2 ? sentences[sentences.count - 2] : ""
        // The newest gets its room first; the sentence before it gets what is left (a sliver of one is not worth showing).
        let room = maxCharacters - latest.count - 1
        if room < 14 || latest.hasPrefix("…") {
            older = ""
        } else if older.count > room {
            older = self.tail(older, room)
        }
        return Parts(older: older, latest: latest)
    }

    /// The end of `text`, `maxCharacters` at most, starting at a word and marked with an ellipsis when the start was left out.
    static func tail(_ text: String, _ maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 1 else { return text }
        let cut = String(text.suffix(maxCharacters - 1))
        if let space = cut.firstIndex(of: " ") { return "…" + String(cut[cut.index(after: space)...]) }
        return "…" + cut
    }
}

/// The two newest sentences as the notch shows them: 11.5 point text across a fixed 300 points, the older sentence at half brightness.
struct RecentSentencesView: View {
    let text: String
    var width: CGFloat = 300

    private var attributed: AttributedString {
        let parts = RecentSentences.parts(of: self.text)
        var older = AttributedString(parts.older.isEmpty ? "" : parts.older + " ")
        older.foregroundColor = Color.white.opacity(0.5)
        var latest = AttributedString(parts.latest)
        latest.foregroundColor = Color.white.opacity(0.95)
        return older + latest
    }

    var body: some View {
        Text(self.attributed)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(width: self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
