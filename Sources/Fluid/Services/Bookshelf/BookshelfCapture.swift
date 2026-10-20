import AppKit
import Foundation

/// What Bookshelf's Mac app does while a song plays, done here so myOS can be the paired device: read the native Spotify or Music app
/// (never audio), turn plausible playing samples into listening time with Bookshelf's own tracker, and report to Bookshelf as often as
/// its own policy allows. The reported track gets a rating target back, which is what a grade is written against.
/// Reading players, the tracker and the report policy are Bookshelf's code, vendored unchanged (see `Vendored/`).
@MainActor
final class BookshelfCapture {
    static let shared = BookshelfCapture()

    /// What is playing, as Bookshelf sees it, for myOS and the notch.
    struct Now: Equatable {
        var state: PlaybackState
        var provider: MusicPlayerKind?
        var title: String?
        var artist: String?
        var album: String?
        var artworkURL: String?
        /// A grade can be saved right now (Bookshelf handed back somewhere to write it).
        var canRate: Bool
        var score: Double?
        var note: String?
        /// Short, human: "Listening…", "Ready to rate", "Allow myOS to control Spotify", …
        var status: String
    }

    private(set) var now = Now(state: .notRunning, provider: nil, title: nil, artist: nil, album: nil, artworkURL: nil, canRate: false, score: nil, note: nil, status: "Not connected")

    private let store: any BookshelfCredentialStoring
    private let site: URL
    private let sessionConfiguration: URLSessionConfiguration
    private let providers: [MusicPlayerKind: @Sendable () -> PlaybackReadResult]
    private var tracker = PlaybackObservationTracker()
    private var policy = CaptureReportPolicy()
    private var token: String?
    private var ratingTargetId: String?
    private var trackKey = ""
    private var timer: Timer?
    private var inFlight = false
    private var observer: NSObjectProtocol?

    init(
        store: any BookshelfCredentialStoring = KeychainBookshelfCredentials(),
        site: URL = URL(string: "https://bookshelf.music")!,
        sessionConfiguration: URLSessionConfiguration = .default,
        providers: [MusicPlayerKind: @Sendable () -> PlaybackReadResult] = [
            .spotify: { SpotifyAppleScriptProvider.read() },
            .appleMusic: { AppleMusicAppleScriptProvider.read() },
        ]
    ) {
        self.store = store
        self.site = site
        self.sessionConfiguration = sessionConfiguration
        self.providers = providers
    }

    static let credentialsChanged = Notification.Name("BookshelfCredentialsChanged")

    func start(interval: TimeInterval = 1.5) {
        guard self.timer == nil else { return }
        self.reloadToken()
        self.observer = NotificationCenter.default.addObserver(forName: Self.credentialsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadToken() }
        }
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    func stop() {
        self.timer?.invalidate()
        self.timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.observer = nil
    }

    private func reloadToken() {
        self.token = self.store.load()
        self.tracker.reset()
        self.policy.invalidate()
        self.clearTarget()
        if self.token == nil { self.now = Now(state: .notRunning, provider: nil, title: nil, artist: nil, album: nil, artworkURL: nil, canRate: false, score: nil, note: nil, status: "Not connected") }
    }

    private func clearTarget() {
        self.ratingTargetId = nil
        self.trackKey = ""
    }

    private func client() -> ListeningAPIClient? {
        guard let token else { return nil }
        return ListeningAPIClient(siteURL: self.site, token: token, session: URLSession(configuration: self.sessionConfiguration))
    }

    /// Picks the player to follow: whichever is playing, else one that is paused, else the first that answered.
    nonisolated static func choose(_ results: [PlaybackReadResult]) -> PlaybackReadResult? {
        func state(_ r: PlaybackReadResult) -> PlaybackState { r.state }
        return results.first { state($0) == .playing } ?? results.first { state($0) == .paused } ?? results.first
    }

