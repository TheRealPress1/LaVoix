import SwiftUI

/// Left: what's playing now. Right: what you've played, each with the app or site it came from.
struct NowPlayingWidgetView: View {
    @ObservedObject var store: NowPlayingStore
    var staticLayout = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            self.nowPlaying
                .frame(width: 262)
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
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    self.artwork(track)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle = self.subtitle(track) {
                            Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            NowPlayingSourceLogo(source: track.site, bundleID: track.bundleID, size: 13)
                            Text(track.site?.name ?? track.appName ?? "")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                self.scrubber(track)
                self.controls(track)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "music.note").font(.system(size: 26, weight: .light)).foregroundStyle(.white.opacity(0.35))
                Text("Nothing playing").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func subtitle(_ track: NowPlayingStore.Track) -> String? {
        let parts = [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func artwork(_ track: NowPlayingStore.Track) -> some View {
        Group {
            if let image = track.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(track.isPlaying ? 1 : 0.6)
        .animation(.easeOut(duration: 0.2), value: track.isPlaying)
    }

    @ViewBuilder
    private func scrubber(_ track: NowPlayingStore.Track) -> some View {
        if let duration = track.duration, duration > 0 {
            HStack(spacing: 8) {
                Text(Self.clock(self.store.elapsed)).frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
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
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func controls(_ track: NowPlayingStore.Track) -> some View {
        HStack(spacing: 30) {
            Button { self.store.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 15)) }
            Button { self.store.togglePlayPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 21))
                    .frame(width: 26)
            }
            Button { self.store.next() } label: { Image(systemName: "forward.fill").font(.system(size: 15)) }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
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
                Text([self.item.artist.flatMap { $0.isEmpty ? nil : $0 }, self.item.source.name].compactMap { $0 }.joined(separator: " · "))
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
