import SwiftUI

/// Left: what's playing now. Right: what you've played, each with the app or site it came from.
struct NowPlayingWidgetView: View {
    @ObservedObject var store: NowPlayingStore
    @ObservedObject private var bookshelf = BookshelfCapture.shared
    @ObservedObject private var lyrics: LyricsStore
    @State private var rightTab: RightTab
    @Environment(\.notchTabsExpanded) private var tabsExpanded

    /// What the right side can show, in the order the switch lists them. History is what the tab opens on; grading a song is one tap away, not the first thing seen.
    enum RightTab: CaseIterable {
        case history, grade, lyrics

        var label: String {
            switch self {
            case .history: "History"
            case .grade: "Grade"
            case .lyrics: "Lyrics"
            }
        }
    }

    static let defaultRightTab = RightTab.history
    var staticLayout = false
    /// Previews can't load a picture from the web: they draw this instead of the song's cover.
    var previewCover: NSImage? = nil
    /// Where in the song a preview says it is, for the timed lyrics.
    var previewClock: PlaybackClock? = nil

    init(store: NowPlayingStore, lyrics: LyricsStore = .shared, staticLayout: Bool = false, previewCover: NSImage? = nil, previewClock: PlaybackClock? = nil, startOnLyrics: Bool = false) {
        self._store = ObservedObject(wrappedValue: store)
        self._lyrics = ObservedObject(wrappedValue: lyrics)
        self.staticLayout = staticLayout
        self.previewCover = previewCover
        self.previewClock = previewClock
        self._rightTab = State(initialValue: startOnLyrics ? .lyrics : NowPlayingWidgetView.defaultRightTab)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Narrower than the full side and kept off the left edge. With the tab icons unfolded it runs the full height of the room, ending where the
            // list on the right does; with them folded away it is 12 points shorter, so its rounded corners clear the notch's own bottom corners.
            // Shorter by measuring, not by padding: padding makes the column taller than the room and pushes the tab icons down into the notch's bottom edge.
            GeometryReader { geometry in
                self.nowPlaying
                    .frame(width: 236, height: max(0, geometry.size.height - (self.tabsExpanded ? 0 : 12)))
                    .padding(.leading, 8)
            }
            .frame(width: 244)
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1).padding(.vertical, 2).padding(.horizontal, 16)
            self.rightSide
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.store.start() } }
        .onDisappear { if !self.staticLayout { self.store.stop() } }
    }

    // MARK: - Now playing

    @ViewBuilder
    private var nowPlaying: some View {
        if self.showsBookshelfCard {
            self.bookshelfCard
        } else if let track = self.store.track {
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

    /// Bookshelf's song takes the card when there is something to grade and the system's now-playing slot is empty, paused, or someone
    /// else's (macOS keeps naming a paused browser video while Spotify is the thing you want to grade).
    private var showsBookshelfCard: Bool {
        guard self.bookshelf.now.canRate, let title = self.bookshelf.now.title else { return false }
        guard let track = self.store.track else { return true }
        return track.title != title && !track.isPlaying
    }

    /// Whether the card on the left is the song Bookshelf would grade. Grade and Notes belong to Bookshelf's song (read from Spotify or Apple
    /// Music), so they show only beside that song: not beside a browser video or anything else macOS happens to name as playing.
    private var gradesShownCard: Bool {
        guard self.bookshelf.now.canRate, let title = self.bookshelf.now.title else { return false }
        if self.showsBookshelfCard { return true }
        guard let track = self.store.track else { return true }
        if NowPlayingSource.isBrowser(track.bundleID) { return false }
        func plain(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return plain(track.title) == plain(title)
    }

    /// The song's cover fills the whole card, as the artwork of the playing card does, with the title and artist and the playback buttons over a dark
    /// fade at its foot.
    private var bookshelfCard: some View {
        let n = self.bookshelf.now
        return ZStack(alignment: .bottomLeading) {
            self.bookshelfCover(n.artworkURL)
            LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .black.opacity(0.9), location: 1)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 7) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title ?? "").font(.system(size: 13.5, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Text([n.artist, n.provider?.displayName].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                .shadow(color: .black.opacity(0.5), radius: 4)
                // These act on the player the card shows (Spotify or Apple Music), not on whatever macOS names as playing.
                HStack(spacing: 10) {
                    NowPlayingControlButton(symbol: "backward.fill", size: 15, label: "Previous") { Task { await self.bookshelf.send(.previous) } }
                    NowPlayingControlButton(symbol: n.state == .playing ? "pause.fill" : "play.fill", size: 22, label: n.state == .playing ? "Pause" : "Play") { Task { await self.bookshelf.send(.playPause) } }
                    NowPlayingControlButton(symbol: "forward.fill", size: 15, label: "Next") { Task { await self.bookshelf.send(.next) } }
                }
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.4), radius: 3)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// The cover, filling the card. Drawn as an overlay of an empty box so the picture fills the card but can't make it any bigger.
    private func bookshelfCover(_ urlString: String?) -> some View {
        Color.clear
            .overlay(
                Group {
                    if let preview = self.previewCover {
                        Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        AsyncImage(url: urlString.flatMap(URL.init(string:))) { image in
                            image.resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        } placeholder: {
                            LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
                                .overlay(Image(systemName: "music.note").font(.system(size: 28, weight: .light)).foregroundStyle(.white.opacity(0.4)))
                        }
                    }
                }
            )
            .clipped()
    }

    /// The card fills the whole left side. Whatever picture there is (an album cover, a video's thumbnail) runs edge to edge behind the title
    /// and the controls; with no picture at all, a small logo of where it plays from sits on a plain backdrop.
    private func card(_ track: NowPlayingStore.Track) -> some View {
        let art = track.artwork
        let wide = art != nil
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
                    .overlay(Image(nsImage: wide ? art : NowPlayingArtwork.soft(art)).resizable().interpolation(.high).aspectRatio(contentMode: .fill))
                    .clipped()
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
                Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                // No artwork at all: show where it's from, not an empty box.
                ZStack {
                    Color.white.opacity(0.1)
                    NowPlayingSourceLogo(source: track.shownSite, bundleID: track.bundleID, size: 30)
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
                NowPlayingSourceLogo(source: track.shownSite, bundleID: track.bundleID, size: 13)
                Text(self.detailLine(track)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 4)
    }

    /// "Channel · 1.2M views", or the artist for music. The source (Spotify, YouTube...) is the logo beside this line, so its name is not repeated here.
    private func detailLine(_ track: NowPlayingStore.Track) -> String {
        var parts: [String] = []
        if let artist = track.artist, !artist.isEmpty { parts.append(artist) }
        if let views = track.viewCount { parts.append(NowPlayingArtwork.viewsText(views)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func scrubber(_ track: NowPlayingStore.Track) -> some View {
        if let duration = track.duration, duration > 0 {
            HStack(spacing: 8) {
                ElapsedText(clock: self.store.clock).frame(width: 34, alignment: .leading)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        ElapsedFill(clock: self.store.clock, duration: duration, width: proxy.size.width)
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
            .lineLimit(1)
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func controls(_ track: NowPlayingStore.Track) -> some View {
        HStack(spacing: 10) {
            NowPlayingControlButton(symbol: "backward.fill", size: 15, label: "Previous") { self.store.previous() }
            NowPlayingControlButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 22, label: track.isPlaying ? "Pause" : "Play") { self.store.togglePlayPause() }
            NowPlayingControlButton(symbol: "forward.fill", size: 15, label: "Next") { self.store.next() }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.4), radius: 3)
    }

    // MARK: - Right side: your grade and note, or the history

    /// The song the Lyrics tab looks for: the one on the card (Bookshelf's when it has the card, else the one macOS names), when it has a title and an artist.
    private var lyricsQuery: LyricsQuery? {
        guard NotchNowPlayingSettings.showsLyrics else { return nil }
        if self.showsBookshelfCard {
            let now = self.bookshelf.now
            guard let title = now.title, !title.isEmpty, let artist = now.artist, !artist.isEmpty else { return nil }
            return LyricsQuery(title: title, artist: artist, album: nil, duration: nil)
        }
        guard let track = self.store.track, !track.title.isEmpty, let artist = track.artist, !artist.isEmpty else { return nil }
        return LyricsQuery(title: track.title, artist: artist, album: track.album, duration: track.duration)
    }

    /// The song's own clock, for timed lyrics: not available for a song only Bookshelf knows about.
    private var lyricsClock: PlaybackClock? {
        if let previewClock = self.previewClock { return previewClock }
        return self.showsBookshelfCard ? nil : self.store.clock
    }

    /// The tabs on the right, in the order they are listed: History always, Grade while Bookshelf has a song to grade, Lyrics while there is a song to look up.
    private var rightTabs: [RightTab] {
        var tabs: [RightTab] = [.history]
        if self.gradesShownCard, !self.staticLayout { tabs.append(.grade) }
        if self.lyricsQuery != nil { tabs.append(.lyrics) }
        return tabs
    }

    /// The tab shown: the one chosen, or History when the one chosen is not there (the song ended, or has nothing to grade).
    private func shownTab(_ tabs: [RightTab]) -> RightTab { tabs.contains(self.rightTab) ? self.rightTab : .history }

    /// The history, with a switch to Grade and Notes and to Lyrics when there is more than the history to show (the history is what it opens on).
    @ViewBuilder
    private var rightSide: some View {
        let tabs = self.rightTabs
        if tabs.count > 1 {
            let shown = self.shownTab(tabs)
            VStack(alignment: .leading, spacing: 8) {
                self.tabSwitch(tabs, shown: shown)
                switch shown {
                case .grade: BookshelfGradePanel(capture: self.bookshelf)
                case .lyrics:
                    if let query = self.lyricsQuery {
                        LyricsPanel(lyrics: self.lyrics, query: query, clock: self.lyricsClock, staticLayout: self.staticLayout) { seconds in
                            if let duration = self.store.track?.duration, duration > 0 { self.store.seek(toFraction: seconds / duration) }
                        }
                    }
                case .history: self.historyBody
                }
            }
        } else {
            self.history
        }
    }

    private func tabSwitch(_ tabs: [RightTab], shown: RightTab) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.label) { tab in
                Button { self.rightTab = tab } label: {
                    Text(tab.label).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(shown == tab ? 1 : 0.5))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(shown == tab ? 0.16 : 0)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if shown == .history, !self.store.history.isEmpty {
                Button("Clear") { self.store.clearHistory() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            } else if shown == .lyrics {
                Text("LRCLIB").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white.opacity(0.28)).help("Lyrics from lrclib.net")
            }
        }
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
            self.historyBody
        }
    }

    @ViewBuilder
    private var historyBody: some View {
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

    private func rows(_ items: [NowPlayingStore.HistoryItem]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { item in HistoryRow(item: item, store: self.store) }
        }
    }

    fileprivate static func clock(_ seconds: TimeInterval) -> String { NowPlayingClock.text(seconds) }
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
                NowPlayingSourceLogo(source: self.item.shownSite, bundleID: self.item.bundleID, size: 14)
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

/// The running time, redrawn on its own as the track plays.
private struct ElapsedText: View {
    @ObservedObject var clock: PlaybackClock
    var body: some View { Text(NowPlayingWidgetView.clock(self.clock.elapsed)) }
}

/// The filled part of the progress bar, redrawn on its own as the track plays.
private struct ElapsedFill: View {
    @ObservedObject var clock: PlaybackClock
    let duration: TimeInterval
    let width: CGFloat
    var body: some View { Capsule().fill(Color.white).frame(width: max(3, self.width * min(self.clock.elapsed / self.duration, 1))) }
}

/// Your Bookshelf grade and note for the song playing: a big number, a bar to drag (saved when you let go), and a note that saves
/// after you stop typing (or on Return).
private struct BookshelfGradePanel: View {
    @ObservedObject var capture: BookshelfCapture
    @State private var draft: Double?
    @State private var note = ""
    @State private var failure: String?
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var noteFocused: Bool

    var body: some View {
        let now = self.capture.now
        let shown = self.draft ?? now.score
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(shown.map { String(format: "%.1f", $0) } ?? "–").font(.system(size: 28, weight: .semibold).monospacedDigit())
                Text("/ 10").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(self.failure ?? now.status).font(.system(size: 10)).foregroundStyle(.white.opacity(self.failure == nil ? 0.45 : 0.8)).lineLimit(1)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.22))
                    Capsule().fill(Color.white).frame(width: max(4, proxy.size.width * CGFloat((shown ?? 0) / 10)))
                }
                .frame(height: 8)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in self.draft = Self.value(at: value.location.x, width: proxy.size.width) }
                    .onEnded { value in
                        let score = Self.value(at: value.location.x, width: proxy.size.width)
                        self.draft = score
                        self.save(score: score, note: nil)
                    })
            }
            .frame(height: 16)
            Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).textCase(.uppercase)
            TextField("", text: self.$note, prompt: Text("What did you think?").foregroundStyle(.white.opacity(0.4)), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...4)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .tint(.white)
                .focused(self.$noteFocused)
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                .onSubmit { self.saveNote() }
                .onExitCommand { self.noteFocused = false; self.saveNote(); NotchHubController.shared.endTextEntry() }
                .contentShape(Rectangle())
                .onTapGesture {
                    NotchHubController.shared.beginTextEntry()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        self.noteFocused = true
                    }
                }
                .onChange(of: self.note) { _, _ in self.scheduleNoteSave() }
                .onChange(of: self.noteFocused) { _, focused in
                    if focused { NotchHubController.shared.beginTextEntry() } else { self.saveNote() }
                }
            Spacer(minLength: 0)
        }
        .onAppear { self.note = now.note ?? "" }
        .onChange(of: now.title) { _, _ in self.draft = nil; self.note = self.capture.now.note ?? ""; self.failure = nil }
        .onChange(of: now.note) { _, new in if !self.noteFocused { self.note = new ?? "" } }
        .onDisappear { self.saveNote(); NotchHubController.shared.endTextEntry() }
    }

    private func scheduleNoteSave() {
        guard self.noteFocused else { return }
        self.saveTask?.cancel()
        self.saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { self.saveNote() }
        }
    }

    private func saveNote() {
        self.saveTask?.cancel()
        guard self.note != (self.capture.now.note ?? "") else { return }
        self.save(score: self.capture.now.score, note: self.note)
    }

    private func save(score: Double?, note: String?) {
        Task {
            do { try await self.capture.rateNow(score: score, note: note); self.failure = nil } catch { self.failure = (error as? LocalizedError)?.errorDescription ?? "Couldn't save" }
            self.draft = nil
        }
    }

    private static func value(at x: CGFloat, width: CGFloat) -> Double {
        let raw = Double(min(max(x / max(width, 1), 0), 1)) * 10
        return (raw * 10).rounded() / 10
    }
}

/// How a time is written on the progress row: 11:03 under an hour, 1h05 from an hour up (hours and minutes, the seconds dropped), so a long
/// video's length always fits the narrow slot beside the bar instead of wrapping onto a second line.
nonisolated enum NowPlayingClock {
    static func text(_ seconds: TimeInterval) -> String {
        let s = Int(max(seconds, 0))
        return s >= 3600 ? String(format: "%dh%02d", s / 3600, (s % 3600) / 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// A playback button: the whole round area around the symbol takes the click (a 14 pt glyph alone was a target you had to hit exactly), it lights up
/// under the pointer and shrinks a little while pressed, so a press visibly lands.
private struct NowPlayingControlButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.symbol)
                .font(.system(size: self.size))
                .frame(width: 44, height: 38)
                .background(Capsule().fill(Color.white.opacity(self.hovering ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(NowPlayingPressStyle())
        .onHover { self.hovering = $0 }
        .help(self.label)
        .accessibilityLabel(self.label)
    }
}

private struct NowPlayingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
