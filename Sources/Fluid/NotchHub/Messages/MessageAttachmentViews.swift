import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Which file the pointer has rested on, shared by the thread and the notification card. A file is enlarged once the pointer has rested on its
/// tile for a moment (not while passing over) and put away the instant the pointer leaves.
@MainActor
final class AttachmentHoverModel: ObservableObject {
    @Published private(set) var enlarged: MessageAttachment?
    /// Told when a file goes on or off the enlarged view (the notification card grows to make room for it).
    var onChange: ((Bool) -> Void)?
    private var token = 0
    static let restDelay: UInt64 = 220_000_000

    func hover(_ file: MessageAttachment, _ inside: Bool) {
        self.token += 1
        guard inside else { self.clear(); return }
        let mine = self.token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.restDelay)
            guard mine == self.token, self.enlarged != file else { return }
            self.enlarged = file
            self.onChange?(true)
        }
    }

    func clear() {
        self.token += 1
        guard self.enlarged != nil else { return }
        self.enlarged = nil
        self.onChange?(false)
    }
}

/// Opening a file from a tile. Messages keeps its files in a protected folder, so the file is opened from a copy in this user's own temporary
/// folder (the app that opens it needs no access to Messages), and copies older than a day are cleared out each time.
enum AttachmentOpener {
    static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("LaVoixOpened", isDirectory: true) }

    /// A copy of the file that any app can open, or nil when the file is not on this Mac.
    static func openableCopy(of file: MessageAttachment) -> URL? {
        let manager = FileManager.default
        guard manager.isReadableFile(atPath: file.path) else { return nil }
        let directory = self.folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = file.name.isEmpty ? file.url.lastPathComponent : file.name
        let copy = directory.appendingPathComponent((name as NSString).lastPathComponent)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: file.url, to: copy)
        } catch {
            return nil
        }
        self.prune(olderThan: 86_400)
        return copy
    }

    @MainActor
    static func open(_ file: MessageAttachment) {
        guard let copy = self.openableCopy(of: file) else { return }
        NSWorkspace.shared.open(copy)
    }

    static func prune(olderThan seconds: TimeInterval) {
        let manager = FileManager.default
        let cutoff = Date().addingTimeInterval(-seconds)
        for entry in (try? manager.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }
}

/// A row of a message's files as small tiles (four at most, then "+3"), with the pointer hover reported to `onHover`.
struct AttachmentTiles: View {
    let files: [MessageAttachment]
    let fromMe: Bool
    var staticLayout = false
    /// The colour of a file's label (a document, a voice message) when it is the user's own; Messages' blue unless another app asks for its own.
    var mineColor: Color = .blue
    var onHover: (MessageAttachment, Bool) -> Void = { _, _ in }
    var onOpen: (MessageAttachment) -> Void = { AttachmentOpener.open($0) }

    static let perRow = 4

    var body: some View {
        let shown = Array(self.files.prefix(Self.perRow))
        let more = self.files.count - shown.count
        HStack(spacing: 4) {
            ForEach(shown) { file in
                AttachmentTile(file: file, fromMe: self.fromMe, staticLayout: self.staticLayout, mineColor: self.mineColor, onHover: { self.onHover(file, $0) }, onOpen: { self.onOpen(file) })
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: AttachmentTile.side, height: AttachmentTile.side)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.12)))
            }
        }
    }
}

/// One attached file. A picture, video or PDF is a small square of the real thing (a play mark on a video); a voice message or any other file is a
/// small label with its icon. The square is the same size before and after the picture is read, so nothing around it jumps. Pressing it opens the file.
struct AttachmentTile: View {
    let file: MessageAttachment
    let fromMe: Bool
    let staticLayout: Bool
    let mineColor: Color
    let onHover: (Bool) -> Void
    let onOpen: () -> Void
    @State private var image: NSImage?

    static let side: CGFloat = 64
    static let pixels = MessageAttachmentImages.tilePixels

    init(file: MessageAttachment, fromMe: Bool, staticLayout: Bool, mineColor: Color = .blue, onHover: @escaping (Bool) -> Void = { _ in }, onOpen: @escaping () -> Void = {}) {
        self.file = file
        self.fromMe = fromMe
        self.staticLayout = staticLayout
        self.mineColor = mineColor
        self.onHover = onHover
        self.onOpen = onOpen
        _image = State(initialValue: staticLayout ? MessageAttachmentImages.load(file, maxPixel: Self.pixels) : MessageAttachmentImages.cached(file, maxPixel: Self.pixels))
    }

    private var hasPicture: Bool { self.file.kind == .image || self.file.kind == .video || self.file.kind == .pdf }

