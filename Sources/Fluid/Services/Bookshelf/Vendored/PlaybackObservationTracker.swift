// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import Foundation

/// The monotonic proof attached to a now-playing report. A new UUID identifies
/// each distinct playback, while `activePlaybackMs` only advances between
/// consecutive samples that prove the playhead was moving normally.
nonisolated public struct PlaybackObservation: Codable, Equatable, Sendable {
    public let version: Int
    public let playbackId: UUID
    public let activePlaybackMs: Int

    public init(version: Int = 1, playbackId: UUID, activePlaybackMs: Int) {
        self.version = version
        self.playbackId = playbackId
        self.activePlaybackMs = activePlaybackMs
    }
}

/// A pure, deterministic playback state machine. The caller supplies a
/// monotonic timestamp for every sample, which keeps wall-clock changes from
/// manufacturing listening time and makes every transition directly testable.
nonisolated public struct PlaybackObservationTracker: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var maximumCreditedGapMs: Int64
        public var maximumPauseRetentionMs: Int64
        public var playheadToleranceMs: Int

        public init(
            maximumCreditedGapMs: Int64 = 4_000,
            maximumPauseRetentionMs: Int64 = 60 * 60 * 1_000,
            playheadToleranceMs: Int = 1_000
        ) {
            self.maximumCreditedGapMs = maximumCreditedGapMs
            self.maximumPauseRetentionMs = maximumPauseRetentionMs
            self.playheadToleranceMs = playheadToleranceMs
        }
    }

    private struct Playback: Sendable {
        var provider: MusicPlayerKind
        var trackIdentity: String
        var identityConfirmed: Bool
        var playbackId: UUID
        var activePlaybackMs: Int
        var lastObservedAtMs: Int64
        var lastPositionMs: Int?
        var lastPositionObservedAtMs: Int64?
        var lastDurationMs: Int?
        var lastState: SpotifyPlaybackState
        var inactiveSinceMs: Int64?
    }

    private enum ResolvedIdentity {
        case usable(value: String, needsRepetition: Bool)
        case unstable
    }

    private let configuration: Configuration
    private let makePlaybackId: @Sendable () -> UUID
    private var playback: Playback?

    public init(
        configuration: Configuration = Configuration(),
        playbackIdGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.configuration = configuration
        makePlaybackId = playbackIdGenerator
    }

    /// Observes one complete player sample at a monotonic millisecond value.
    /// Provider-backed observations can be sent immediately with zero active
    /// time. A metadata-only Apple Music identity returns `nil` until the same
    /// metadata repeats; all observations reach the server's qualification
    /// threshold only through plausible playing samples.
    public mutating func observe(
        _ snapshot: PlaybackSnapshot,
        atMilliseconds observedAtMs: Int64
    ) -> PlaybackObservation? {
        switch snapshot.state {
        case .stopped, .notRunning:
            reset()
            return nil
        case .unavailable:
            interrupt(atMilliseconds: observedAtMs)
            return nil
        case .playing, .paused:
            break
        }

        guard let track = snapshot.track else {
            interrupt(atMilliseconds: observedAtMs)
            return nil
        }

        guard case let .usable(identity, needsRepetition) = resolvedIdentity(
            for: snapshot,
            track: track
        ) else {
            // A before/after identity mismatch is positive evidence of a track
            // transition, not a harmless missing field. Drop the old playback
            // so the mixed sample cannot bridge two songs.
            reset()
            return nil
        }

        if let current = playback,
           observedAtMs < current.lastObservedAtMs {
            // Monotonic time going backwards means this tracker cannot safely
            // relate the samples (for example, a reconstructed test clock).
            reset()
        }

        if playback?.provider != snapshot.provider || playback?.trackIdentity != identity {
            playback = makePlayback(
                snapshot: snapshot,
                track: track,
                identity: identity,
                identityConfirmed: !needsRepetition,
                observedAtMs: observedAtMs
            )
            return observation
        }

        guard var current = playback else { return nil }

        if let inactiveSinceMs = current.inactiveSinceMs,
           observedAtMs - inactiveSinceMs >= configuration.maximumPauseRetentionMs {
            playback = makePlayback(
                snapshot: snapshot,
                track: track,
                identity: identity,
                identityConfirmed: !needsRepetition,
                observedAtMs: observedAtMs
            )
            return observation
        }

        if current.lastState == .playing,
           snapshot.state == .playing,
           isEndToStartReplay(
            previousPositionMs: current.lastPositionMs,
            currentPositionMs: track.positionMs,
            durationMs: track.durationMs ?? current.lastDurationMs,
            elapsedMs: observedAtMs - (current.lastPositionObservedAtMs ?? current.lastObservedAtMs)
           ) {
            playback = makePlayback(
                snapshot: snapshot,
                track: track,
                identity: identity,
                identityConfirmed: !needsRepetition,
                observedAtMs: observedAtMs
            )
            return observation
        }

        if needsRepetition {
            current.identityConfirmed = true
        }

        if snapshot.state == .playing {
            if current.lastState == .playing,
               current.identityConfirmed {
                current.activePlaybackMs = addingWithoutOverflow(
                    plausibleActiveMilliseconds(
                        previousObservedAtMs: current.lastObservedAtMs,
                        observedAtMs: observedAtMs,
                        previousPositionMs: current.lastPositionMs,
                        currentPositionMs: track.positionMs
                    ),
                    to: current.activePlaybackMs
                )
            }
            current.inactiveSinceMs = nil
        } else if current.inactiveSinceMs == nil {
            current.inactiveSinceMs = observedAtMs
        }

        current.lastObservedAtMs = observedAtMs
        // Missing player fields are inconclusive, not evidence that the last
        // valid end position disappeared. Retaining them lets the next near-zero
        // sample recognize a replay across one transient Apple Event failure.
        if let positionMs = track.positionMs {
            current.lastPositionMs = positionMs
            current.lastPositionObservedAtMs = observedAtMs
        }
        if let durationMs = track.durationMs {
            current.lastDurationMs = durationMs
        }
        current.lastState = snapshot.state
        playback = current
        return observation
    }

    public mutating func reset() {
        playback = nil
    }

    public var observation: PlaybackObservation? {
        guard let playback, playback.identityConfirmed else { return nil }
        return PlaybackObservation(
            playbackId: playback.playbackId,
            activePlaybackMs: playback.activePlaybackMs
        )
    }

    private func makePlayback(
        snapshot: PlaybackSnapshot,
        track: PlaybackTrack,
        identity: String,
        identityConfirmed: Bool,
        observedAtMs: Int64
    ) -> Playback {
        Playback(
            provider: snapshot.provider,
            trackIdentity: identity,
            identityConfirmed: identityConfirmed,
            playbackId: makePlaybackId(),
            activePlaybackMs: 0,
            lastObservedAtMs: observedAtMs,
            lastPositionMs: track.positionMs,
            lastPositionObservedAtMs: track.positionMs == nil ? nil : observedAtMs,
            lastDurationMs: track.durationMs,
            lastState: snapshot.state,
            inactiveSinceMs: snapshot.state == .paused ? observedAtMs : nil
        )
    }

    private mutating func interrupt(atMilliseconds observedAtMs: Int64) {
        guard var current = playback else { return }
        guard current.identityConfirmed else {
            reset()
            return
        }
        if observedAtMs < current.lastObservedAtMs {
            reset()
            return
        }
        if current.inactiveSinceMs == nil {
            current.inactiveSinceMs = observedAtMs
        }
        current.lastObservedAtMs = observedAtMs
        current.lastState = .unavailable
        playback = current
    }

    private func resolvedIdentity(
        for snapshot: PlaybackSnapshot,
        track: PlaybackTrack
    ) -> ResolvedIdentity {
        switch snapshot.identityEvidence {
        case let .provider(value):
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return .unstable }
            let providerIdentity = snapshot.provider == .spotify
                ? (spotifyTrackIdentity(from: normalized) ?? normalized)
                : normalized.lowercased()
            return .usable(
                value: "\(snapshot.provider.rawValue):provider:\(providerIdentity)",
                needsRepetition: false
            )
        case .repeatedMetadata:
            return .usable(
                value: metadataIdentity(provider: snapshot.provider, track: track),
                needsRepetition: true
            )
        case .unstable:
            return .unstable
        case nil:
            // Source-compatible snapshots created by tests or third-party core
            // clients predate before/after evidence. A Spotify URL is still a
            // provider identity; otherwise use the same repeated fallback as
            // Apple Music. Live scripts always provide explicit evidence.
            if snapshot.provider == .spotify,
               let spotifyIdentity = spotifyTrackIdentity(from: track.spotifyUrl) {
                return .usable(
                    value: "spotify:provider:\(spotifyIdentity)",
                    needsRepetition: false
                )
            }
            return .usable(
                value: metadataIdentity(provider: snapshot.provider, track: track),
                needsRepetition: true
            )
        }
    }

    private func plausibleActiveMilliseconds(
        previousObservedAtMs: Int64,
        observedAtMs: Int64,
        previousPositionMs: Int?,
        currentPositionMs: Int?
    ) -> Int {
        let elapsed = observedAtMs - previousObservedAtMs
        guard elapsed > 0,
              elapsed <= configuration.maximumCreditedGapMs,
              elapsed <= Int64(Int.max),
              let previousPositionMs,
              let currentPositionMs else { return 0 }

        let playheadDelta = currentPositionMs - previousPositionMs
        guard playheadDelta > 0 else { return 0 }

        let elapsedInt = Int(elapsed)
        let lowerBound = max(1, elapsedInt - configuration.playheadToleranceMs)
        let upperBound = elapsedInt + configuration.playheadToleranceMs
        guard playheadDelta >= lowerBound, playheadDelta <= upperBound else { return 0 }

        // Never award more than either the observed wall interval or the
        // playhead's proven advance, even inside the jitter tolerance.
        return min(elapsedInt, playheadDelta)
    }

    private func isEndToStartReplay(
        previousPositionMs: Int?,
        currentPositionMs: Int?,
        durationMs: Int?,
        elapsedMs: Int64
    ) -> Bool {
        guard let previousPositionMs,
              let currentPositionMs,
              let durationMs,
              durationMs > 0,
              currentPositionMs < previousPositionMs else { return false }

        let endWindow = min(
            5_000,
            max(Int(configuration.maximumCreditedGapMs), max(1_000, durationMs / 10))
        )
        let startWindow = min(
            5_000,
            max(Int(configuration.maximumCreditedGapMs), max(1_000, durationMs / 10))
        )
        let plausiblePriorEnd = previousPositionMs >= durationMs - endWindow || (
            elapsedMs > 0 &&
            elapsedMs <= Int64(Int.max) &&
            previousPositionMs + Int(elapsedMs) >= durationMs
        )
        guard plausiblePriorEnd,
              currentPositionMs <= startWindow,
              elapsedMs > 0,
              elapsedMs <= Int64(Int.max) else { return false }

        // Proximity to the end and start is not enough: a person can seek
        // backward from 96s to 1s. A real replay must have traversed the
        // wrapped distance during the elapsed sample interval. This keeps a
        // seek on the same playback ID (and credits that jump with zero time)
        // instead of manufacturing a second listen after another ten seconds.
        let wrappedDistance = (durationMs - previousPositionMs) + currentPositionMs
        let elapsed = Int(elapsedMs)
        let lowerBound = max(1, elapsed - configuration.playheadToleranceMs)
        let upperBound = elapsed + configuration.playheadToleranceMs
        return wrappedDistance >= lowerBound && wrappedDistance <= upperBound
    }

    private func addingWithoutOverflow(_ amount: Int, to total: Int) -> Int {
        guard amount > 0 else { return total }
        return amount > Int.max - total ? Int.max : total + amount
    }

    private func metadataIdentity(provider: MusicPlayerKind, track: PlaybackTrack) -> String {
        let components = [
            track.title,
            track.artist,
            track.album,
            track.albumArtist ?? "",
            track.durationMs.map(String.init) ?? "",
            track.trackNumber.map(String.init) ?? "",
        ]
        return ([provider.rawValue] + components.map(normalizedMetadataComponent))
            .joined(separator: "\u{1f}")
    }

    private func normalizedMetadataComponent(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private func spotifyTrackIdentity(from value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }

        let uriParts = value.split(separator: ":", omittingEmptySubsequences: false)
        if uriParts.count == 3,
           uriParts[0].lowercased() == "spotify",
           uriParts[1].lowercased() == "track",
           !uriParts[2].isEmpty {
            return String(uriParts[2])
        }

        guard let components = URLComponents(string: value),
              components.host?.lowercased() == "open.spotify.com" else { return nil }
        let pathParts = components.path.split(separator: "/")
        guard let trackIndex = pathParts.firstIndex(where: { $0.lowercased() == "track" }) else {
            return nil
        }
        let idIndex = pathParts.index(after: trackIndex)
        guard pathParts.indices.contains(idIndex), !pathParts[idIndex].isEmpty else { return nil }
        return String(pathParts[idIndex])
    }
}
