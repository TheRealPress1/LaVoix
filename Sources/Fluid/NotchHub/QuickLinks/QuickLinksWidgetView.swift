import Combine
import SwiftUI

/// Your quick links as chips; click one and it is on the clipboard.
struct QuickLinksWidgetView: View {
    @ObservedObject var store: QuickLinksStore
    @Environment(\.notchWidgetActive) private var active
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick links")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .textCase(.uppercase)
            if self.store.links.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 24)).foregroundStyle(.white.opacity(0.35))
                    Text("Add your links in myOS → Settings").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(self.store.links) { link in
                            QuickLinkChip(link: link, copied: self.store.copiedID == link.id) { self.store.copy(link) }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { self.store.reload() }
        .onReceive(self.refresh) { _ in if self.active { self.store.reload() } }
    }
}

private struct QuickLinkChip: View {
    let link: QuickLinksStore.Link
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 6) {
                Image(systemName: self.copied ? "checkmark" : "doc.on.doc").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                Text(self.copied ? "Copied" : self.link.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(self.copied ? 0.22 : (self.hovering ? 0.14 : 0.07))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
        .help(self.link.value)
    }
}
