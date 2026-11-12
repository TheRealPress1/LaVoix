import AppKit
import SwiftUI

/// What shows when the notch comes back on (the app opening, or the notch being switched on again): the notch's own strip widens outwards to both sides of the
/// camera, "Welcome" on its left and "Back" with a waving hand on its right, then draws back in. It never drops down. The shape itself is drawn by NotchHubView
/// (its size comes from `NotchGeometry.bannerSize`); this is what is written on it.
struct NotchWelcomeStripView: View {
    /// The width of the hardware notch (or the closed notch's stand-in), which the two words leave clear.
    let notchWidth: CGFloat
    /// A still preview draws no animation and shows everything at once.
    var staticLayout = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    @State private var wave: Double = 0

    private static let font = Font.system(size: 13, weight: .medium)
    /// The room between a word and the notch's edge.
    private static let gap: CGFloat = 14

    init(notchWidth: CGFloat, staticLayout: Bool = false) {
        self.notchWidth = notchWidth
        self.staticLayout = staticLayout
        self._shown = State(initialValue: staticLayout)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("Welcome")
                .font(Self.font)
                .tracking(0.3)
                .padding(.trailing, Self.gap)
                .frame(width: NotchGeometry.welcomeWing, alignment: .trailing)
                // The words come out of the notch as the strip widens: this one slides left, the other right.
                .offset(x: self.shown ? 0 : 16)
            Spacer(minLength: self.notchWidth)
            HStack(spacing: 5) {
                Text("Back").font(Self.font).tracking(0.3)
                Text("👋")
                    .font(.system(size: 13))
                    .rotationEffect(.degrees(self.wave), anchor: UnitPoint(x: 0.7, y: 0.9))
            }
            .padding(.leading, Self.gap)
            .frame(width: NotchGeometry.welcomeWing, alignment: .leading)
            .offset(x: self.shown ? 0 : -16)
        }
        .opacity(self.shown ? 1 : 0)
        .foregroundStyle(.white.opacity(0.92))
        .frame(width: self.notchWidth + NotchGeometry.welcomeWing * 2)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { NotchHubController.shared.dismissBanner() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Welcome back")
        .task {
            guard !self.staticLayout else { return }
            // The strip is already widening: the words follow it.
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5).delay(0.16)) { self.shown = true }
            guard !self.reduceMotion else { return }
            try? await Task.sleep(nanoseconds: 650_000_000)
            for angle in [20.0, -6.0, 14.0, -4.0, 0.0] {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.17)) { self.wave = angle }
                try? await Task.sleep(nanoseconds: 170_000_000)
            }
        }
    }
}
