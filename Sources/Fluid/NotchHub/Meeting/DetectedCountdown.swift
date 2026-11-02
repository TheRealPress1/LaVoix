import AppKit
import SwiftUI

/// How long the "meeting detected" prompt stays up before it goes away by itself (hovering it holds it).
nonisolated enum MeetingPromptTiming {
    static let showSeconds: TimeInterval = 5
}

/// The time left on the "meeting detected" prompt, drawn as a line that shrinks from the right to the left. `remaining` seconds were left when it
/// last started or resumed running (`startedAt`); `startedAt` is nil while it is held, and then `remaining` is what is left.
nonisolated struct DetectedCountdown: Equatable {
    var total: TimeInterval
    var remaining: TimeInterval
    var startedAt: Date?

    /// How much of the line is left at `now`: 1 when the prompt has just appeared, 0 when it is gone.
    func fraction(at now: Date) -> Double {
        let elapsed = self.startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return min(1, max(0, (self.remaining - elapsed) / max(self.total, 0.001)))
    }
}

/// A thin line, full width when the prompt appears and gone when it goes, its right end running to the left.
struct DetectedCountdownLine: View {
    let countdown: DetectedCountdown

    var body: some View {
        // Redrawn every frame while it runs; drawn once while it is held.
        TimelineView(.animation(paused: self.countdown.startedAt == nil)) { context in
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: proxy.size.width * self.countdown.fraction(at: context.date), height: 2.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 2.5)
        }
        .accessibilityHidden(true)
    }
}

/// Where an app's icon really starts inside its frame: app icons are drawn with a transparent margin, so the left edge of the picture is a few
/// points in from the left edge of the frame it is shown in.
nonisolated enum AppIconInset {
    /// How far in from the left the picture starts, as a fraction of the icon's width (0 when it fills the frame or cannot be measured).
    static func leftFraction(_ image: NSImage) -> CGFloat {
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        for x in 0..<side {
            for y in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.25 {
                return CGFloat(x) / CGFloat(side)
            }
        }
        return 0
    }
}
