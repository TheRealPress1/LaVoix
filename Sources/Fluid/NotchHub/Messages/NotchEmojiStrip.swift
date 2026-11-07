import SwiftUI

/// One row of emojis above a reply box (the conversation keeps its height): the ones used last first, then the common ones, scrolling sideways. Shared by the
/// Messages and WhatsApp tabs, so the two cannot drift apart. A tap hands the emoji to `onPick`; the row stays open so several can be added in a row.
struct NotchEmojiStrip: View {
    let recents: [String]
    var staticLayout = false
    let onPick: (String) -> Void

    var body: some View {
        // A still cannot scroll, so it shows the first dozen instead of laying all of them out at their full width.
        let items = self.staticLayout ? Array(EmojiPalette.strip(recents: self.recents).prefix(11)) : EmojiPalette.strip(recents: self.recents)
        let row = HStack(spacing: 2) {
            ForEach(items, id: \.self) { emoji in
                Button { self.onPick(emoji) } label: {
                    Text(emoji).font(.system(size: 20)).frame(width: 34, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        Group {
            if self.staticLayout {
                row.frame(maxWidth: .infinity, alignment: .leading).clipped()
            } else {
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
        }
        .frame(height: 34)
        .padding(.horizontal, 4)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}
