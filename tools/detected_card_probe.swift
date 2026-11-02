// Draws the "meeting detected" card the way the notch lays it out (the same shape, row, padding and countdown line code) with a real app icon,
// at a few moments of the countdown, and measures whether the line starts exactly where the icon's picture does. Nothing of the user's is read.
//
//   swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
//     Sources/Fluid/NotchHub/NotchHubShape.swift Sources/Fluid/NotchHub/Meeting/DetectedCountdown.swift tools/detected_card_probe.swift -o /tmp/detected_card_probe
//   /tmp/detected_card_probe <output folder> [path of an app, default FaceTime]
import AppKit
import SwiftUI

@main
@MainActor
enum DetectedCardProbe {
    static let notchHeight: CGFloat = 38
    static let width: CGFloat = 360

    static func card(icon: NSImage, countdown: DetectedCountdown, inset: CGFloat) -> some View {
        let height = notchHeight + 54
        return ZStack(alignment: .top) {
            Color.gray.opacity(0.35)
            NotchHubShape(topCornerRadius: 10, bottomCornerRadius: 28)
                .fill(Color.black)
                .frame(width: width, height: height)
                .overlay(alignment: .top) {
                    HStack(spacing: 10) {
                        HStack(spacing: 10) {
                            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("FaceTime").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text("Click to record").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer(minLength: 8)
                            ZStack {
                                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5).frame(width: 20, height: 20)
                                Circle().fill(Color(red: 1, green: 0.27, blue: 0.23)).frame(width: 11, height: 11)
                            }
                        }
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.top, 4)
                    .padding(.top, notchHeight + 4)
                    .padding(.horizontal, 26)
                    .frame(width: width, height: height, alignment: .top)
                }
                .overlay(alignment: .bottom) {
                    DetectedCountdownLine(countdown: countdown)
                        .padding(.leading, 26 + inset)
                        .padding(.trailing, 26)
                        .padding(.bottom, 6)
                        .frame(width: width)
                }
        }
        .frame(width: width, height: height)
        .foregroundStyle(.white)
    }

    static func main() {
        guard CommandLine.arguments.count > 1 else { print("usage: detected_card_probe <output folder> [app path]"); exit(2) }
        let out = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let appPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/System/Applications/FaceTime.app"
        let icon = NSWorkspace.shared.icon(forFile: appPath)
        let fraction = AppIconInset.leftFraction(icon)
        let inset = fraction * 26
        print(String(format: "icon of %@: picture starts %.1f%% in = %.2f pt of the 26 pt frame", appPath, fraction * 100, inset))
        for (name, remaining, useInset) in [("full", 5.0, true), ("part", 2.0, true), ("short", 0.6, true), ("part_without_inset", 2.0, false)] {
            let view = card(icon: icon, countdown: DetectedCountdown(total: 5, remaining: remaining, startedAt: nil), inset: useInset ? inset : 0)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let image = renderer.cgImage else { print("no image for \(name)"); continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
            // Measure at 3x: where the icon's picture starts in its middle row, and where the line starts in its row.
            let scale = 3.0, h = Double(image.height)
            func firstLit(row: Int) -> Int? {
                for x in 0..<image.width { if let c = rep.colorAt(x: x, y: row), c.brightnessComponent > 0.45 || c.saturationComponent > 0.25, c.alphaComponent > 0.5 { return x } }
                return nil
            }
            let iconRow = Int((Double(notchHeight + 4 + 4 + 15)) * scale)   // the middle of the 26 pt icon
            let lineRow = Int((Double(notchHeight + 54) - 6 - 1.25) * scale)
            // The card's black body begins at x = 10; ignore the grey backdrop by looking for the first pixel that differs from it inside the body.
            func firstInBody(row: Int, minX: Int) -> Int? {
                for x in minX..<image.width { if let c = rep.colorAt(x: x, y: row), c.alphaComponent > 0.5, c.brightnessComponent > 0.3 || c.saturationComponent > 0.3 { return x } }
                return nil
            }
            let bodyStart = Int(14 * scale)
            let iconX = firstInBody(row: iconRow, minX: bodyStart).map { Double($0) / scale }
            let lineX = firstInBody(row: lineRow, minX: bodyStart).map { Double($0) / scale }
            print(String(format: "%@: icon picture starts at x=%@ pt, line starts at x=%@ pt (height %.0f pt)", name, iconX.map { String(format: "%.2f", $0) } ?? "?", lineX.map { String(format: "%.2f", $0) } ?? "?", h / scale))
        }
        exit(0)
    }
}
