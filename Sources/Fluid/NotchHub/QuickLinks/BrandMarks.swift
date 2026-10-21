import SwiftUI

/// Vector marks for brands whose logo is more than a few shapes, drawn from their published outlines (24 x 24 units) so they stay sharp at
/// any size and nothing is downloaded to find them.
enum BrandMarks {
    /// GitHub's mark: the circle with the cat cut out of it.
    static let github = "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12"
    /// Cal.com's wordmark, which fills the width of its 24 x 24 box and about a quarter of its height.
    static let calcom = "M2.408 14.488C1.035 14.488 0 13.4 0 12.058c0-1.346.982-2.443 2.408-2.443.758 0 1.282.233 1.691.765l-.66.55a1.343 1.343 0 0 0-1.03-.442c-.93 0-1.44.711-1.44 1.57 0 .86.559 1.557 1.44 1.557.413 0 .765-.147 1.043-.443l.651.573c-.391.51-.929.743-1.695.743zM6.948 10.913h.89v3.49h-.89v-.51c-.185.362-.493.604-1.083.604-.943 0-1.695-.82-1.695-1.826 0-1.007.752-1.825 1.695-1.825.585 0 .898.241 1.083.604zm.026 1.758c0-.546-.374-.998-.964-.998-.568 0-.938.457-.938.998 0 .528.37.998.938.998.586 0 .964-.456.964-.998zM8.467 9.503h.89v4.895h-.89zM9.752 13.937a.53.53 0 0 1 .542-.528c.313 0 .533.242.533.528a.527.527 0 0 1-.533.537.534.534 0 0 1-.542-.537zM14.23 13.839c-.33.403-.832.658-1.426.658a1.806 1.806 0 0 1-1.84-1.826c0-1.007.778-1.825 1.84-1.825.572 0 1.07.241 1.4.622l-.687.577c-.172-.215-.396-.376-.713-.376-.568 0-.938.456-.938.998 0 .541.37.997.938.997.343 0 .58-.179.757-.42zM14.305 12.671c0-1.007.78-1.825 1.84-1.825 1.061 0 1.84.818 1.84 1.825 0 1.007-.779 1.826-1.84 1.826-1.06-.005-1.84-.82-1.84-1.826zm2.778 0c0-.546-.37-.998-.938-.998-.568-.004-.937.452-.937.998 0 .542.37.998.937.998.568 0 .938-.456.938-.998zM24 12.269v2.13h-.89v-1.911c0-.604-.281-.864-.704-.864-.396 0-.678.197-.678.864v1.91h-.89v-1.91c0-.604-.285-.864-.704-.864-.396 0-.744.197-.744.864v1.91h-.89v-3.49h.89v.484c.185-.376.52-.564 1.035-.564.489 0 .898.241 1.123.649.224-.417.554-.65 1.153-.65.731.005 1.299.56 1.299 1.442z"
    /// The box the Cal.com wordmark sits in: its outline's top and height within the 24 x 24 units.
    static let calcomBox = CGRect(x: 0, y: 9.5, width: 24, height: 5)

    /// The rectangle an outline covers, in its own units.
    nonisolated static func bounds(of d: String) -> CGRect { SVGPathParser.parse(d).boundingRect }
}

/// An SVG path (the `d` text: M L H V C S A Z, upper or lower case) scaled to fill the rectangle it is given, from `box` in the path's own units.
struct SVGPathShape: Shape {
    let d: String
    var box = CGRect(x: 0, y: 0, width: 24, height: 24)

