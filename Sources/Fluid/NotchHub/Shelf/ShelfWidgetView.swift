import SwiftUI
import UniformTypeIdentifiers

/// Drop files on the notch to park them; drag them back out anywhere.
struct ShelfWidgetView: View {
    @ObservedObject var store: ShelfStore
    var staticLayout = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shelf")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                Spacer()
                if !self.store.items.isEmpty {
                    Button("Clear") { self.store.clear() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            ZStack {
                if self.store.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 24)).foregroundStyle(.white.opacity(0.4))
                        Text("Drop files here").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    }
                } else {
                    if self.staticLayout {
                        self.tiles
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) { self.tiles }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(self.targeted ? 0.7 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            )
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(self.targeted ? 0.1 : 0.03)))
        }
        .foregroundStyle(.white)
        .modifier(ShelfDropTarget(enabled: !self.staticLayout, store: self.store, targeted: self.$targeted))
        .onAppear { if !self.staticLayout { self.store.prune() } }
    }
}

extension ShelfWidgetView {
    fileprivate var tiles: some View {
        HStack(spacing: 10) {
            ForEach(self.store.items) { item in ShelfTile(item: item, store: self.store, draggable: !self.staticLayout) }
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfStore.Item
    let store: ShelfStore
    var draggable = true
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: self.item.path))
                .resizable().frame(width: 48, height: 48)
            Text(self.item.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 84)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(self.hovering ? 0.12 : 0.06)))
        .overlay(alignment: .topTrailing) {
            if self.hovering {
                Button { self.store.remove(self.item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
        .onHover { self.hovering = $0 }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(self.item.url) }
        .modifier(ShelfDragSource(enabled: self.draggable, url: self.item.url))
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(self.item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([self.item.url]) }
            Button("Remove") { self.store.remove(self.item) }
        }
    }
}

/// Drop and drag are AppKit-backed, which the image preview tool can't draw, so previews switch them off.
private struct ShelfDropTarget: ViewModifier {
    let enabled: Bool
    let store: ShelfStore
    @Binding var targeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if self.enabled {
            content.onDrop(of: [.fileURL], isTargeted: self.$targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in self.store.add([url]) }
                    }
                }
                return true
            }
        } else {
            content
        }
    }
}

private struct ShelfDragSource: ViewModifier {
    let enabled: Bool
    let url: URL

    @ViewBuilder
    func body(content: Content) -> some View {
        if self.enabled {
            content.onDrag { NSItemProvider(object: self.url as NSURL) }
        } else {
            content
        }
    }
}
