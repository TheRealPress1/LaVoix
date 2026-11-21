import Foundation

// The notch terminal's output model: what a shell prints, as lines of styled cells. It understands what a command runner needs (colours and bold, a carriage
// return that overwrites the line so progress bars work, erase-line, a few cursor moves along the line, clear-screen) and drops everything else. A program that
// takes over the whole screen (vim, htop) is only noticed, not drawn. Pure: no UI, no process, so it can be tested on its own.
// See docs/21-notch-terminal.md in the myos repo.

nonisolated enum TermColor: Equatable {
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

nonisolated struct TermStyle: Equatable {
    var fg: TermColor?
    var bg: TermColor?
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
}

nonisolated struct TermCell: Equatable {
    var ch: Character
    var style: TermStyle
}

nonisolated struct TermLine: Identifiable {
    let id: Int
    var cells: [TermCell]
    var plain: String { String(self.cells.map(\.ch)) }
}

nonisolated final class TerminalScreen {
    /// Only this many finished lines are kept, so a command that never stops (`vercel logs -f`) cannot grow memory without limit.
    static let maxLines = 2000

    private(set) var lines: [TermLine] = []
    /// True while a full-screen program (vim, htop) has the screen. Output is swallowed until it gives the screen back.
    private(set) var usesAlternateScreen = false
    /// Counts every change, so a caller can tell whether anything new needs drawing.
    private(set) var revision = 0

    private var current: [TermCell] = []
    private var col = 0
    private var style = TermStyle()
    private var nextID = 1
    private var pending: [UInt8] = []
    private var state = ParseState.ground
    private var params: [UInt8] = []
    private var osc: [UInt8] = []

    private enum ParseState { case ground, escape, charset, csi, osc, oscEscape, string, stringEscape }

    /// The line still being written (no newline yet), as a line with the id -1.
    var inProgress: TermLine? { self.current.isEmpty ? nil : TermLine(id: -1, cells: self.current) }

    func reset() {
        self.lines.removeAll()
        self.current.removeAll()
        self.col = 0
        self.style = TermStyle()
        self.pending.removeAll()
        self.state = .ground
        self.usesAlternateScreen = false
        self.revision += 1
    }

    /// Takes what the shell printed, in any chunking (a multi-byte character or an escape sequence may be split between two calls).
    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        var bytes = self.pending + [UInt8](data)
        self.pending.removeAll()
        // Keep an unfinished multi-byte character for the next chunk.
        var cut = bytes.count
        var back = 0
        while back < min(3, bytes.count) {
            let b = bytes[bytes.count - 1 - back]
            if b & 0xC0 == 0x80 { back += 1; continue }              // a continuation byte: look further back for its lead
            let needed = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if needed > back + 1 { cut = bytes.count - 1 - back }
            break
        }
        if cut < bytes.count { self.pending = Array(bytes[cut...]); bytes.removeSubrange(cut...) }
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars { self.process(scalar) }
        self.revision += 1
    }

    // MARK: - parsing

    private func process(_ s: Unicode.Scalar) {
        let v = s.value
        switch self.state {
        case .ground:
            switch v {
            case 0x1B: self.state = .escape
            case 0x0A: self.newline()
            case 0x0D: self.col = 0
            case 0x08: self.col = max(0, self.col - 1)
            case 0x09: self.put(" ", times: 8 - (self.col % 8))
            case 0x00 ... 0x1F, 0x7F: break
            default: self.put(Character(s), times: 1)
            }
        case .escape:
            switch s {
            case "[": self.params.removeAll(); self.state = .csi
            case "]": self.osc.removeAll(); self.state = .osc
            case "P", "X", "^", "_": self.state = .string
            case "(", ")", "*", "+", "#": self.state = .charset
            default: self.state = .ground
            }
        case .charset:
            self.state = .ground
        case .csi:
            if v >= 0x40 && v <= 0x7E {
                self.csi(final: Character(s))
                self.state = .ground
            } else if v == 0x1B {
                self.state = .escape
            } else if self.params.count < 64 {
                self.params.append(UInt8(truncatingIfNeeded: v))
            }
        case .osc:
            if v == 0x07 { self.state = .ground } else if v == 0x1B { self.state = .oscEscape } else if self.osc.count < 4096 { self.osc.append(UInt8(truncatingIfNeeded: v)) }
        case .oscEscape:
            self.state = s == "\\" ? .ground : .osc
        case .string:
            if v == 0x1B { self.state = .stringEscape } else if v == 0x07 { self.state = .ground }
        case .stringEscape:
            self.state = s == "\\" ? .ground : .string
        }
    }

    private func put(_ ch: Character, times: Int) {
        guard !self.usesAlternateScreen else { return }
        for _ in 0 ..< max(0, times) {
            let cell = TermCell(ch: ch, style: self.style)
            if self.col < self.current.count {
                self.current[self.col] = cell
            } else {
                while self.current.count < self.col { self.current.append(TermCell(ch: " ", style: TermStyle())) }
                self.current.append(cell)
            }
            self.col += 1
            if self.current.count > 4000 { self.newline() }     // a line this long is a flood: wrap it
        }
    }

    private func newline() {
        guard !self.usesAlternateScreen else { return }
        self.lines.append(TermLine(id: self.nextID, cells: self.current))
        self.nextID += 1
        self.current.removeAll(keepingCapacity: true)
        self.col = 0
        if self.lines.count > Self.maxLines + 200 { self.lines.removeFirst(self.lines.count - Self.maxLines) }
    }

    private func numbers() -> [Int?] {
        let text = String(decoding: self.params.filter { $0 != UInt8(ascii: "?") && $0 != UInt8(ascii: ">") && $0 != UInt8(ascii: "!") }, as: UTF8.self)
        return text.split(separator: ";", omittingEmptySubsequences: false).map { Int($0.split(separator: ":").first ?? "") }
    }

    private func csi(final: Character) {
        let isPrivate = self.params.first == UInt8(ascii: "?")
        let n = self.numbers()
        let first = n.first.flatMap { $0 }
        switch final {
        case "m": self.sgr(n)
        case "K":
            switch first ?? 0 {
            case 0: if self.col < self.current.count { self.current.removeSubrange(self.col...) }
            case 1: for i in 0 ..< min(self.col + 1, self.current.count) { self.current[i] = TermCell(ch: " ", style: TermStyle()) }
            default: self.current.removeAll()
            }
        case "J":
            if first == 2 || first == 3 {
                self.lines.removeAll()
                self.current.removeAll()
                self.col = 0
            }
        case "C": self.col += max(1, first ?? 1)
        case "D": self.col = max(0, self.col - max(1, first ?? 1))
        case "G": self.col = max(0, (first ?? 1) - 1)
        case "H", "f": self.col = max(0, ((n.count > 1 ? n[1] : nil) ?? 1) - 1)
        case "P": if self.col < self.current.count { self.current.removeSubrange(self.col ..< min(self.current.count, self.col + max(1, first ?? 1))) }
        case "X":
            for i in self.col ..< min(self.current.count, self.col + max(1, first ?? 1)) { self.current[i] = TermCell(ch: " ", style: TermStyle()) }
        case "h", "l":
            if isPrivate, let mode = first, mode == 1049 || mode == 47 || mode == 1047 { self.usesAlternateScreen = final == "h" }
        default: break
        }
    }

    private func sgr(_ n: [Int?]) {
        var list = n.map { $0 ?? 0 }
        if list.isEmpty { list = [0] }
        var i = 0
        while i < list.count {
            let code = list[i]
            switch code {
            case 0: self.style = TermStyle()
            case 1: self.style.bold = true
            case 2: self.style.dim = true
            case 3: self.style.italic = true
            case 4: self.style.underline = true
            case 7: self.style.inverse = true
            case 22: self.style.bold = false; self.style.dim = false
            case 23: self.style.italic = false
            case 24: self.style.underline = false
            case 27: self.style.inverse = false
            case 30 ... 37: self.style.fg = .indexed(UInt8(code - 30))
            case 90 ... 97: self.style.fg = .indexed(UInt8(code - 90 + 8))
            case 39: self.style.fg = nil
            case 40 ... 47: self.style.bg = .indexed(UInt8(code - 40))
            case 100 ... 107: self.style.bg = .indexed(UInt8(code - 100 + 8))
            case 49: self.style.bg = nil
            case 38, 48:
                var color: TermColor?
                if i + 2 < list.count, list[i + 1] == 5 { color = .indexed(UInt8(clamping: list[i + 2])); i += 2 }
                else if i + 4 < list.count, list[i + 1] == 2 { color = .rgb(UInt8(clamping: list[i + 2]), UInt8(clamping: list[i + 3]), UInt8(clamping: list[i + 4])); i += 4 }
                if let color { if code == 38 { self.style.fg = color } else { self.style.bg = color } }
            default: break
            }
            i += 1
        }
    }
}
