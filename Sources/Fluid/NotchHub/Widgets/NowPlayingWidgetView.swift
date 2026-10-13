import SwiftUI

/// Left: what's playing now. Right: what you've played, each with the app or site it came from.
struct NowPlayingWidgetView: View {
    @ObservedObject var store: NowPlayingStore
    var staticLayout = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            self.nowPlaying
                .frame(width: 272)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2).padding(.horizontal, 16)
            self.history
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.store.start() } }
        .onDisappear { if !self.staticLayout { self.store.stop() } }
    }

    // MARK: - Now playing

    @ViewBuilder
    private var nowPlaying: some View {
        if let track = self.store.track {
            self.card(track)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.35))
                Text("Nothing playing").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
        }
    }

    /// The card fills the whole left side. A widescreen thumbnail (a video) runs edge to edge; anything else (a square
    /// album cover, or no artwork) sits on a blurred backdrop of itself.
    private func card(_ track: NowPlayingStore.Track) -> some View {
        let art = track.artwork
        let wide = art.map { $0.size.width / max($0.size.height, 1) >= 1.4 } ?? false
        return ZStack(alignment: .bottom) {
            self.backdrop(track, art: art, wide: wide)
            VStack(alignment: .leading, spacing: 7) {
                if wide {
                    Spacer(minLength: 0)
                    self.titleBlock(track)
                } else {
                    HStack(alignment: .top, spacing: 11) {
                        self.coverArt(track, art: art)
                        self.titleBlock(track)
                    }
                    Spacer(minLength: 0)
                }
                self.scrubber(track)
                self.controls(track)
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func backdrop(_ track: NowPlayingStore.Track, art: NSImage?, wide: Bool) -> some View {
        ZStack {
            if let art {
                // Drawn as an overlay of an empty box so the image fills the card but can't make it any wider.
                Color.clear
                    .overlay(Image(nsImage: art).resizable().aspectRatio(contentMode: .fill))
                    .clipped()
                    .blur(radius: wide ? 0 : 28)
                    .brightness(wide ? 0 : -0.25)
            } else {
                LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            LinearGradient(
                stops: [.init(color: .clear, location: wide ? 0.25 : 0), .init(color: .black.opacity(0.9), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .opacity(track.isPlaying ? 1 : 0.75)
        .animation(.easeOut(duration: 0.2), value: track.isPlaying)
    }

    private func coverArt(_ track: NowPlayingStore.Track, art: NSImage?) -> some View {
        Group {
            if let art {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                // No artwork at all: show where it's from, not an empty box.
                ZStack {
                    Color.white.opacity(0.1)
                    NowPlayingSourceLogo(source: track.site, bundleID: track.bundleID, size: 30)
                }
            }
        }
        .frame(width: 62, height: 62)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func titleBlock(_ track: NowPlayingStore.Track) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title)
                .font(.system(size: 13.5, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                NowPlayingSourceLogo(source: track.site, bundleID: track.bundleID, size: 13)
                Text(self.detailLine(track)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    /// "Channel · 1.2M views · YouTube", or the artist and source for music.
    private func detailLine(_ track: NowPlayingStore.Track) -> String {
        var parts: [String] = []
        if let artist = track.artist, !artist.isEmpty { parts.append(artist) }
        if let views = track.viewCount { parts.append(NowPlayingArtwork.viewsText(views)) }
        parts.append(track.site?.name ?? track.appName ?? "")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func scrubber(_ track: NowPlayingStore.Track) -> some View {
        if let duration = track.duration, duration > 0 {
            HStack(spacing: 8) {
                Text(Self.clock(self.store.elapsed)).frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white)
                            .frame(width: max(3, proxy.size.width * min(self.store.elapsed / duration, 1)))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        self.store.seek(toFraction: value.location.x / max(proxy.size.width, 1))
                    })
                }
                .frame(height: 14)
                Text(Self.clock(duration)).frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func controls(_ track: NowPlayingStore.Track) -> some View {
        HStack(spacing: 30) {
            Button { self.store.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 14)) }
            Button { self.store.togglePlayPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20))
                    .frame(width: 26)
            }
            Button { self.store.next() } label: { Image(systemName: "forward.fill").font(.system(size: 14)) }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    // MARK: - History

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                Spacer()
                if !self.store.history.isEmpty {
                    Button("Clear") { self.store.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if self.store.history.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.35))
                    Text(NotchNowPlayingSettings.keepsHistory ? "What you play will be listed here" : "History is turned off in settings")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.staticLayout {
                self.rows(Array(self.store.history.prefix(3)))
            } else {
                ScrollView(.vertical, showsIndicators: false) { self.rows(self.store.history) }
            }
        }
    }

    private func rows(_ items: [NowPlayingStore.HistoryItem]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in HistoryRow(item: item, store: self.store) }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct HistoryRow: View {
    let item: NowPlayingStore.HistoryItem
    let store: NowPlayingStore
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image = self.store.thumbnail(for: self.item) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                NowPlayingSourceLogo(source: self.item.site, bundleID: self.item.bundleID, size: 14)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.black, lineWidth: 1.5))
                    .offset(x: 4, y: 4)
            }
            .frame(width: 36, height: 36, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 1) {
                Text(self.item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text([self.item.artist.flatMap { $0.isEmpty ? nil : $0 }, self.item.viewCount.map(NowPlayingArtwork.viewsText), self.item.source.name].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 6)
            if self.hovering {
                Button { self.store.removeFromHistory(self.item) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            } else {
                Text(Self.ago(self.item.date)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(self.hovering ? 0.12 : 0.05)))
        .contentShape(Rectangle())
        .onHover { self.hovering = $0 }
        .onTapGesture { self.store.search(for: self.item) }
        .contextMenu {
            Button("Search for it") { self.store.search(for: self.item) }
            Button("Remove from history") { self.store.removeFromHistory(self.item) }
        }
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        if seconds < 172_800 { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
