// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import Foundation

nonisolated public enum SpotifyScriptParser {
    public static func parse(_ output: String) -> SpotifySnapshot {
        PlaybackScriptParser.parse(output, provider: .spotify)
    }
}

nonisolated public enum AppleMusicScriptParser {
    public static func parse(_ output: String) -> PlaybackSnapshot {
        PlaybackScriptParser.parse(output, provider: .appleMusic)
    }
}

/// Parses the common tab-delimited result emitted by both Automation scripts.
/// Keeping parsing in the pure core target makes malformed player metadata easy
/// to exercise without invoking Apple Events in tests.
nonisolated public enum PlaybackScriptParser {
    private static let maximumMediaMilliseconds = 24 * 60 * 60 * 1000

    public static func parse(
        _ output: String,
        provider: MusicPlayerKind
    ) -> PlaybackSnapshot {
        // Preserve trailing tab fields: the live scripts append identity reads,
        // and an empty read is meaningful evidence rather than formatting.
        let line = output.trimmingCharacters(in: .newlines)
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return PlaybackSnapshot(state: .unavailable, provider: provider)
        }

        let parts = line.components(separatedBy: "\t")
        let stateValue = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let state = SpotifyPlaybackState(rawValue: stateValue) ?? .unavailable
        guard (state == .playing || state == .paused), parts.count >= 4 else {
            return PlaybackSnapshot(state: state, provider: provider)
        }

        let track = SpotifyTrack(
            title: parts[safe: 1] ?? "",
            artist: parts[safe: 2] ?? "",
            album: parts[safe: 3] ?? "",
            albumArtist: nonEmpty(parts[safe: 4]),
            durationMs: mediaMilliseconds(parts[safe: 5]),
            positionMs: mediaMilliseconds(parts[safe: 6]),
            spotifyUrl: nonEmpty(parts[safe: 7]),
            trackNumber: integer(parts[safe: 8]),
            artworkUrl: nonEmpty(parts[safe: 9])
        )

        if track.title.isEmpty || track.artist.isEmpty || track.album.isEmpty {
            return PlaybackSnapshot(state: state, provider: provider)
        }

        return PlaybackSnapshot(
            state: state,
            track: track,
            provider: provider,
            identityEvidence: identityEvidence(parts: parts, provider: provider, track: track)
        )
    }

    /// Fields 10 and 11 are the provider identity read immediately before and
    /// after metadata. Older parser fixtures have neither field and retain the
    /// legacy URL/metadata inference used by programmatic snapshots.
    private static func identityEvidence(
        parts: [String],
        provider: MusicPlayerKind,
        track: PlaybackTrack
    ) -> PlaybackTrackIdentityEvidence {
        guard parts.count >= 12 else {
            if provider == .spotify, let spotifyUrl = track.spotifyUrl {
                return .provider(spotifyUrl)
            }
            return provider == .appleMusic ? .repeatedMetadata : .unstable
        }

        let before = providerIdentity(parts[safe: 10], provider: provider)
        let after = providerIdentity(parts[safe: 11], provider: provider)
        if let before, let after, before == after {
            // Spotify's URL is read with the rest of the display metadata,
            // between the two identity reads. Requiring all three values to
            // agree prevents a coherent B / stale metadata URL A / coherent B
            // transition sample from accumulating playback time for either
            // recording. Apple Music has no Spotify URL field, so its stable
            // persistent/database ID remains sufficient.
            if provider == .spotify,
               providerIdentity(track.spotifyUrl, provider: provider) != before {
                return .unstable
            }
            return .provider(before)
        }
        if provider == .appleMusic, before == nil, after == nil {
            return .repeatedMetadata
        }
        return .unstable
    }

    /// AppleScript renders a missing descriptor as the literal text
    /// `missing value` when it is coerced to a string. Treating a prefixed
    /// sentinel such as `persistent:missing value` as a provider ID would make
    /// every non-library song share one identity and let transition metadata
    /// bridge unrelated recordings.
    private static func providerIdentity(
        _ value: String?,
        provider: MusicPlayerKind
    ) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        guard provider == .appleMusic else { return value }

        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let payload = normalized.split(separator: ":", maxSplits: 1)
            .last
            .map(String.init) ?? normalized
        guard payload != "missing value",
              payload != "<missing value>",
              payload != "«class msng»" else { return nil }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value, let number = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return number
    }

    private static func mediaMilliseconds(_ value: String?) -> Int? {
        guard let number = integer(value), number >= 0, number <= maximumMediaMilliseconds else {
            return nil
        }
        return number
    }
}

nonisolated private extension Array where Element == String {
    subscript(safe index: Int) -> String? {
        indices.contains(index) ? self[index] : nil
    }
}
