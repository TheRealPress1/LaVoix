// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import Foundation

nonisolated public struct SpotifyTrack: Codable, Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var albumArtist: String?
    public var durationMs: Int?
    public var positionMs: Int?
    public var spotifyUrl: String?
    public var trackNumber: Int?
    public var artworkUrl: String?

    public init(
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        durationMs: Int? = nil,
        positionMs: Int? = nil,
        spotifyUrl: String? = nil,
        trackNumber: Int? = nil,
        artworkUrl: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.durationMs = durationMs
        self.positionMs = positionMs
        self.spotifyUrl = spotifyUrl
        self.trackNumber = trackNumber
        self.artworkUrl = artworkUrl
    }
}

nonisolated public enum SpotifyPlaybackState: String, Codable, Sendable {
    case playing
    case paused
    case stopped
    case notRunning = "not_running"
    case unavailable
}

/// Evidence gathered while reading a player's current track. Provider-backed
/// identities are read before and after the visible metadata so a half-updated
/// player snapshot can never earn listening time. Apple Music tracks without a
/// library identity use metadata only after it repeats on a consecutive poll.
nonisolated public enum PlaybackTrackIdentityEvidence: Equatable, Sendable {
    case provider(String)
    case repeatedMetadata
    case unstable
}

nonisolated public struct SpotifySnapshot: Equatable, Sendable {
    public var state: SpotifyPlaybackState
    public var track: SpotifyTrack?
    public var provider: MusicPlayerKind
    public var identityEvidence: PlaybackTrackIdentityEvidence?

    public init(
        state: SpotifyPlaybackState,
        track: SpotifyTrack? = nil,
        provider: MusicPlayerKind = .spotify,
        identityEvidence: PlaybackTrackIdentityEvidence? = nil
    ) {
        self.state = state
        self.track = track
        self.provider = provider
        self.identityEvidence = identityEvidence
    }
}

/// Provider-neutral names for new code. The aliases preserve the wire contract
/// and source compatibility of the original Spotify-only companion.
public typealias PlaybackTrack = SpotifyTrack
public typealias PlaybackState = SpotifyPlaybackState
public typealias PlaybackSnapshot = SpotifySnapshot
