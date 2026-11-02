import AppKit
import SwiftUI

/// The card Look shows in the notch: what it asks, answers or proposes. Quieter than a connection alert: no coloured disc, a small mark beside the
/// title, the text across the full width of the card, and buttons that are white on the notch's black (the main one solid, the other faint).
struct NotchLookCardView: View {
    let title: String
    let text: String
    /// An SF Symbol name: a small mark beside the title (sparkles, an eye while it reads, a tick, a warning).
    let symbol: String
    let width: CGFloat
    let primaryLabel: String?
    let secondaryLabel: String?
    var onPrimary: () -> Void = {}
    var onSecondary: () -> Void = {}

    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let textFont = NSFont.systemFont(ofSize: 14)
    static let maxLines = 7
    static let sidePadding: CGFloat = 26
    private static let titleHeight: CGFloat = 20
    private static let buttonHeight: CGFloat = 32

    private static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: self.textFont) }

    /// The width the text has inside a card that is `cardWidth` wide.
    static func textWidth(cardWidth: CGFloat) -> CGFloat { cardWidth - self.sidePadding * 2 }

    static func lines(of text: String, cardWidth: CGFloat) -> Int {
        let bounds = (text as NSString).boundingRect(with: CGSize(width: self.textWidth(cardWidth: cardWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: self.textFont])
        return min(self.maxLines, max(1, Int((bounds.height / self.lineHeight).rounded(.up))))
    }

    /// Everything the card needs under the notch band: the title, the text as it wraps, the buttons when there are any, and room at the bottom.
    static func contentHeight(text: String, hasButtons: Bool, cardWidth: CGFloat) -> CGFloat {
        8 + self.titleHeight + 8 + CGFloat(self.lines(of: text, cardWidth: cardWidth)) * self.lineHeight + 2 + (hasButtons ? 14 + self.buttonHeight : 0) + 18
    }

    private var markColor: Color {
        if self.symbol.contains("exclamation") { return Color.orange }
        if self.symbol.contains("checkmark") { return Color(red: 0.36, green: 0.84, blue: 0.5) }
        return Color.white.opacity(0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: self.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(self.markColor)
                Text(self.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .frame(height: Self.titleHeight)
            Text(NotchLinkText.attributed(self.text))
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(Self.lines(of: self.text, cardWidth: self.width))
                .fixedSize(horizontal: false, vertical: true)
            if let primary = self.primaryLabel {
                HStack(spacing: 8) {
                    if let secondary = self.secondaryLabel {
                        Button(action: self.onSecondary) {
                            Text(secondary).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: Self.buttonHeight)
                                .background(Capsule().fill(Color.white.opacity(0.14))).foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: self.onPrimary) {
                        Text(primary).font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: Self.buttonHeight)
                            .background(Capsule().fill(Color.white)).foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.sidePadding)
        .padding(.top, 8)
        .frame(width: self.width, alignment: .leading)
    }
}
