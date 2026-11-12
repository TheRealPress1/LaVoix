import AppKit
import SwiftUI

/// The card that drops out of the notch when it comes back on (the app opening, or the notch being switched on again): a gold hand in a glass ring that waves
/// once, "Welcome back" in a champagne serif italic that catches the light once, and the greeting for the time of day in small spaced capitals under it.
/// It says the notch is running and then goes by itself.
struct NotchWelcomeCardView: View {
    /// "Good morning, Gaspard": see `greeting`.
    let greeting: String
    /// A still preview draws no animation and shows everything at once.
    var staticLayout = false

    /// Under the notch band: the row (44), a little air above it and more below, where the card's corners curve in.
    static let contentHeight: CGFloat = 8 + 44 + 18

    private static let gold = Color(red: 1.0, green: 0.84, blue: 0.55)
    private static let rose = Color(red: 1.0, green: 0.62, blue: 0.52)
    /// Only for the still preview: where the light is on the title (nil: not on it).
    nonisolated(unsafe) static var previewSheen: Double?
    private static let titleFont = Font.system(size: 22, weight: .semibold, design: .serif).italic()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Bool
    @State private var wave: Double = 0
    /// Where the band of light is along the title: 0 is its left end, 1 its right end; outside that it cannot be seen.
    @State private var sheen: Double = -1
    @State private var glow: Double

    init(greeting: String, staticLayout: Bool = false) {
        self.greeting = greeting
        self.staticLayout = staticLayout
        self._shown = State(initialValue: staticLayout)
        self._glow = State(initialValue: staticLayout ? 0.4 : 0)
        if staticLayout, let sheen = Self.previewSheen { self._sheen = State(initialValue: sheen) }
    }

    var body: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            self.hand
            self.words
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { NotchHubController.shared.dismissBanner() }
        .task {
            guard !self.staticLayout else { return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) { self.shown = true }
            withAnimation(.easeOut(duration: 0.7).delay(0.1)) { self.glow = 0.55 }
            guard !self.reduceMotion else { withAnimation(.easeInOut(duration: 1.2)) { self.glow = 0.3 }; return }
            // Waits for the card to finish dropping, then the hand waves (out, back, out, back, and settles) while the light crosses the title.
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeInOut(duration: 1.05)) { self.sheen = 1.6 }
            withAnimation(.easeInOut(duration: 1.4)) { self.glow = 0.3 }
            for angle in [22.0, -8.0, 18.0, -6.0, 10.0, 0.0] {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.19)) { self.wave = angle }
                try? await Task.sleep(nanoseconds: 190_000_000)
            }
        }
    }

    /// A thin ring of light with a warm glow behind it, and the hand in gold, turning about its wrist.
    private var hand: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.05))
            Circle().strokeBorder(
                LinearGradient(colors: [Self.gold.opacity(0.95), Self.gold.opacity(0.08), Self.rose.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 1
            )
            Image(systemName: "hand.wave.fill")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(LinearGradient(colors: [Self.gold, Color(red: 1.0, green: 0.73, blue: 0.42)], startPoint: .top, endPoint: .bottom))
                .rotationEffect(.degrees(self.wave), anchor: UnitPoint(x: 0.7, y: 0.9))
        }
        .frame(width: 44, height: 44)
        .background {
            // A radial fade behind the ring (not a blurred disc, whose square edge shows on black); a background so it cannot change the ring's size.
            Circle()
                .fill(RadialGradient(colors: [Self.gold.opacity(0.55), Self.gold.opacity(0.16), .clear], center: .center, startRadius: 4, endRadius: 33))
                .frame(width: 66, height: 66)
                .opacity(self.glow / 0.55)
        }
        .scaleEffect(self.shown ? 1 : 0.55)
        .opacity(self.shown ? 1 : 0)
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) {
            self.title
            Text(self.greeting.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .tracking(1.9)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .opacity(self.shown ? 1 : 0)
        .offset(y: self.shown ? 0 : 6)
        .blur(radius: self.shown ? 0 : 5)
        .animation(.easeOut(duration: 0.55).delay(0.12), value: self.shown)
    }

    /// Champagne gold, with a white band of light that crosses it once.
    private var title: some View {
        Text("Welcome back")
            .font(Self.titleFont)
            .tracking(0.3)
            .foregroundStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.93, blue: 0.80), Color(red: 0.98, green: 0.79, blue: 0.53)], startPoint: .leading, endPoint: .trailing))
            .overlay {
                Text("Welcome back")
                    .font(Self.titleFont)
                    .tracking(0.3)
                    .foregroundStyle(LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.5), .init(color: .clear, location: 1)],
                        startPoint: UnitPoint(x: self.sheen - 0.22, y: 0.35), endPoint: UnitPoint(x: self.sheen + 0.22, y: 0.65)
                    ))
            }
            .lineLimit(1)
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
