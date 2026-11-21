import AppKit
import SwiftUI

/// What shows when the notch comes back on (the app opening, or the notch being switched on again): the notch's own strip widens outwards to both sides of the
/// camera, "Welcome back" on its left and the person's first name with a waving hand on its right, then draws back in. It never drops down. The shape itself
/// is drawn by NotchHubView (its size comes from `NotchGeometry.bannerSize`); this is what is written on it.
struct NotchWelcomeStripView: View {
    /// The width of the hardware notch (or the closed notch's stand-in), which the two words leave clear.
    let notchWidth: CGFloat
    /// A still preview draws no animation and shows everything at once.
    var staticLayout = false
    /// The first name written beside the hand (from the Mac's account name); with none, the hand stands alone.
    let name: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    @State private var wave: Double = 0

    private static let font = Font.system(size: 13, weight: .medium)
    /// The room between the words and the strip's outer ends: the same on both sides, so "Welcome back" and the name with its hand sit evenly from the edges.
    private static let edge: CGFloat = 20

    init(notchWidth: CGFloat, staticLayout: Bool = false, name: String? = Self.firstName(from: NSFullUserName())) {
        self.notchWidth = notchWidth
        self.staticLayout = staticLayout
        self.name = name
        self._shown = State(initialValue: staticLayout)
    }

    /// The first word of a full name ("Gaspard Seuge" -> "Gaspard"); nil when there is nothing to show.
    nonisolated static func firstName(from fullName: String) -> String? {
        let word = fullName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        return (word?.isEmpty ?? true) ? nil : word
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("Welcome back")
                .font(Self.font)
                .lineLimit(1)
                .tracking(0.3)
                .padding(.leading, Self.edge)
                .frame(width: NotchGeometry.welcomeWing, alignment: .leading)
                // The words come out of the notch as the strip widens: this one slides left, the other right.
                .offset(x: self.shown ? 0 : 16)
            Spacer(minLength: self.notchWidth)
            HStack(spacing: 5) {
                if let name = self.name {
                    // A long first name is cut with an ellipsis rather than pushed into the notch.
                    Text(name).font(Self.font).tracking(0.3).lineLimit(1).truncationMode(.tail)
                }
                Text("👋")
                    .font(.system(size: 13))
                    .rotationEffect(.degrees(self.wave), anchor: UnitPoint(x: 0.7, y: 0.9))
            }
            .padding(.trailing, Self.edge)
            .frame(width: NotchGeometry.welcomeWing, alignment: .trailing)
            .offset(x: self.shown ? 0 : -16)
        }
        .opacity(self.shown ? 1 : 0)
        .foregroundStyle(.white.opacity(0.92))
        .frame(width: self.notchWidth + NotchGeometry.welcomeWing * 2)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { NotchHubController.shared.dismissBanner() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.name.map { "Welcome back, \($0)" } ?? "Welcome back")
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
