import AppKit
import SwiftUI

/// The small card that drops out of the notch when it comes back on (the app opening, or the notch being switched on again): a hand that waves once,
/// "Welcome back" in a serif italic, and the greeting for the time of day under it. It says the notch is running and then goes by itself.
struct NotchWelcomeCardView: View {
    /// "Good morning, Gaspard": see `greeting`.
    let greeting: String
    /// A still preview draws no animation and shows everything at once.
    var staticLayout = false

    /// Under the notch band: the row (40), a little air above it and more below, where the card's corners curve in.
    static let contentHeight: CGFloat = 8 + 40 + 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    @State private var wave: Double = 0

    init(greeting: String, staticLayout: Bool = false) {
        self.greeting = greeting
        self.staticLayout = staticLayout
        self._shown = State(initialValue: staticLayout)
    }

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().fill(LinearGradient(
                    colors: [Color(red: 1.0, green: 0.84, blue: 0.50).opacity(0.46), Color(red: 1.0, green: 0.58, blue: 0.48).opacity(0.22)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                // The hand turns about its wrist, which is low and to the right of the picture's middle.
                Text("👋")
                    .font(.system(size: 21))
                    .rotationEffect(.degrees(self.wave), anchor: UnitPoint(x: 0.72, y: 0.85))
            }
            .frame(width: 40, height: 40)
            .scaleEffect(self.shown ? 1 : 0.55)
            .opacity(self.shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                Text("Welcome back")
                    .font(.system(size: 19, weight: .semibold, design: .serif).italic())
                    .tracking(0.2)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(self.greeting)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .tracking(0.3)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .opacity(self.shown ? 1 : 0)
            .offset(y: self.shown ? 0 : 5)
            .animation(.easeOut(duration: 0.5).delay(0.12), value: self.shown)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { NotchHubController.shared.dismissBanner() }
        .task {
            guard !self.staticLayout else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.68)) { self.shown = true }
            guard !self.reduceMotion else { return }
            // Waits for the card to finish dropping, then waves: out, back, out, back, and settles.
            try? await Task.sleep(nanoseconds: 450_000_000)
            for angle in [22.0, -8.0, 18.0, -6.0, 10.0, 0.0] {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.19)) { self.wave = angle }
                try? await Task.sleep(nanoseconds: 190_000_000)
            }
        }
    }

    // MARK: - The words

    /// "Good morning" until noon, "Good afternoon" until six, "Good evening" after that, and a plain "Hello" in the small hours; with the first name when there is one.
    static func greeting(name: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: now)
        let hello = hour < 5 ? "Hello" : (hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening"))
        guard let name, !name.isEmpty else { return hello }
        return "\(hello), \(name)"
    }

    /// The first word of the Mac account's full name ("Gaspard Seuge" gives "Gaspard"); nil when there is none to use.
    static func firstName(from fullName: String) -> String? {
        let first = fullName.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        return first?.isEmpty == false ? first : nil
    }
}
