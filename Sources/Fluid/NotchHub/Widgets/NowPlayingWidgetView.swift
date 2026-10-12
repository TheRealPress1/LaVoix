import SwiftUI

/// Artwork, title, scrubber and transport controls for whatever is playing system-wide.
struct NowPlayingWidgetView: View {
    @ObservedObject var store: NowPlayingStore
    var staticLayout = false
    @State private var showHistory: Bool

    init(store: NowPlayingStore, staticLayout: Bool = false, showHistory: Bool = false) {
        self.store = store
        self.staticLayout = staticLayout
        self._showHistory = State(initialValue: showHistory)
    }

    var body: some View {
        Group {
            if self.showHistory {
                self.historyList
            } else if let track = self.store.track {
                self.player(track)
            } else {
                self.empty
            }
        }
        .overlay(alignment: .topTrailing) {
            if NotchNowPlayingSettings.keepsHistory || self.showHistory {
                Button { self.showHistory.toggle() } label: {
                    Image(systemName: self.showHistory ? "chevron.backward" : "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(self.showHistory ? "Back to now playing" : "Listening history")
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.store.start() } }
        .onDisappear { if !self.staticLayout { self.store.stop() } }
    }

    private func player(_ track: NowPlayingStore.Track) -> some View {
        HStack(spacing: 18) {
            self.artwork(track)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Text([track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                self.scrubber(track)
                self.controls(track)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func artwork(_ track: NowPlayingStore.Track) -> some View {
        Group {
            if let image = track.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .scaleEffect(track.isPlaying ? 1 : 0.94)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: track.isPlaying)
    }

    @ViewBuilder
    private func scrubber(_ track: NowPlayingStore.Track) -> some View {
        if let duration = track.duration, duration > 0 {
            VStack(spacing: 4) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.15))
                        Capsule().fill(Color.white)
                            .frame(width: max(4, proxy.size.width * min(self.store.elapsed / duration, 1)))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        self.store.seek(toFraction: value.location.x / max(proxy.size.width, 1))
                    })
                }
                .frame(height: 5)
                HStack {
                    Text(Self.clock(self.store.elapsed))
                    Spacer()
                    Text("-" + Self.clock(max(duration - self.store.elapsed, 0)))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func controls(_ track: NowPlayingStore.Track) -> some View {
        HStack(spacing: 26) {
            Button { self.store.previous() } label: { Image(systemName: "backward.fill") }
            Button { self.store.togglePlayPause() } label: {
                Image(systemName: track.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 24))
            }
            Button { self.store.next() } label: { Image(systemName: "forward.fill") }
            Spacer()
            if let app = track.appName {
                Text(app).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
            }
        }
        .font(.system(size: 18))
        .buttonStyle(.plain)
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recently played")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .textCase(.uppercase)
                Spacer()
                if !self.store.history.isEmpty {
                    Button("Clear") { self.store.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                        .padding(.trailing, 34)
                }
            }
            if self.store.history.isEmpty {
                Text("Songs and videos you play will be listed here")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.staticLayout {
                self.historyRows(Array(self.store.history.prefix(4)))
            } else {
                ScrollView(.vertical, showsIndicators: false) { self.historyRows(self.store.history) }
            }
        }
    }

    private func historyRows(_ items: [NowPlayingStore.HistoryItem]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                HistoryRow(item: item, store: self.store)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note").font(.system(size: 28)).foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, minHeight: 110)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct HistoryRow: View {
    let item: NowPlayingStore.HistoryItem
    let store: NowPlayingStore
    @State private var hovering = false

    var body: some View {
        Button { self.store.search(for: self.item) } label: {
            HStack(spacing: 10) {
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
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(self.item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text([self.item.artist, self.item.appName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(Self.ago(self.item.date)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(self.hovering ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
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
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
