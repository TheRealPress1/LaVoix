import AppKit
import SwiftUI

/// Message text with its web addresses turned into links, so a tap opens them in the browser.
enum NotchLinkText {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// The links found in `text`, in order (bare domains like `example.com/x` get an https scheme).
    static func links(in text: String) -> [(range: NSRange, url: URL)] {
        let range = NSRange(text.startIndex..., in: text)
        return (detector?.matches(in: text, options: [], range: range) ?? []).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (match.range, url)
        }
    }

    static func attributed(_ text: String, linkColor: Color = Color(red: 0.45, green: 0.72, blue: 1.0)) -> AttributedString {
        var result = AttributedString(text)
        for (nsRange, url) in self.links(in: text) {
            guard let stringRange = Range(nsRange, in: text),
                  let lower = AttributedString.Index(stringRange.lowerBound, within: result),
                  let upper = AttributedString.Index(stringRange.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].foregroundColor = linkColor
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }

    /// Opens a tapped link in the default browser.
    static let openAction = OpenURLAction { url in
        NSWorkspace.shared.open(url)
        return .handled
    }
}
