import AppKit
import Combine
import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

enum NotchNowPlayingSettings {
    private static let historyKey = "LaVoixNotchNowPlayingHistory"

    /// Remember what played, even while the notch is closed. Needs the music listener to run in the background.
    static var keepsHistory: Bool {
        get { UserDefaults.standard.object(forKey: self.historyKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.historyKey) }
    }
}

/// What is playing right now, system-wide (Music, Spotify, browsers, ...), via the MediaRemote bridge.
/// The listener process only runs while the Now Playing widget is on screen.
@MainActor
final class NowPlayingStore: ObservableObject {
    static let shared = NowPlayingStore()

    struct Track: Equatable {
        var title: String
        var artist: String?
        var album: String?
        var appName: String?
        var bundleID: String?
        var isPlaying: Bool
        var duration: TimeInterval?
        var artwork: NSImage?
        var pid: Int32?
        /// Where it's playing from: the app, or the website when it's in a browser and could be read.
        var site: NowPlayingSource?

        /// Same title in the same app is the same item, whatever the artist field says at the moment: browsers fill in
        /// the artist a beat after the title.
        var key: String { "\(self.bundleID ?? "")|\(self.title)" }

        static func == (lhs: Track, rhs: Track) -> Bool {
            lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
                && lhs.bundleID == rhs.bundleID && lhs.isPlaying == rhs.isPlaying
                && lhs.duration == rhs.duration && (lhs.artwork == nil) == (rhs.artwork == nil)
                && lhs.site == rhs.site
        }
    }

    struct HistoryItem: Identifiable, Codable, Equatable {
        var id: UUID
        var title: String
        var artist: String?
        var album: String?
        var appName: String?
        var bundleID: String?
        var date: Date
        /// The website or app it came from, e.g. YouTube. Older entries don't have one.
        var site: NowPlayingSource?

        var key: String { "\(self.bundleID ?? "")|\(self.title)" }
        var source: NowPlayingSource { self.site ?? NowPlayingSource.native(bundleID: self.bundleID, appName: self.appName) }
    }

    static let maxHistory = 100

    @Published private(set) var track: Track?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var history: [HistoryItem] = []

    #if arch(arm64)
    private let controller = MediaController()
    #endif
    private var listening = false
    /// The widget and the history logger can both want the listener; it runs while anyone does.
    private var listenerUsers = 0
    private var artworkCache: (key: String, image: NSImage)?
    private let directory: URL
    private var thumbnailCache: [UUID: NSImage] = [:]