    func tick() async {
        guard self.token != nil, !self.inFlight else { return }
        self.inFlight = true
        defer { self.inFlight = false }

        let readers = self.providers
        let results: [PlaybackReadResult] = await Task.detached(priority: .userInitiated) {
            // Spotify first, so a tie goes to the same player the Bookshelf Mac app prefers.
            [MusicPlayerKind.spotify, .appleMusic].compactMap { readers[$0]?() }
        }.value
        guard let chosen = Self.choose(results) else { return }

        let snapshot: PlaybackSnapshot
        switch chosen {
        case let .success(s): snapshot = s
        case .permissionDenied(let provider):
            self.setIdle(status: "Allow myOS to control \(provider.displayName) in System Settings → Privacy → Automation")
            return
        case let .metadataUnavailable(state, provider):
            snapshot = PlaybackSnapshot(state: state, provider: provider)
        case let .scriptFailure(_, provider):
            self.setIdle(status: "Couldn't read \(provider.displayName)")
            return
        }

        let observedAtMs = Int64(ProcessInfo.processInfo.systemUptime * 1000)
        let observation = self.tracker.observe(snapshot, atMilliseconds: observedAtMs)
        if snapshot.identityEvidence == .unstable { return }

        let key = snapshot.track.map { "\(snapshot.provider.rawValue)|\($0.title)|\($0.artist)|\($0.album)" } ?? ""
        if key != self.trackKey { self.clearTarget(); self.trackKey = key }
        self.showLocally(snapshot)

        // A live track needs verified observation evidence before it is reported; the first Apple Music sample has none.
        if snapshot.state == .playing || snapshot.state == .paused, snapshot.track != nil, snapshot.identityEvidence != nil, observation == nil {
            self.now.status = "Listening…"
            return
        }
        guard self.policy.shouldReport(snapshot, atMilliseconds: observedAtMs), let client = self.client() else { return }
        do {
            let response = try await client.nowPlaying(snapshot, observation: observation)
            guard key == self.trackKey else { return }
            self.apply(response, to: snapshot)
        } catch {
            self.handle(error)
        }
    }

    private func showLocally(_ s: PlaybackSnapshot) {
        let t = s.track
        self.now = Now(
            state: s.state, provider: s.provider, title: t?.title, artist: t?.artist, album: t?.album, artworkURL: t?.artworkUrl,
            canRate: self.ratingTargetId != nil && t != nil, score: self.now.title == t?.title ? self.now.score : nil,
            note: self.now.title == t?.title ? self.now.note : nil, status: self.now.status
        )
    }

    private func apply(_ r: NowPlayingResponse, to s: PlaybackSnapshot) {
        self.ratingTargetId = r.ratingTargetId
        var score: Double?
        var note: String?
        if let current = r.currentTrack, current.title == s.track?.title { score = current.score; note = current.note }
        let status: String
        switch r.status {
        case "observing": status = "Listening…"
        case "session": status = "Ready to rate"
        case "already-reviewed": status = r.publishedReview?.isEditable == true ? "Already reviewed, editable" : "Already reviewed"
        case "standalone": status = r.standaloneRating?.isEditable == true ? "Ready to rate" : "Read-only"
        case "idle": status = s.state == .paused ? "Paused" : "Nothing playing"
        default: status = r.error ?? "Waiting"
        }
        self.now.canRate = r.ratingTargetId != nil && s.track != nil
        self.now.score = score ?? self.now.score
        self.now.note = note ?? self.now.note
        self.now.status = status
    }

    private func setIdle(status: String) {
        self.now = Now(state: .unavailable, provider: nil, title: nil, artist: nil, album: nil, artworkURL: nil, canRate: false, score: nil, note: nil, status: status)
    }

    private func handle(_ error: Error) {
        let ns = error as NSError
        if ns.domain == "BookshelfListen", ns.code == 401 {
            // The site no longer accepts this device (revoked, or another Mac was paired): forget it.
            self.store.delete()
            NotificationCenter.default.post(name: Self.credentialsChanged, object: nil)
            self.now.status = "Bookshelf no longer accepts this device; pair again"
        } else {
            self.now.status = "Couldn't reach Bookshelf"
        }
    }

    /// Writes a grade (nil clears it) for the track playing now.
    func rateNow(score: Double?, note: String?) async throws {
        guard let client = self.client() else { throw EngineBookshelfError.notConnected }
        guard self.now.canRate, let target = self.ratingTargetId, let title = self.now.title else { throw EngineBookshelfError.server("Nothing to grade yet; keep listening.") }
        let checked = try BookshelfRules.score(score)
        do {
            _ = try await client.saveRating(ratingTargetId: target, trackTitle: title, score: checked, note: note)
        } catch let error as NSError where error.domain == "BookshelfListen" {
            throw EngineBookshelfError.server(error.localizedDescription)
        }
        self.now.score = checked
        if let note { self.now.note = note }
        self.now.status = "Saved"
    }
}