    func path(in rect: CGRect) -> Path {
        let raw = SVGPathParser.parse(self.d)
        let sx = rect.width / self.box.width, sy = rect.height / self.box.height
        return raw.applying(CGAffineTransform(translationX: -self.box.minX, y: -self.box.minY).concatenating(CGAffineTransform(scaleX: sx, y: sy)).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

nonisolated enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        var path = Path()
        var tokens = Tokens(Array(d.unicodeScalars))
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?
        var command: Character = "M"
        while let next = tokens.peekCommand() ?? (tokens.hasNumber ? command : nil) {
            if tokens.peekCommand() != nil { tokens.skipCommand() }
            command = next
            let rel = command.isLowercase
            func pt(_ x: Double, _ y: Double) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
            var cubicEnd: CGPoint?
            switch command.uppercased() {
            case "M":
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                cur = pt(x, y); start = cur; path.move(to: cur)
                command = rel ? "l" : "L"
            case "L":
                guard let x = tokens.number(), let y = tokens.number() else { return path }
                cur = pt(x, y); path.addLine(to: cur)
            case "H":
                guard let x = tokens.number() else { return path }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
            case "V":
                guard let y = tokens.number() else { return path }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
            case "C":
                guard let a = tokens.number(), let b = tokens.number(), let c = tokens.number(), let e = tokens.number(), let f = tokens.number(), let g = tokens.number() else { return path }
                let c1 = pt(a, b), c2 = pt(c, e), end = pt(f, g)
                path.addCurve(to: end, control1: c1, control2: c2)
                cubicEnd = c2; cur = end
            case "S":
                guard let c = tokens.number(), let e = tokens.number(), let f = tokens.number(), let g = tokens.number() else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(c, e), end = pt(f, g)
                path.addCurve(to: end, control1: c1, control2: c2)
                cubicEnd = c2; cur = end
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rot = tokens.number(), let large = tokens.flag(), let sweep = tokens.flag(), let x = tokens.number(), let y = tokens.number() else { return path }
                let end = pt(x, y)
                addArc(&path, from: cur, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = end
            case "Z":
                path.closeSubpath(); cur = start
            default:
                return path
            }
            lastCubic = cubicEnd
        }
        return path
    }

    /// An SVG elliptical arc as cubic curves (the endpoint-to-centre conversion from the SVG specification, appendix F.6).
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx0), ry = abs(ry0)
        guard p0 != p1 else { return }
        guard rx > 0, ry > 0 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let sign: Double = large == sweep ? -1 : 1
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coef = sign * max(0, num / den).squareRoot()
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2, cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        var t = theta1
        for _ in 0..<segments {
            let c1 = cos(t), s1 = sin(t), c2 = cos(t + step), s2 = sin(t + step)
            func map(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: cosP * rx * x - sinP * ry * y + cx, y: sinP * rx * x + cosP * ry * y + cy) }
            path.addCurve(to: map(c2, s2), control1: map(c1 - k * s1, s1 + k * c1), control2: map(c2 + k * s2, s2 - k * c2))
            t += step
        }
    }

    private struct Tokens {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        private mutating func skipSeparators() { while i < s.count, s[i] == " " || s[i] == "," || s[i] == "\n" || s[i] == "\t" { i += 1 } }
        func isCommand(_ c: Unicode.Scalar) -> Bool { "MmLlHhVvCcSsAaZz".unicodeScalars.contains(c) }
        mutating func peekCommand() -> Character? { skipSeparators(); return i < s.count && isCommand(s[i]) ? Character(s[i]) : nil }
        mutating func skipCommand() { i += 1 }
        var hasNumber: Bool { var j = i; while j < s.count, s[j] == " " || s[j] == "," { j += 1 }; return j < s.count && !isCommand(s[j]) }
        /// A flag in an arc is a single 0 or 1 that may sit right against the next number.
        mutating func flag() -> Bool? { skipSeparators(); guard i < s.count, s[i] == "0" || s[i] == "1" else { return nil }; defer { i += 1 }; return s[i] == "1" }
        mutating func number() -> Double? {
            skipSeparators()
            let begin = i
            if i < s.count, s[i] == "-" || s[i] == "+" { i += 1 }
            var seenDot = false
            while i < s.count {
                let c = s[i]
                if c == "." { if seenDot { break }; seenDot = true; i += 1 } else if c.properties.numericType != nil, c.value < 128 { i += 1 } else { break }
            }
            guard i > begin else { return nil }
            return Double(String(String.UnicodeScalarView(s[begin..<i])))
        }
    }
}
