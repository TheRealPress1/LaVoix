// Draws Look's notch cards (the real NotchLookCardView on the notch's own shape) for a few typical texts and writes pictures, so the design can be
// looked at without Look being used. Nothing of the user's is read.
//
//   swiftc -swift-version 5 -default-isolation MainActor -parse-as-library Sources/Fluid/NotchHub/NotchHubShape.swift \
//     Sources/Fluid/NotchHub/Messages/NotchLinkText.swift Sources/Fluid/NotchHub/Messages/NotchLookCard.swift tools/look_card_probe.swift -o /tmp/look_card_probe
//   /tmp/look_card_probe <output folder>
import AppKit
import SwiftUI

@main
@MainActor
enum LookCardProbe {
    static let width: CGFloat = 400
    static let notchHeight: CGFloat = 38

    static func card(title: String, text: String, symbol: String, primary: String?, secondary: String?) -> some View {
        let height = notchHeight + NotchLookCardView.contentHeight(text: text, hasButtons: primary != nil, cardWidth: width)
        return ZStack(alignment: .top) {
            Color(red: 0.16, green: 0.12, blue: 0.1)
            NotchHubShape(topCornerRadius: 10, bottomCornerRadius: 30)
                .fill(Color.black)
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    NotchLookCardView(title: title, text: text, symbol: symbol, width: width, primaryLabel: primary, secondaryLabel: secondary)
                        .padding(.top, notchHeight)
                }
        }
        .frame(width: width + 40, height: height + 30, alignment: .top)
        .foregroundStyle(.white)
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else { print("usage: look_card_probe <output folder>"); exit(2) }
        let out = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let cases: [(String, String, String, String, String?, String?)] = [
            ("answer", "Look", "You're looking at the Convex homepage (convex.dev). It describes Convex as a reactive backend platform with database, functions, workflows, sync, search, and file storage, all in TypeScript. There's a button to start a new project.", "sparkles", "Keep as note", nil),
            ("consent", "Ask Claude about this?", "Look can send what you said and the text of the window in Dia to Claude, through your login. Email addresses and long numbers stay on this Mac.", "sparkles", "Always for Dia", "Allow once"),
            ("person", "Add Anthony Ha?", "Anthony Ha is a weekend editor at TechCrunch. His address is anthony.ha@techcrunch.com.", "person.crop.circle.badge.plus", "Add to Outreach", nil),
            ("looking", "Looking…", "Reading what you pointed at", "eye", nil, nil),
            ("kept", "Kept in your notes", "Convex homepage", "checkmark.circle.fill", nil, nil),
            ("error", "Look couldn't ask Claude", "Claude Code isn't signed in. Open Claude Code and sign in.", "exclamationmark.triangle.fill", nil, nil),
        ]
        for (name, title, text, symbol, primary, secondary) in cases {
            let renderer = ImageRenderer(content: card(title: title, text: text, symbol: symbol, primary: primary, secondary: secondary))
            renderer.scale = 2
            guard let image = renderer.cgImage else { print("no image for \(name)"); continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
            print("wrote \(name) (\(NotchLookCardView.lines(of: text, cardWidth: width)) lines of text)")
        }
        exit(0)
    }
}
