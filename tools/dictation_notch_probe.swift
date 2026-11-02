// Draws the compact dictation notch (the app icon and the waveform beside the notch, the two newest sentences under it) for a few moments of
// speech, using the real RecentSentencesView on the notch's own shape, so it can be looked at without dictating. Nothing of the user's is read.
//
//   swiftc -swift-version 5 -default-isolation MainActor -parse-as-library Sources/Fluid/NotchHub/NotchHubShape.swift \
//     Sources/Fluid/Views/RecentSentences.swift tools/dictation_notch_probe.swift -o /tmp/dictation_notch_probe
//   /tmp/dictation_notch_probe <output folder>
import AppKit
import SwiftUI

@main
@MainActor
enum DictationNotchProbe {
    static let notchWidth: CGFloat = 190
    static let notchHeight: CGFloat = 38

    static func notch(_ text: String) -> some View {
        let bottom = text.isEmpty ? 0 : RecentSentencesView(text: text).intrinsicHeight + 12
        let width = max(notchWidth + 2 * 44, text.isEmpty ? 0 : 300 + 24)
        let height = notchHeight + bottom
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.3, blue: 0.2), Color(red: 0.1, green: 0.15, blue: 0.3)], startPoint: .top, endPoint: .bottom)
            NotchHubShape(topCornerRadius: 6, bottomCornerRadius: 14)
                .fill(Color.black)
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.blue).frame(width: 16, height: 16).frame(width: 34).padding(.leading, 8)
                            Spacer().frame(width: notchWidth)
                            HStack(spacing: 2) { ForEach(0..<8, id: \.self) { i in Capsule().fill(Color.orange).frame(width: 2, height: CGFloat(4 + (i * 5) % 11)) } }.frame(width: 34, height: 16).padding(.trailing, 8)
                        }
                        .frame(height: notchHeight)
                        if !text.isEmpty { RecentSentencesView(text: text).padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 10) }
                    }
                }
        }
        .frame(width: 480, height: 150, alignment: .top)
        .foregroundStyle(.white)
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else { print("usage: dictation_notch_probe <output folder>"); exit(2) }
        let out = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let cases: [(String, String)] = [
            ("silent", ""),
            ("one", "I think we should change right now"),
            ("two", "I think we should change right now when I do my whisper. It uses the icon at the bottom that I can screenshot"),
            ("long", "Also I think we should change right now when I do my whisper it uses the icon at the bottom that I can screenshot right now, and I would love if we could put it into the notch and not expand it too crazy when I'm talking."),
        ]
        for (name, text) in cases {
            let renderer = ImageRenderer(content: notch(text))
            renderer.scale = 2
            guard let image = renderer.cgImage else { print("no image for \(name)"); continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
            let parts = RecentSentences.parts(of: text)
            print("\(name): older=\(parts.older.debugDescription) latest=\(parts.latest.debugDescription)")
        }
        exit(0)
    }
}

private extension View {
    /// The height a view takes at its natural size.
    @MainActor var intrinsicHeight: CGFloat {
        let host = NSHostingView(rootView: self)
        return host.fittingSize.height
    }
}
