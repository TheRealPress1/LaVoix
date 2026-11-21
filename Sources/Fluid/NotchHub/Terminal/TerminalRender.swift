import SwiftUI

// Draws the notch terminal's lines: styled cells to an AttributedString, with links made clickable. Colours are tuned for the notch's black.

struct RenderedLine: Identifiable {
    let id: Int
    let text: AttributedString
}

/// The screen's lines behind a lock, so the shell's reader thread can feed it while the main thread takes snapshots to draw.
nonisolated final class TerminalBuffer: @unchecked Sendable {
    struct Snapshot {
        var lines: [TermLine]
        var inProgress: TermLine?
        var alternateScreen: Bool
        var revision: Int
    }

    private let lock = NSLock()
    private let screen = TerminalScreen()

    func feed(_ data: Data) {
        self.lock.lock()
        self.screen.feed(data)
        self.lock.unlock()
    }

    func reset() {
        self.lock.lock()
        self.screen.reset()
        self.lock.unlock()
    }

    func snapshot() -> Snapshot {
        self.lock.lock()
        defer { self.lock.unlock() }
        return Snapshot(lines: self.screen.lines, inProgress: self.screen.inProgress, alternateScreen: self.screen.usesAlternateScreen, revision: self.screen.revision)
    }
}

enum TerminalRenderer {
    static let fontSize: CGFloat = 12
    static let defaultColor = Color.white.opacity(0.9)

    static func color(_ color: TermColor) -> Color {
        switch color {
        case let .rgb(r, g, b): return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case let .indexed(i): return self.indexed(Int(i))
        }
    }

    private static let base16: [(Double, Double, Double)] = [
        (0.36, 0.36, 0.38), (0.93, 0.36, 0.36), (0.40, 0.85, 0.45), (0.95, 0.80, 0.35),
        (0.45, 0.62, 1.00), (0.85, 0.50, 0.95), (0.40, 0.85, 0.90), (0.85, 0.85, 0.85),
        (0.55, 0.55, 0.58), (1.00, 0.50, 0.50), (0.55, 0.95, 0.60), (1.00, 0.90, 0.50),
        (0.60, 0.75, 1.00), (0.95, 0.65, 1.00), (0.55, 0.95, 1.00), (1.00, 1.00, 1.00),
    ]

    private static func indexed(_ i: Int) -> Color {
        if i < 16 { let c = base16[i]; return Color(red: c.0, green: c.1, blue: c.2) }
        if i < 232 {
            let n = i - 16
            func level(_ v: Int) -> Double { v == 0 ? 0 : (Double(v) * 40 + 55) / 255 }
            return Color(red: level(n / 36), green: level((n / 6) % 6), blue: level(n % 6))
        }
        let g = (Double(i - 232) * 10 + 8) / 255
        return Color(red: g, green: g, blue: g)
    }

    static func attributed(_ cells: [TermCell]) -> AttributedString {
        guard !cells.isEmpty else { return AttributedString(" ") }
        var out = AttributedString()
        var start = 0
        while start < cells.count {
            var end = start
            let style = cells[start].style
            while end < cells.count, cells[end].style == style { end += 1 }
            var run = AttributedString(String(cells[start ..< end].map(\.ch)))
            let foreground = style.fg.map(self.color) ?? self.defaultColor
            let background = style.bg.map(self.color)
            run.foregroundColor = style.inverse ? (background ?? Color.black) : foreground
            if style.inverse { run.backgroundColor = foreground } else if let background { run.backgroundColor = background }
            run.font = .system(size: self.fontSize, weight: style.bold ? .bold : .regular, design: .monospaced)
            if style.dim { run.foregroundColor = (run.foregroundColor ?? self.defaultColor).opacity(0.6) }
            if style.italic { run.font = run.font?.italic() }
            if style.underline { run.underlineStyle = .single }
            out += run
            start = end
        }
        // Addresses in the output (a sign-in page `aws sso login` or `vercel login` prints) open in the browser when clicked.
        let plain = String(cells.map(\.ch))
        for (nsRange, url) in NotchLinkText.links(in: plain) {
            guard let range = Range(nsRange, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower ..< upper].link = url
            out[lower ..< upper].foregroundColor = Color(red: 0.45, green: 0.72, blue: 1.0)
            out[lower ..< upper].underlineStyle = .single
        }
        return out
    }
}
