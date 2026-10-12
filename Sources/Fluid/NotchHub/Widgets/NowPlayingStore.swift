import AppKit
import Combine
import Foundation
#if arch(arm64)
import MediaRemoteAdapter
#endif

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

    @Published private(set) var track: Track?
    @Published private(set) var elapsed: TimeInterval = 0

    #if arch(arm64)
    private let controller = MediaController()
    #endif
    private var listening = false
    private var artworkCache: (key: String, image: NSImage)?

    init() {}

    /// Sample state for debug rendering; never talks to the bridge.
    static func sample(playing: Bool = true) -> NowPlayingStore {
        let store = NowPlayingStore()
        store.track = Track(
            title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", appName: "Music",
            bundleID: "com.apple.Music", isPlaying: playing, duration: 200, artwork: sampleArtwork()
        )
        store.elapsed = 74
        return store
    }

    func start() {
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
            // The adapter exits on its own after a while; restart as long as someone is looking.
            Task { @MainActor in
                guard let self, self.listening else { return }
                self.listening = false
                self.start()
            }
        }
        self.controller.startListening()
        #endif
    }

    func stop() {
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
    }
    #endif

    private static func sampleArtwork() -> NSImage {
        let image = NSImage(size: NSSize(width: 120, height: 120))
        image.lockFocus()
        NSGradient(colors: [.systemPink, .systemIndigo])?.draw(in: NSRect(x: 0, y: 0, width: 120, height: 120), angle: 45)
        image.unlockFocus()
        return image
    }
}
