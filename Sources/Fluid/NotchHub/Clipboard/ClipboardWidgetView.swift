import SwiftUI

/// Recent copies; click one to put it back on the clipboard.
struct ClipboardWidgetView: View {
    @ObservedObject var store: ClipboardStore
    var staticLayout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                Spacer()
                if !self.store.entries.isEmpty {
                    Button("Clear") { self.store.clear() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if self.store.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 24)).foregroundStyle(.white.opacity(0.35))
                    Text("Things you copy show up here").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The image preview tool can't draw scroll views, so previews get a plain list.
                if self.staticLayout {
                    self.rows(Array(self.store.entries.prefix(4)))
                } else {
                    ScrollView(.vertical, showsIndicators: false) { self.rows(self.store.entries) }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.store.poll() } }
    }
}

extension ClipboardWidgetView {
    fileprivate func rows(_ entries: [ClipboardStore.Entry]) -> some View {
        VStack(spacing: 4) {
            ForEach(entries) { entry in
                ClipboardRow(entry: entry, store: self.store, copied: self.store.copiedID == entry.id)
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardStore.Entry
    let store: ClipboardStore
    let copied: Bool
    @State private var hovering = false

    var body: some View {
        Button { self.store.copy(self.entry) } label: {
            HStack(spacing: 10) {
                self.icon.frame(width: 28, height: 28)
                Text(self.preview)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if self.copied {
                    Text("Copied").font(.system(size: 11, weight: .semibold))
                } else {
                    Text(self.caption).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(self.copied ? 0.2 : (self.hovering ? 0.12 : 0.06))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
        .contextMenu { Button("Delete") { self.store.remove(self.entry) } }
    }

    @ViewBuilder
    private var icon: some View {
        switch self.entry.kind {
        case .text:
            Image(systemName: "text.alignleft").font(.system(size: 14)).foregroundStyle(.white.opacity(0.5))
        case .image:
            if let image = self.store.thumbnail(for: self.entry) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: "photo").foregroundStyle(.white.opacity(0.5))
            }
        case .files:
            if let path = self.entry.paths?.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 24, height: 24)
            }
        }
    }

    private var preview: String {
        switch self.entry.kind {
        case .text:
            return (self.entry.text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        case .image:
            return "Image"
        case .files:
            let names = (self.entry.paths ?? []).map { ($0 as NSString).lastPathComponent }
            return names.count > 1 ? "\(names[0]) and \(names.count - 1) more" : (names.first ?? "File")
        }
    }

    private var caption: String {
        let age = RelativeDateTimeFormatter.short.localizedString(for: self.entry.date, relativeTo: Date())
        return [self.entry.app, age].compactMap { $0 }.joined(separator: " · ")
    }
}

extension RelativeDateTimeFormatter {
    fileprivate static let short: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