    var body: some View {
        Group {
            if self.hasPicture { self.square } else { self.label }
        }
        .onTapGesture { self.onOpen() }
        .task(id: self.file.id) {
            guard self.hasPicture, self.image == nil, !self.staticLayout else { return }
            // A photo that has just arrived may still be on its way to this Mac: look again a few times before giving up.
            for pause in [0, 0.6, 1.2, 2.4, 4.8] as [Double] {
                if pause > 0 { try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
                if Task.isCancelled { return }
                if let made = await MessageAttachmentImages.image(for: self.file, maxPixel: Self.pixels) {
                    self.image = made
                    return
                }
            }
        }
    }

    private var square: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(self.file.kind == .pdf ? Color.white : Color.white.opacity(0.12))
            if let image = self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: self.file.kind == .pdf ? .fit : .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipped()
            } else {
                // Not on this Mac (Messages keeps old files in iCloud) or still being read.
                Image(systemName: self.file.kind == .video ? "video" : (self.file.kind == .pdf ? "doc.richtext" : "photo"))
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
            }
            if self.file.kind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { self.onHover($0) }
    }

    private var label: some View {
        HStack(spacing: 6) {
            if self.file.kind == .audio {
                Image(systemName: "waveform").font(.system(size: 13, weight: .medium))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: self.file.path)).resizable().frame(width: 18, height: 18)
            }
            Text(self.file.kind == .audio ? "Audio message" : self.file.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 200, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(self.fromMe ? self.mineColor : Color.white.opacity(0.16)))
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A file shown large over the thread (or the card) while the pointer rests on its tile: the whole picture (not the cropped square), what is
/// behind it dimmed. A video plays, muted, in a loop, on top of its first picture, and stops when the pointer leaves.
struct EnlargedFile: View {
    let file: MessageAttachment
    let staticLayout: Bool
    @State private var image: NSImage?

    private static let pixels = MessageAttachmentImages.enlargedPixels

    init(file: MessageAttachment, staticLayout: Bool) {
        self.file = file
        self.staticLayout = staticLayout
        // The small picture the tile already made shows at once while the large one is read.
        let start = staticLayout ? MessageAttachmentImages.load(file, maxPixel: Self.pixels) : (MessageAttachmentImages.cached(file, maxPixel: Self.pixels) ?? MessageAttachmentImages.cached(file, maxPixel: AttachmentTile.pixels))
        _image = State(initialValue: start)
    }

    private var plays: Bool { self.file.kind == .video && !self.staticLayout && self.file.exists }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.62))
            if let image = self.image {
                self.picture(image)
                    .aspectRatio(image.size, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                    .padding(8)
            } else if self.plays {
                MutedVideoView(url: self.file.url)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(8)
            }
        }
        // Never taller than the notch's own content area.
        .frame(maxHeight: 190)
        .task(id: self.file.id) {
            guard !self.staticLayout else { return }
            if let large = await MessageAttachmentImages.image(for: self.file, maxPixel: Self.pixels) { self.image = large }
        }
    }

    /// The still picture, with the moving video over it when the file is a video.
    @ViewBuilder
    private func picture(_ image: NSImage) -> some View {
        ZStack {
            Image(nsImage: image).resizable().interpolation(.high)
            if self.plays { MutedVideoView(url: self.file.url) }
        }
    }
}

/// A video played quietly, from the start, over and over. It makes its own player and lets go of the file as soon as it is stopped.
@MainActor
final class LoopingMutedPlayer {
    let player: AVPlayer
    private(set) var loops = 0
    private var observer: NSObjectProtocol?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        self.player = AVPlayer(playerItem: item)
        self.player.isMuted = true
        self.player.actionAtItemEnd = .none
        self.observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.loops += 1
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
    }

    func play() { self.player.play() }

    func stop() {
        self.player.pause()
        self.player.replaceCurrentItem(with: nil)
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
    }
}

private final class PlayerHostView: NSView {
    let looping: LoopingMutedPlayer
    private let playerLayer = AVPlayerLayer()

    init(url: URL) {
        self.looping = LoopingMutedPlayer(url: url)
        super.init(frame: .zero)
        self.wantsLayer = true
        self.playerLayer.player = self.looping.player
        self.playerLayer.videoGravity = .resizeAspect
        self.layer?.addSublayer(self.playerLayer)
        self.looping.play()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        self.playerLayer.frame = self.bounds
    }
}

private struct MutedVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSView { PlayerHostView(url: self.url) }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? PlayerHostView)?.looping.stop() }
}

/// A tiny picture of a file beside "Photo" in the conversation list (a symbol for a voice message or another file).
struct AttachmentMiniThumb: View {
    let file: MessageAttachment
    var staticLayout = false
    @State private var image: NSImage?

    static let side: CGFloat = 15
    static let pixels = 48

    init(file: MessageAttachment, staticLayout: Bool = false) {
        self.file = file
        self.staticLayout = staticLayout
        _image = State(initialValue: staticLayout ? MessageAttachmentImages.load(file, maxPixel: Self.pixels) : MessageAttachmentImages.cached(file, maxPixel: Self.pixels))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.14))
            if let image = self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: self.file.kind == .pdf ? .fit : .fill)
                    .frame(width: Self.side, height: Self.side)
                    .clipped()
            } else {
                Image(systemName: self.symbol).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: self.file.id) {
            guard self.image == nil, !self.staticLayout, self.file.kind == .image || self.file.kind == .video || self.file.kind == .pdf else { return }
            self.image = await MessageAttachmentImages.image(for: self.file, maxPixel: Self.pixels)
        }
    }

    private var symbol: String {
        switch self.file.kind {
        case .image: return "photo"
        case .video: return "video.fill"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .file: return "doc.fill"
        }
    }
}
