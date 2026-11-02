// Checks that the engine finds a phrase on the screen where it really is: draws known text at known places in a picture, runs the same
// recognition and locating code the engine uses, and compares each box with where the text was drawn. Nothing of the user's screen is read.
//
//   swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
//     Sources/Fluid/Services/EngineSocket/EngineLook.swift Sources/Fluid/Services/Look/LookBuddy.swift tools/look_locate_probe.swift -o /tmp/look_locate_probe
//   /tmp/look_locate_probe
import AppKit
import Vision

nonisolated final class DebugLogger {
    nonisolated(unsafe) static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
}

@main
enum LookLocateProbe {
    static func main() {
        let size = CGSize(width: 1200, height: 800)
        let frame = CGRect(x: 100, y: 200, width: size.width, height: size.height)
        let font = NSFont.systemFont(ofSize: 30, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // Each line: text, where it starts (top-left origin, points), and the stretch to find inside it.
        let lines: [(String, CGPoint, String)] = [
            ("Contact: Anthony Ha, weekend editor", CGPoint(x: 60, y: 90), "Anthony Ha"),
            ("Email: anthony.ha@techcrunch.com", CGPoint(x: 60, y: 260), "anthony.ha@techcrunch.com"),
            ("Follow us on social media today", CGPoint(x: 600, y: 640), "social media"),
        ]
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { print("no context"); exit(1) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for (text, origin, _) in lines {
            // The context is bottom-left origin: the text's baseline box starts at height - y - line height.
            let lineHeight = ("X" as NSString).size(withAttributes: attributes).height
            (text as NSString).draw(at: CGPoint(x: origin.x, y: size.height - origin.y - lineHeight), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { print("no image"); exit(1) }

        let started = Date()
        let phrases = lines.map(\.2) + ["not on the page", "ANTHONY   HA"]
        let result = EngineLookText.readLocating(image, find: phrases, in: frame)
        print(String(format: "read in %.2f s, %d characters", Date().timeIntervalSince(started), result.text.count))
        var failures = 0
        for (index, (text, origin, wanted)) in lines.enumerated() {
            let lineHeight = ("X" as NSString).size(withAttributes: attributes).height
            let prefix = String(text[..<text.range(of: wanted)!.lowerBound])
            let x = origin.x + (prefix as NSString).size(withAttributes: attributes).width
            let width = (wanted as NSString).size(withAttributes: attributes).width
            // Where it was drawn, in global points (the frame's origin added).
            let expected = CGRect(x: frame.minX + x, y: frame.minY + origin.y, width: width, height: lineHeight)
            guard let found = result.found[index] else { print("FAIL \(wanted): not found"); failures += 1; continue }
            let dx = abs(found.rect.midX - expected.midX), dy = abs(found.rect.midY - expected.midY)
            let ratio = found.rect.width / expected.width
            let ok = dx < 14 && dy < 14 && ratio > 0.8 && ratio < 1.25
            if !ok { failures += 1 }
            print(String(format: "%@ %@: found x=%.0f y=%.0f w=%.0f h=%.0f, drawn x=%.0f y=%.0f w=%.0f h=%.0f (centre off by %.1f, %.1f; width ratio %.2f)", ok ? "OK  " : "FAIL", wanted, found.rect.minX, found.rect.minY, found.rect.width, found.rect.height, expected.minX, expected.minY, expected.width, expected.height, dx, dy, ratio))
        }
        let missing = result.found[3]
        print(missing == nil ? "OK   a phrase that is not on the page is not found" : "FAIL a missing phrase was found")
        if missing != nil { failures += 1 }
        if let spaced = result.found[4] {
            print(String(format: "OK   extra spaces and other case still find the name: %@ (line \"%@\")", spaced.rect.debugDescription, spaced.line))
        } else {
            print("FAIL the name with extra spaces and other case was not found")
            failures += 1
        }
        print(failures == 0 ? "LOCATE PROBE PASSED" : "LOCATE PROBE FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
