// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import Foundation

/// Decides whether a locally observed sample is worth telling the server about.
///
/// Sampling the player is free — it is an AppleScript call to an app on the same
/// machine. Posting is not: measured against production, a single listener sent
/// 53,064 reports in 24 hours, which was 99% of all traffic the site received.
/// Only about 5% of those covered actual playback. The rest said "nothing is
/// happening" over and over, because the Mac was awake.
///
/// So the widget keeps watching every tick and reports:
///   - every sample while a song is playing, so progress stays live
///   - every state or track change, so a pause, skip or quit is known at once
///   - while paused, until the pause outlives `pausedReportWindowMs`
///   - never while the player is stopped, quit or unavailable, beyond the one
///     report that announced it
///
/// Playback resuming is detected locally, so going quiet costs nothing: the very
/// next playing sample reports immediately with no server round trip to wake it.
nonisolated public struct CaptureReportPolicy: Sendable {
    public struct Configuration: Equatable, Sendable {
        /// How long a pause keeps reporting before the widget goes quiet.
        ///
        /// The server keeps a paused capture candidate for an hour, so silence
        /// well inside that window loses nothing — resuming inside the hour
        /// still lands on the same candidate.
        public var pausedReportWindowMs: Int64

        public init(pausedReportWindowMs: Int64 = 3 * 60 * 1_000) {
            self.pausedReportWindowMs = pausedReportWindowMs
        }
    }

    /// What the last reported sample looked like, so a change can be recognised.
    private struct Reported: Equatable, Sendable {
        var state: SpotifyPlaybackState
        var provider: MusicPlayerKind
        var trackKey: String?
    }

    public private(set) var configuration: Configuration
    private var lastReported: Reported?
    private var pausedSinceMs: Int64?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Call once per sample, in order. Returns true when this sample should be
    /// POSTed. Mutates, so the caller must not ask twice about one sample.
    public mutating func shouldReport(
        _ snapshot: PlaybackSnapshot,
        atMilliseconds observedAtMs: Int64
    ) -> Bool {
        let current = Reported(
            state: snapshot.state,
            provider: snapshot.provider,
            trackKey: snapshot.track.map(Self.trackKey)
        )
        defer { lastReported = current }

        // Anything different is reported immediately: a new song, a pause, a
        // resume, a quit, switching player. This is what keeps the site's
        // now-playing card honest even while the widget is otherwise quiet.
        if current != lastReported {
            pausedSinceMs = current.state == .paused ? observedAtMs : nil
            return true
        }

        switch snapshot.state {
        case .playing:
            // Unchanged and playing: keep reporting every tick. Progress and the
            // ten-second qualification both depend on this cadence, and it is
            // the one case where the traffic is buying something.
            pausedSinceMs = nil
            return true

        case .paused:
            // A pause that is going somewhere is worth following; a pause that
            // has become "walked away from the desk" is not.
            guard let since = pausedSinceMs else {
                pausedSinceMs = observedAtMs
                return true
            }
            // A clock that jumped backwards must not strand the widget in
            // silence, so treat it as the start of a fresh pause.
            if observedAtMs < since {
                pausedSinceMs = observedAtMs
                return true
            }
            return observedAtMs - since < configuration.pausedReportWindowMs

        case .stopped, .notRunning, .unavailable:
            // The change above already told the server. Repeating it says
            // nothing, and this is where 95% of the old traffic came from.
            pausedSinceMs = nil
            return false
        }
    }

    /// Forces the next sample to report whatever it looks like. Used when
    /// something other than playback changed — a fresh sign-in, a new device
    /// credential — and the server's picture may be stale.
    public mutating func invalidate() {
        lastReported = nil
        pausedSinceMs = nil
    }

    private static func trackKey(_ track: SpotifyTrack) -> String {
        // Identity only. Position deliberately excluded: it moves every tick,
        // and treating that as a change would report every sample forever and
        // undo the whole point of this type.
        "\(track.title)\u{0}\(track.artist)\u{0}\(track.album)"
    }
}
