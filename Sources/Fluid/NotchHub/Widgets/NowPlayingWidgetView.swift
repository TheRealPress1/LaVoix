import SwiftUI

/// Artwork, title, scrubber and transport controls for whatever is playing system-wide.
struct NowPlayingWidgetView: View {
    @ObservedObject var store: NowPlayingStore
    var staticLayout = false

    var body: some View {
        Group {
            if let track = self.store.track {
                self.player(track)
            } else {
                self.empty
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
