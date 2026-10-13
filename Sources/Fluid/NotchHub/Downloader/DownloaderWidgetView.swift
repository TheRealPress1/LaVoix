import AppKit
import SwiftUI

/// Paste a YouTube link (or take the video that's playing) and get an MP3 in your Music folder.
struct DownloaderWidgetView: View {
    @ObservedObject var downloader: YouTubeDownloader
    var staticLayout = false

    @State private var link = ""
    @State private var notice: String?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if self.downloader.isReady { self.controls } else { self.setup }
            }
            .frame(width: 272)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2).padding(.horizontal, 16)
            self.list.frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.downloader.locateTools() } }
        .onChange(of: self.focused) { _, isFocused in
            if isFocused { NotchHubController.shared.beginTextEntry() }
        }
        // Pasting a link into the box is enough: as soon as it is a complete YouTube video link, it starts.
        .onChange(of: self.link) { _, text in
            if YouTubeDownloader.youTubeURL(from: text) != nil { self.start(text) }
        }
    }

    // MARK: - Left: one box to paste into

    private var controls: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(self.focused ? 0.55 : 0.2), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            VStack(spacing: 10) {
                Image(systemName: "link").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.45))
                Group {
                    if self.staticLayout {
                        Text("Paste a YouTube link").foregroundStyle(.white.opacity(0.55))
                    } else {
                        TextField("", text: self.$link, prompt: Text("Paste a YouTube link").foregroundStyle(.white.opacity(0.55)))
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .tint(.white)
                            .multilineTextAlignment(.center)
                            .focused(self.$focused)
                            .onSubmit { self.start(self.link) }
                            .onExitCommand { self.focused = false; NotchHubController.shared.endTextEntry() }
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .frame(width: 210)
                Text(self.notice ?? "It turns into an MP3 as soon as you paste")
                    .font(.system(size: 11))
                    .foregroundStyle(self.notice == nil ? Color.white.opacity(0.4) : Color.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { self.focusBox() }
    }

    /// Clicking anywhere in the box starts typing into it (the panel has to take the keyboard first).
    private func focusBox() {
        guard !self.staticLayout else { return }
        NotchHubController.shared.beginTextEntry()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.focused = true
        }
    }

    // MARK: - Left: first-time setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 9) {
            self.sectionTitle("Set up the downloader")
            Text("Two free tools do the work. LaVoix runs them on this Mac; nothing goes through a LaVoix server.")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            self.toolRow(
                name: "yt-dlp", ready: self.downloader.ytDlp != nil,
                action: self.downloader.installState == .installing ? "Installing…" : "Install",
                busy: self.downloader.installState == .installing
            ) { self.downloader.installYtDlp() }
            self.toolRow(name: "ffmpeg", ready: self.downloader.ffmpeg != nil, action: "Copy command", busy: false) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                self.notice = "Copied. Paste it into Terminal, then come back."
            }
            if case let .failed(message) = self.downloader.installState {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let notice = self.notice {
                Text(notice).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func toolRow(name: String, ready: Bool, action: String, busy: Bool, run: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Color.green : .white.opacity(0.4))
            Text(name).font(.system(size: 13, weight: .medium))
            Spacer()
            if !ready {
                Button(action: run) {
                    Text(action).font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 11).frame(height: 24).background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 10).frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: - Right: the downloads

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                self.sectionTitle("Downloads")
                Spacer()
                if self.downloader.jobs.contains(where: { !$0.isRunning }) {
                    Button("Clear") { self.downloader.clearFinished() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if self.downloader.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.3))
                    Text("MP3s you make show up here").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.staticLayout {
                self.rows(Array(self.downloader.jobs.prefix(3)))
            } else {
                ScrollView(.vertical, showsIndicators: false) { self.rows(self.downloader.jobs) }
            }
        }
    }

    private func rows(_ jobs: [YouTubeDownloader.Job]) -> some View {
        VStack(spacing: 5) {
            ForEach(jobs) { job in DownloadRow(job: job, downloader: self.downloader, draggable: !self.staticLayout) }
        }
    }

    // MARK: - Bits

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).textCase(.uppercase)
    }

    private func start(_ text: String) {
        if self.downloader.add(text) {
            self.link = ""
            self.notice = nil
        } else {
            self.notice = "That isn't a link to a single YouTube video."
        }
    }
}

private struct DownloadRow: View {
    let job: YouTubeDownloader.Job
    let downloader: YouTubeDownloader
    let draggable: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            self.thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(self.job.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                self.status
            }
            Spacer(minLength: 4)
            self.trailing
        }
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(self.hovering ? 0.11 : 0.06))
        )
        .overlay(alignment: .bottom) {
            if self.job.state == .downloading || self.job.state == .converting {
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(0.85)).frame(width: max(3, proxy.size.width * self.job.progress), height: 2.5)
                }
                .frame(height: 2.5).padding(.horizontal, 10).padding(.bottom, 2)
            }
        }
        .onHover { self.hovering = $0 }
        .modifier(FileDrag(enabled: self.draggable && self.job.state == .done, file: self.job.file))
        .onTapGesture {
            if self.job.state == .done, let file = self.job.file { NSWorkspace.shared.open(file) }
        }
        .contextMenu {
            if let file = self.job.file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Button("Open") { NSWorkspace.shared.open(file) }
            }
            Button("Remove from list") { self.downloader.remove(self.job.id) }
        }
    }

    private var thumbnail: some View {
        Group {
            if let image = self.job.thumbnail {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: self.job.state == .done ? "music.note" : "arrow.down").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        switch self.job.state {
        case .fetching:
            Text("Looking it up…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        case .downloading:
            Text("Downloading \(Int((self.job.progress * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        case .converting:
            Text("Making the MP3…").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        case .done:
            Text(self.detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
        case let .failed(message):
            Text(message).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
        case .cancelled:
            Text("Cancelled").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }

    /// "Blender · 10:35 · 23M views · CC", whatever is known.
    private var detail: String {
        var parts: [String] = []
        if let channel = self.job.channel { parts.append(channel) }
        if let duration = self.job.duration {
            let s = Int(duration)
            parts.append(s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60))
        }
        if let views = self.job.viewCount { parts.append(NowPlayingArtwork.viewsText(views)) }
        if self.job.isCreativeCommons { parts.append("CC") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if self.job.isRunning {
            Button { self.downloader.cancel(self.job.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
        } else if self.job.state == .done, let file = self.job.file, self.hovering {
            Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: {
                Image(systemName: "magnifyingglass.circle.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Show in Finder")
        } else if case .failed = self.job.state {
            Button { self.downloader.remove(self.job.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
        }
    }
}

/// Drag the finished MP3 out of the notch into Finder, Music, a message, or the shelf. Off in image previews.
private struct FileDrag: ViewModifier {
    let enabled: Bool
    let file: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, let file {
            content.onDrag { NSItemProvider(object: file as NSURL) }
        } else {
            content
        }
    }
}
