import SwiftUI

/// The Lyrics tab: the words of the song playing. When the service has the time of every line, the line being sung is bright and the rest follow it up the
/// panel (pressing a line jumps the song there); otherwise the words are shown as plain text.
struct LyricsPanel: View {
    @ObservedObject var lyrics: LyricsStore
    let query: LyricsQuery
    /// Where in the song it is, when that is known (it is not for a song only Bookshelf knows about, which then shows plain words).
    var clock: PlaybackClock?
    var staticLayout = false
    var onSeek: (TimeInterval) -> Void = { _ in }

    var body: some View {
        Group {
            switch self.lyrics.state {
            case .idle, .loading:
                self.message(icon: nil, "Finding lyrics…")
            case .notFound:
                self.message(icon: "text.quote", "No lyrics found for this song")
            case .failed:
                VStack(spacing: 8) {
                    self.message(icon: "wifi.slash", "Could not reach the lyrics service")
                    Button("Try again") { self.lyrics.load(self.query, force: true) }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 24).background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .found(found):
                if found.instrumental && found.synced.isEmpty && found.plain.allSatisfy(\.isEmpty) {
                    self.message(icon: "music.note", "Instrumental")
                } else if !found.synced.isEmpty, let clock = self.clock {
                    SyncedLyrics(lines: found.synced, clock: clock, staticLayout: self.staticLayout, onSeek: self.onSeek)
                } else {
                    self.plain(found.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Looks for the words when the tab opens and again when the song changes; nothing is asked for while another tab is showing.
        .task(id: self.query.key) { if !self.staticLayout { self.lyrics.load(self.query) } }
        .onDisappear { if !self.staticLayout { self.lyrics.stop() } }
    }

    private func message(icon: String?, _ text: String) -> some View {
        VStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 22, weight: .light)).foregroundStyle(.white.opacity(0.35))
            } else if !self.staticLayout {
                ProgressView().controlSize(.small).colorScheme(.dark)
            }
            Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func plain(_ lines: [String]) -> some View {
        let content = VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Color.clear.frame(height: 8)
                } else {
                    Text(line).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.85)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 6)
        if self.staticLayout {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).overlay(alignment: .topLeading) { content }.clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) { content }
        }
    }
}

/// Timed lyrics that follow the song. Its own view so only it is redrawn as the clock ticks.
private struct SyncedLyrics: View {
    let lines: [LyricLine]
    @ObservedObject var clock: PlaybackClock
    let staticLayout: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        let current = LyricsParser.currentIndex(in: self.lines, at: self.clock.elapsed)
        if self.staticLayout {
            // Previews can't draw a scroll view: the line being sung and the ones around it.
            let first = max(0, (current ?? 0) - 1)
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(self.lines.enumerated()).dropFirst(first).prefix(5), id: \.offset) { index, line in self.row(index, line, current: current) }
                    }
                    .padding(.top, 8)
                }
                .clipped()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Color.clear.frame(height: 40)
                        ForEach(Array(self.lines.enumerated()), id: \.offset) { index, line in
                            self.row(index, line, current: current).id(index)
                        }
                        Color.clear.frame(height: 90)
                    }
                }
                .onChange(of: current) { _, new in
                    if let new { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(new, anchor: .center) } }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
                // The words fade out at the top and the bottom edge instead of being cut off.
                .mask(
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 22)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 22)
                    }
                )
            }
        }
    }

    private func row(_ index: Int, _ line: LyricLine, current: Int?) -> some View {
        let sung = current.map { index < $0 } ?? false
        let here = index == current
        return Text(line.text.isEmpty ? "♪" : line.text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white.opacity(here ? 1 : (sung ? 0.3 : 0.5)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture { self.onSeek(line.time) }
            .animation(.easeOut(duration: 0.25), value: here)
    }
}