    /// A track is only added to the history once it has been the one playing for this long, so a title that flickers for
    /// a moment (browsers do this) or a song skipped straight away doesn't pollute the list.
    var settleDelay: TimeInterval = 5
    private var candidateKey: String?
    private var settleTask: Task<Void, Never>?
    /// Works out the website a browser track is on. Replaced in tests.
    var siteResolver: (Track) async -> NowPlayingSource? = { track in await NowPlayingStore.resolveSite(for: track) }

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaVoix/NowPlaying", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.loadHistory()
    }

    /// Sample state for debug rendering; never talks to the bridge.
    static func sample(playing: Bool = true) -> NowPlayingStore {
        let store = NowPlayingStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-np-sample-\(UUID().uuidString)"))
        store.track = Track(
            title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", appName: "Music",
            bundleID: "com.apple.Music", isPlaying: playing, duration: 200, artwork: sampleArtwork()
        )
        store.elapsed = 74
        let now = Date()
        store.track?.site = NowPlayingSource(kind: .youtube, name: "YouTube")
        store.track?.bundleID = "company.thebrowser.dia"
        store.track?.appName = "Dia"
        let yt = NowPlayingSource(kind: .youtube, name: "YouTube")
        store.history = [
            HistoryItem(id: UUID(), title: "Weekend Update ft. James Austin Johnson and Ashley Padilla", artist: "Saturday Night Live", album: nil, appName: "Dia", bundleID: "company.thebrowser.dia", date: now.addingTimeInterval(-90), site: yt),
            HistoryItem(id: UUID(), title: "Nights", artist: "Frank Ocean", album: "Blonde", appName: "Spotify", bundleID: "com.spotify.client", date: now.addingTimeInterval(-900), site: nil),
            HistoryItem(id: UUID(), title: "Shark Tank US | Can Aira Secure A Deal?", artist: "Sony Pictures Television", album: nil, appName: "Dia", bundleID: "company.thebrowser.dia", date: now.addingTimeInterval(-4000), site: yt),
            HistoryItem(id: UUID(), title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", appName: "Music", bundleID: "com.apple.Music", date: now.addingTimeInterval(-9000), site: nil),
            HistoryItem(id: UUID(), title: "Redbone", artist: "Childish Gambino", album: "Awaken, My Love!", appName: "Spotify", bundleID: "com.spotify.client", date: now.addingTimeInterval(-20000), site: nil),
        ]
        return store
    }

    /// Starts the listener if nobody else already has. Every `start()` must be matched by a `stop()`.
    func start() {
        self.listenerUsers += 1
        guard self.listenerUsers == 1 else { return }
        self.startListening()
    }

    func stop() {
        guard self.listenerUsers > 0 else { return }
        self.listenerUsers -= 1
        guard self.listenerUsers == 0 else { return }
        self.stopListening()
    }

    private func startListening() {
        guard !self.listening else { return }
        self.listening = true
        #if arch(arm64)
        self.controller.onTrackInfoReceived = { [weak self] info in
            Task { @MainActor in self?.apply(info) }
        }
        self.controller.onPlaybackTimeUpdate = { [weak self] seconds in
            Task { @MainActor in self?.elapsed = max(0, seconds) }
        }
        self.controller.onListenerTerminated = { [weak self] in
            // The adapter exits on its own after a while; restart as long as someone is listening.
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.listening = false
                self.startListening()
            }
        }
        self.controller.startListening()
        #endif
    }

    private func stopListening() {
        guard self.listening else { return }
        self.listening = false
        #if arch(arm64)
        self.controller.onListenerTerminated = nil
        self.controller.stopListening()
        #endif
    }

    func togglePlayPause() {
        #if arch(arm64)
        self.controller.togglePlayPause()
        #endif
        if var t = self.track { t.isPlaying.toggle(); self.track = t }
    }

    func next() {
        #if arch(arm64)
        self.controller.nextTrack()
        #endif
    }

    func previous() {
        #if arch(arm64)
        self.controller.previousTrack()
        #endif
    }

    func seek(toFraction fraction: Double) {
        guard let duration = self.track?.duration, duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        self.elapsed = seconds
        #if arch(arm64)
        self.controller.setTime(seconds: seconds)
        #endif
    }

    #if arch(arm64)
    private func apply(_ info: TrackInfo?) {
        guard let p = info?.payload, let title = p.title, !title.isEmpty else {
            self.trackChanged(nil)
            return
        }
        let key = "\(p.bundleIdentifier ?? "")|\(title)"
        var art = self.artworkCache?.key == key ? self.artworkCache?.image : nil
        if art == nil, let fresh = p.artwork {
            art = fresh
            self.artworkCache = (key, fresh)
        }
        if let current = p.currentElapsedTime { self.elapsed = max(0, current) }
        self.trackChanged(Track(
            title: title, artist: p.artist, album: p.album, appName: p.applicationName,
            bundleID: p.bundleIdentifier, isPlaying: p.isPlaying ?? false,
            duration: p.durationMicros.map { $0 / 1_000_000 }, artwork: art, pid: p.PID
        ))
    }
    #endif

    // MARK: - Tracking what plays

    private var resolvingKey: String?

    /// Every state report from the player comes through here (and tests call it directly).
    func trackChanged(_ new: Track?) {
        guard var track = new else {
            self.track = nil
            self.cancelSettle()
            return
        }
        let previous = self.track
        if let previous, previous.key == track.key { track.site = previous.site }
        self.track = track

        guard track.isPlaying else { self.cancelSettle(); return }
        if track.site == nil, previous?.key != track.key { self.resolveSiteNow(for: track) }
        guard NotchNowPlayingSettings.keepsHistory, self.candidateKey != track.key else { return }
        // Start the countdown for this track; any change of track or pause before it ends discards it.
        self.candidateKey = track.key
        self.settleTask?.cancel()
        let delay = self.settleDelay
        self.settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.candidateKey == track.key,
                  var current = self.track, current.key == track.key, current.isPlaying else { return }
            if current.site == nil, let site = await self.siteResolver(current) {
                current.site = site
                if self.track?.key == current.key { self.track?.site = site }
            }
            self.record(current)
        }
    }

    private func cancelSettle() {
        self.settleTask?.cancel()
        self.settleTask = nil
        self.candidateKey = nil
    }

    /// Looks up the website for the track on screen, so the logo and name show up while it plays.
    private func resolveSiteNow(for track: Track) {
        guard self.resolvingKey != track.key else { return }
        self.resolvingKey = track.key
        Task { [weak self] in
            guard let self else { return }
            let site = await self.siteResolver(track)
            if self.resolvingKey == track.key { self.resolvingKey = nil }
            if let site, self.track?.key == track.key, self.track?.site == nil { self.track?.site = site }
        }
    }

    private static let tabReader = AXBrowserTabReader()

    /// The website a browser track is on. Only the browser's front tab can be read, so this only works while that browser
    /// is the app you're using, and only for sites we recognise; otherwise the track keeps the browser's own name.
    static func resolveSite(for track: Track) async -> NowPlayingSource? {
        guard NowPlayingSource.isBrowser(track.bundleID), let bundle = track.bundleID, let pid = track.pid,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, AXIsProcessTrusted(),
              let url = await self.tabReader.frontmostTabURL(bundleIdentifier: bundle, processID: pid) else { return nil }
        return NowPlayingSource.site(forHost: url.host)
    }

    // MARK: - History

    /// Adds a track to the listening history. Something already in the list (same title in the same app) is moved to the
    /// top and updated instead of added again, so the list holds each thing once, most recent first.
    func record(_ track: Track, at date: Date = Date()) {
        if let index = self.history.firstIndex(where: { $0.key == "\(track.bundleID ?? "")|\(track.title)" }) {
            var existing = self.history.remove(at: index)
            existing.date = date
            if let artist = track.artist, !artist.isEmpty { existing.artist = artist }
            if let album = track.album, !album.isEmpty { existing.album = album }
            if let site = track.site { existing.site = site }
            if let artwork = track.artwork, !FileManager.default.fileExists(atPath: self.thumbnailURL(existing.id).path) {
                self.saveThumbnail(artwork, id: existing.id)
            }
            self.history.insert(existing, at: 0)
        } else {
            let item = HistoryItem(
                id: UUID(), title: track.title, artist: track.artist, album: track.album,
                appName: track.appName, bundleID: track.bundleID, date: date, site: track.site
            )
            if let artwork = track.artwork { self.saveThumbnail(artwork, id: item.id) }
            self.history.insert(item, at: 0)
        }
        while self.history.count > Self.maxHistory { self.removeFiles(self.history.removeLast()) }
        self.saveHistory()
    }

    func removeFromHistory(_ item: HistoryItem) {
        self.removeFiles(item)
        self.history.removeAll { $0.id == item.id }
        self.saveHistory()
    }

    func clearHistory() {
        for item in self.history { self.removeFiles(item) }
        self.history = []
        self.saveHistory()
    }

    func thumbnail(for item: HistoryItem) -> NSImage? {
        if let cached = self.thumbnailCache[item.id] { return cached }
        guard let image = NSImage(contentsOf: self.thumbnailURL(item.id)) else { return nil }
        self.thumbnailCache[item.id] = image
        return image
    }

    /// Opens a search for the track in the app it was playing in (Spotify) or Apple Music.
    func search(for item: HistoryItem) {
        let query = [item.title, item.artist].compactMap { $0 }.joined(separator: " ")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
        let urlString = item.bundleID == "com.spotify.client"
            ? "spotify:search:\(encoded)"
            : "https://music.apple.com/search?term=\(encoded)"
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func thumbnailURL(_ id: UUID) -> URL { self.directory.appendingPathComponent("\(id.uuidString).jpg") }
    private var historyURL: URL { self.directory.appendingPathComponent("history.json") }

    private func removeFiles(_ item: HistoryItem) {
        self.thumbnailCache[item.id] = nil
        try? FileManager.default.removeItem(at: self.thumbnailURL(item.id))
    }

    /// Keeps a small 96 px JPEG, not the full artwork.
    private func saveThumbnail(_ image: NSImage, id: UUID) {
        let side: CGFloat = 96
        let small = NSImage(size: NSSize(width: side, height: side))
        small.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        small.unlockFocus()
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? jpeg.write(to: self.thumbnailURL(id), options: .atomic)
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(self.history) else { return }
        try? data.write(to: self.historyURL, options: .atomic)
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: self.historyURL),
              let saved = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        // Older versions logged every metadata flicker as a new entry; collapse those into one each.
        var seen: [String: Int] = [:]
        var deduped: [HistoryItem] = []
        for item in saved {
            if let index = seen[item.key] {
                if (deduped[index].artist ?? "").isEmpty, let artist = item.artist, !artist.isEmpty { deduped[index].artist = artist }
                if !FileManager.default.fileExists(atPath: self.thumbnailURL(deduped[index].id).path),
                   FileManager.default.fileExists(atPath: self.thumbnailURL(item.id).path) {
                    try? FileManager.default.moveItem(at: self.thumbnailURL(item.id), to: self.thumbnailURL(deduped[index].id))
                } else {
                    self.removeFiles(item)
                }
            } else {
                seen[item.key] = deduped.count
                deduped.append(item)
            }
        }
        self.history = deduped
        if deduped.count != saved.count { self.saveHistory() }
    }

    private static func sampleArtwork() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSGradient(colors: [.systemPink, .systemIndigo])?.draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: 45)
        image.unlockFocus()
        return image
    }
}
