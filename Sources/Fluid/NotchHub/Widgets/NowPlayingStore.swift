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

        static func == (lhs: Track, rhs: Track) -> Bool {
            lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album
                && lhs.bundleID == rhs.bundleID && lhs.isPlaying == rhs.isPlaying
                && lhs.duration == rhs.duration && (lhs.artwork == nil) == (rhs.artwork == nil)
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

        var key: String { "\(self.title)|\(self.artist ?? "")|\(self.bundleID ?? "")" }
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
        store.history = [
            HistoryItem(id: UUID(), title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", appName: "Music", bundleID: "com.apple.Music", date: now.addingTimeInterval(-90)),
            HistoryItem(id: UUID(), title: "Nights", artist: "Frank Ocean", album: "Blonde", appName: "Spotify", bundleID: "com.spotify.client", date: now.addingTimeInterval(-900)),
            HistoryItem(id: UUID(), title: "Redbone", artist: "Childish Gambino", album: "Awaken, My Love!", appName: "Spotify", bundleID: "com.spotify.client", date: now.addingTimeInterval(-4000)),
            HistoryItem(id: UUID(), title: "3 FREE Mac Apps That Should Not Be This Good", artist: "Renz Sadiwa", album: nil, appName: "Dia", bundleID: "company.thebrowser.dia", date: now.addingTimeInterval(-9000)),
            HistoryItem(id: UUID(), title: "Pink + White", artist: "Frank Ocean", album: "Blonde", appName: "Music", bundleID: "com.apple.Music", date: now.addingTimeInterval(-20000)),
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
            self.track = nil
            return
        }
        let key = p.uniqueIdentifier
        var art = self.artworkCache?.key == key ? self.artworkCache?.image : nil
        if art == nil, let fresh = p.artwork {
            art = fresh
            self.artworkCache = (key, fresh)
        }
        self.track = Track(
            title: title, artist: p.artist, album: p.album, appName: p.applicationName,
            bundleID: p.bundleIdentifier, isPlaying: p.isPlaying ?? false,
            duration: p.durationMicros.map { $0 / 1_000_000 }, artwork: art
        )
        if let current = p.currentElapsedTime { self.elapsed = max(0, current) }
        if NotchNowPlayingSettings.keepsHistory, let track = self.track, track.isPlaying { self.record(track) }
    }
    #endif

    // MARK: - History

    /// Adds a track to the listening history the moment it starts playing. The same track again right away (a pause and
    /// resume, or a repeat) is not logged twice, but it fills in missing artwork.
    func record(_ track: Track, at date: Date = Date()) {
        let item = HistoryItem(
            id: UUID(), title: track.title, artist: track.artist, album: track.album,
            appName: track.appName, bundleID: track.bundleID, date: date
        )
        if let latest = self.history.first, latest.key == item.key {
            if let artwork = track.artwork, !FileManager.default.fileExists(atPath: self.thumbnailURL(latest.id).path) {
                self.saveThumbnail(artwork, id: latest.id)
            }
            return
        }
        if let artwork = track.artwork { self.saveThumbnail(artwork, id: item.id) }
        self.history.insert(item, at: 0)
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
        self.history = saved
    }

    private static func sampleArtwork() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSGradient(colors: [.systemPink, .systemIndigo])?.draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: 45)
        image.unlockFocus()
        return image
    }
}
