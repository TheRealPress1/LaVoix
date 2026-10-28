import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The two places a dragged file can go from the notch.
enum NotchDropTarget: Equatable {
    case shelf
    case messages
}

/// What the open notch shows while a file is being dragged to it: Shelf on the left, iMessage on the right. Hold the file over one for
/// `holdSeconds` and that tab opens at full size (the file is still in your hand, so it can be dropped right into it); or drop it on a half at once.
struct NotchDropSplitView: View {
    /// How long a file must be held over a half before that tab opens.
    static let holdSeconds: Double = 1.5

    @ObservedObject var model: NotchHubModel
    /// Previews can't draw drop targets; this leaves them out.
    var staticLayout = false

    var body: some View {
        HStack(spacing: 14) {
            NotchDropPanel(target: .shelf, title: "Shelf", detail: "Keep it here for later", systemImage: "tray.and.arrow.down.fill", model: self.model, staticLayout: self.staticLayout)
            NotchDropPanel(target: .messages, title: "iMessage", detail: "Send it in a chat", systemImage: "message.fill", model: self.model, staticLayout: self.staticLayout)
        }
        .foregroundStyle(.white)
    }
}

private struct NotchDropPanel: View {
    let target: NotchDropTarget
    let title: String
    let detail: String
    let systemImage: String
    @ObservedObject var model: NotchHubModel
    var staticLayout = false
    /// 0...1, how far the hold has got; animated over the hold time while the file is over this half.
    @State private var progress: CGFloat = 0

    private var hovered: Bool { self.model.dropHover == self.target }

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: self.systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(self.target == .messages ? Color(red: 0.35, green: 0.85, blue: 0.45) : .white.opacity(0.85))
            Text(self.title).font(.system(size: 14, weight: .semibold))
            Text(self.hovered ? "Keep holding to open it" : self.detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { proxy in
                // The fill grows left to right while the file is held over this half.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.14))
                    .frame(width: proxy.size.width * self.progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(self.hovered ? 0.08 : 0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(self.hovered ? 0.7 : 0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .onChange(of: self.hovered) { _, isHovered in
            if isHovered {
                self.progress = 0
                withAnimation(.linear(duration: NotchDropSplitView.holdSeconds)) { self.progress = 1 }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { self.progress = 0 }
            }
        }
        .modifier(NotchDropPanelTarget(enabled: !self.staticLayout, target: self.target))
    }
}

/// Dropping straight onto a half puts the file there at once, without waiting for the hold.
private struct NotchDropPanelTarget: ViewModifier {
    let enabled: Bool
    let target: NotchDropTarget

    @ViewBuilder
    func body(content: Content) -> some View {
        if self.enabled {
            content.onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                let target = self.target
                NotchDropLoader.load(providers) { urls in
                    NotchHubController.shared.dropFinished(on: target, urls: urls)
                }
                return true
            }
        } else {
            content
        }
    }
}

/// Turns what was dropped into files on disk: a file from Finder stays where it is; image data from a browser or another app is saved to a temporary
/// file first (messages and the shelf only deal in files).
enum NotchDropLoader {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [(Int, URL)] = []
        func add(_ url: URL, at index: Int) { self.lock.lock(); self.urls.append((index, url)); self.lock.unlock() }
        var inOrder: [URL] { self.lock.lock(); defer { self.lock.unlock() }; return self.urls.sorted { $0.0 < $1.0 }.map(\.1) }
    }

    @MainActor
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let collected = Collected()
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { collected.add(url, at: index) }
                    group.leave()
                }
            } else if let type = provider.registeredTypeIdentifiers.compactMap({ UTType($0) }).first(where: { $0.conforms(to: .image) }) {
                let name = provider.suggestedName ?? "Image"
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    if let data, let url = Self.saveDropped(data, name: name, type: type) { collected.add(url, at: index) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let urls = collected.inOrder
            MainActor.assumeIsolated { completion(urls) }
        }
    }

    private static func saveDropped(_ data: Data, name: String, type: UTType) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaVoixDrops/\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        let ext = type.preferredFilenameExtension ?? "png"
        let base = (name as NSString).deletingPathExtension.isEmpty ? "Image" : (name as NSString).deletingPathExtension
        let url = folder.appendingPathComponent(base.replacingOccurrences(of: "/", with: "-")).appendingPathExtension(ext)
        return (try? data.write(to: url)) != nil ? url : nil
    }
}
