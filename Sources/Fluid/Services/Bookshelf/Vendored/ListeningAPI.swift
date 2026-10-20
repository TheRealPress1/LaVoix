// Vendored unchanged (apart from `nonisolated` markers and the dropped module import) from bookshelf's mac/BookshelfListen at dd62626, so myOS
// reads players and credits listening exactly the way Bookshelf's own Mac app does. Re-sync from there; do not improve it here.
import Foundation

nonisolated public struct NowPlayingPayload: Codable, Equatable, Sendable {
    public var playerState: SpotifyPlaybackState
    public var track: SpotifyTrack?
    public var provider: MusicPlayerKind
    public var observation: PlaybackObservation?

    public init(
        playerState: SpotifyPlaybackState,
        track: SpotifyTrack?,
        provider: MusicPlayerKind = .spotify,
        observation: PlaybackObservation? = nil
    ) {
        self.playerState = playerState
        self.track = track
        self.provider = provider
        self.observation = observation
    }
}

nonisolated public struct RatingPayload: Codable, Equatable, Sendable {
    public var ratingTargetId: String?
    public var sessionId: String?
    public var publishedReviewSlug: String?
    public var dailyEventId: String?
    public var trackTitle: String
    public var trackNumber: Int?
    public var score: Double?
    public var note: String?

    public init(
        ratingTargetId: String? = nil,
        sessionId: String? = nil,
        publishedReviewSlug: String? = nil,
        dailyEventId: String? = nil,
        trackTitle: String,
        trackNumber: Int? = nil,
        score: Double?,
        note: String?
    ) {
        self.ratingTargetId = ratingTargetId
        self.sessionId = sessionId
        self.publishedReviewSlug = publishedReviewSlug
        self.dailyEventId = dailyEventId
        self.trackTitle = trackTitle
        self.trackNumber = trackNumber
        self.score = score
        self.note = note
    }
}

nonisolated public enum RatingPatchField: String, Codable, CaseIterable, Hashable, Sendable {
    case score
    case note
}

/// A presence-preserving score/note patch.
///
/// `nil` is a meaningful value for either field, so the inclusion booleans are
/// intentionally separate from the values. Encoding an included `nil` emits a
/// JSON null; an unincluded field emits no key at all.
nonisolated public struct RatingFieldPatch: Codable, Equatable, Sendable {
    public var scoreIsIncluded: Bool
    public var score: Double?
    public var noteIsIncluded: Bool
    public var note: String?

    public init(
        scoreIsIncluded: Bool = false,
        score: Double? = nil,
        noteIsIncluded: Bool = false,
        note: String? = nil
    ) {
        self.scoreIsIncluded = scoreIsIncluded
        self.score = score
        self.noteIsIncluded = noteIsIncluded
        self.note = note
    }

    public var fields: [RatingPatchField] {
        var result: [RatingPatchField] = []
        if scoreIsIncluded { result.append(.score) }
        if noteIsIncluded { result.append(.note) }
        return result
    }

    public var isEmpty: Bool { !scoreIsIncluded && !noteIsIncluded }

    private enum CodingKeys: String, CodingKey {
        case score
        case note
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scoreIsIncluded = values.contains(.score)
        score = try values.decodeIfPresent(Double.self, forKey: .score)
        noteIsIncluded = values.contains(.note)
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if scoreIsIncluded {
            if let score {
                try values.encode(score, forKey: .score)
            } else {
                try values.encodeNil(forKey: .score)
            }
        }
        if noteIsIncluded {
            if let note {
                try values.encode(note, forKey: .note)
            } else {
                try values.encodeNil(forKey: .note)
            }
        }
    }
}

nonisolated public struct AlbumNotesPayload: Codable, Equatable, Sendable {
    public var reviewId: String
    public var notes: String

    public init(reviewId: String, notes: String) {
        self.reviewId = reviewId
        self.notes = notes
    }
}

/// The album-notes append endpoint answers `{ ok, revision }` on success and an
/// `error` string otherwise. Every field decodes optionally so an older or
/// partial payload fails soft rather than throwing on a missing key.
nonisolated public struct AlbumNotesResponse: Codable, Sendable {
    public var ok: Bool?
    public var revision: Int?
    public var error: String?

    public init(ok: Bool? = nil, revision: Int? = nil, error: String? = nil) {
        self.ok = ok
        self.revision = revision
        self.error = error
    }
}

nonisolated public struct RatingPatchPayload: Codable, Equatable, Sendable {
    public var version: Int
    public var clientRevision: UInt64
    public var ratingTargetId: String
    public var trackTitle: String
    public var trackNumber: Int?
    public var patch: RatingFieldPatch

    public init(
        version: Int = 1,
        clientRevision: UInt64,
        ratingTargetId: String,
        trackTitle: String,
        trackNumber: Int? = nil,
        patch: RatingFieldPatch
    ) {
        self.version = version
        self.clientRevision = clientRevision
        self.ratingTargetId = ratingTargetId
        self.trackTitle = trackTitle
        self.trackNumber = trackNumber
        self.patch = patch
    }
}

nonisolated public enum RatingPatchStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case applied
    case superseded
    case rejected
}

nonisolated public struct RatingPatchAcknowledgement: Codable, Equatable, Sendable {
    public var version: Int
    public var clientRevision: UInt64
    public var status: RatingPatchStatus
    public var acceptedAt: String?

    public init(
        version: Int = 1,
        clientRevision: UInt64,
        status: RatingPatchStatus,
        acceptedAt: String? = nil
    ) {
        self.version = version
        self.clientRevision = clientRevision
        self.status = status
        self.acceptedAt = acceptedAt
    }
}

/// Owner-facing projection of a durable patch that has not yet been merged
/// into a complete canonical opinion. `fields` is the authoritative mask; the
/// corresponding value may be null to represent an explicit clear.
nonisolated public struct PendingRatingPatch: Codable, Equatable, Sendable {
    public var version: Int
    public var clientRevision: UInt64
    public var status: RatingPatchStatus
    public var acceptedAt: String?
    public var patch: RatingFieldPatch

    public init(
        version: Int = 1,
        clientRevision: UInt64,
        status: RatingPatchStatus = .pending,
        acceptedAt: String? = nil,
        patch: RatingFieldPatch
    ) {
        self.version = version
        self.clientRevision = clientRevision
        self.status = status
        self.acceptedAt = acceptedAt
        self.patch = patch
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case clientRevision
        case status
        case acceptedAt
        case fields
        case score
        case note
        case patch
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        clientRevision = try values.decode(UInt64.self, forKey: .clientRevision)
        status = try values.decodeIfPresent(RatingPatchStatus.self, forKey: .status) ?? .pending
        acceptedAt = try values.decodeIfPresent(String.self, forKey: .acceptedAt)

        if let nestedPatch = try values.decodeIfPresent(RatingFieldPatch.self, forKey: .patch) {
            patch = nestedPatch
            return
        }

        let fields = try values.decodeIfPresent([RatingPatchField].self, forKey: .fields)
        let fieldSet = Set(fields ?? [])
        let scoreIsIncluded = fields == nil ? values.contains(.score) : fieldSet.contains(.score)
        let noteIsIncluded = fields == nil ? values.contains(.note) : fieldSet.contains(.note)
        patch = RatingFieldPatch(
            scoreIsIncluded: scoreIsIncluded,
            score: try values.decodeIfPresent(Double.self, forKey: .score),
            noteIsIncluded: noteIsIncluded,
            note: try values.decodeIfPresent(String.self, forKey: .note)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(clientRevision, forKey: .clientRevision)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(acceptedAt, forKey: .acceptedAt)
        try values.encode(patch.fields, forKey: .fields)
        if patch.scoreIsIncluded {
            if let score = patch.score {
                try values.encode(score, forKey: .score)
            } else {
                try values.encodeNil(forKey: .score)
            }
        }
        if patch.noteIsIncluded {
            if let note = patch.note {
                try values.encode(note, forKey: .note)
            } else {
                try values.encodeNil(forKey: .note)
            }
        }
    }
}

nonisolated public struct NowPlayingResponse: Codable, Sendable {
    public struct Capabilities: Codable, Equatable, Sendable {
        public var ratingPatch: Int?

        public init(ratingPatch: Int? = nil) {
            self.ratingPatch = ratingPatch
        }
    }

    public struct BookshelfDestination: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable {
            case song
            case album
        }

        public var href: String
        public var kind: Kind

        public init(href: String, kind: Kind) {
            self.href = href
            self.kind = kind
        }
    }

    public struct Session: Codable, Sendable {
        public var id: String
        public var artist: String
        public var album: String
        public var currentTrackTitle: String?
        public var spotifyUrl: String?
        public var average: Double?
        public var scoredCount: Int? = nil
    }

    public struct Track: Codable, Sendable {
        public var title: String
        public var score: Double?
        public var note: String?
    }

    public struct DailyEvent: Codable, Sendable {
        public var id: String
        public var listeningDate: String
    }

    public struct PublishedReview: Codable, Sendable {
        public var slug: String
        public var artist: String
        public var album: String
        public var source: String?
        public var isEditable: Bool
        /// The review's album score. Optional because older servers omit it —
        /// both the rating route (on publish) and the already-reviewed poll
        /// send it today, and the album-thoughts prompt renders it in its
        /// score ring, falling back to the pre-publish snapshot's average.
        public var score: Double? = nil
    }

    public struct StandaloneRating: Codable, Sendable {
        public var dailyEventId: String?
        public var isEditable: Bool
    }

    /// Whose archive this widget writes to. Shown in the notch before any track
    /// has played, so the widget is not anonymous while it sits idle.
    public struct Identity: Codable, Sendable {
        public var firstName: String?
    }

    public var status: String
    public var session: Session?
    public var currentTrack: Track?
    public var dailyEvent: DailyEvent?
    public var publishedReview: PublishedReview?
    public var standaloneRating: StandaloneRating?
    public var alreadyReviewedUrl: String?
    public var error: String?
    public var identity: Identity?
    public var observing: Bool? = nil
    public var ratingTargetId: String? = nil
    public var bookshelfDestination: BookshelfDestination? = nil
    public var capabilities: Capabilities? = nil
    public var ratingPatch: RatingPatchAcknowledgement? = nil
    public var pendingRating: PendingRatingPatch? = nil
}

nonisolated public struct RatingResponse: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public var id: String
        public var artist: String
        public var album: String
        public var currentTrackTitle: String?
        public var average: Double?
        public var scoredCount: Int?
        public var totalTracks: Int?
    }

    public var session: Session?
    public var dailyEvent: NowPlayingResponse.DailyEvent?
    public var currentTrack: NowPlayingResponse.Track?
    public var publishedReview: NowPlayingResponse.PublishedReview?
    public var standaloneRating: NowPlayingResponse.StandaloneRating?
    public var error: String?
    public var ratingTargetId: String? = nil
    public var ratingPatch: RatingPatchAcknowledgement? = nil
    public var pendingRating: PendingRatingPatch? = nil
}

nonisolated public struct ListeningHistoryResponse: Codable, Sendable {
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var listeningDate: String
        public var title: String
        /// The track's own credit, guests included.
        public var artist: String
        /// Who the record is by.
        ///
        /// Optional because it is decoded with `decodeIfPresent`, which is what
        /// lets this build talk to a server that predates the field — and to
        /// older rows that never stored one. Both fall back to `artist`.
        public var albumArtist: String?
        public var album: String
        public var artworkUrl: String?
        public var spotifyUrl: String?
        public var score: Double?
        public var note: String?
        public var lastPlayedAt: String
        public var isEditable: Bool

        public init(
            id: String,
            listeningDate: String,
            title: String,
            artist: String,
            albumArtist: String? = nil,
            album: String,
            artworkUrl: String? = nil,
            spotifyUrl: String? = nil,
            score: Double? = nil,
            note: String? = nil,
            lastPlayedAt: String,
            isEditable: Bool
        ) {
            self.id = id
            self.listeningDate = listeningDate
            self.title = title
            self.artist = artist
            self.albumArtist = albumArtist
            self.album = album
            self.artworkUrl = artworkUrl
            self.spotifyUrl = spotifyUrl
            self.score = score
            self.note = note
            self.lastPlayedAt = lastPlayedAt
            self.isEditable = isEditable
        }
    }

    public var events: [Event]

    public init(events: [Event]) {
        self.events = events
    }
}

nonisolated public struct HistoryRatingPayload: Codable, Equatable, Sendable {
    public var dailyEventId: String
    public var score: Double?
    /// `nil` is deliberately omitted for score-only compatibility. A present
    /// empty string clears the note for 0.1.9 clients.
    public var note: String?

    private enum CodingKeys: String, CodingKey {
        case dailyEventId
        case score
        case note
    }

    public init(dailyEventId: String, score: Double?, note: String? = nil) {
        self.dailyEventId = dailyEventId
        self.score = score
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dailyEventId = try values.decode(String.self, forKey: .dailyEventId)
        score = try values.decodeIfPresent(Double.self, forKey: .score)
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dailyEventId, forKey: .dailyEventId)
        if let score {
            try values.encode(score, forKey: .score)
        } else {
            try values.encodeNil(forKey: .score)
        }
        if let note {
            try values.encode(note, forKey: .note)
        }
    }
}

nonisolated public struct ListeningHistoryRatingResponse: Codable, Sendable {
    public var event: ListeningHistoryResponse.Event?
    public var error: String?

    public init(event: ListeningHistoryResponse.Event? = nil, error: String? = nil) {
        self.event = event
        self.error = error
    }
}

nonisolated private struct APIErrorResponse: Codable {
    var error: String?
}

nonisolated public final class ListeningAPIClient: Sendable {
    private let siteURL: URL
    private let token: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(siteURL: URL, token: String, session: URLSession = .shared) {
        self.siteURL = siteURL
        self.token = token
        self.session = session
    }

    public func nowPlaying(
        _ snapshot: SpotifySnapshot,
        observation: PlaybackObservation? = nil
    ) async throws -> NowPlayingResponse {
        let payload = NowPlayingPayload(
            playerState: snapshot.state,
            track: snapshot.track,
            provider: snapshot.provider,
            observation: observation
        )
        let request = try request(path: "/api/listening/now-playing/", payload: payload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(NowPlayingResponse.self, from: data)
    }

    public func saveRating(
        ratingTargetId: String? = nil,
        sessionId: String? = nil,
        publishedReviewSlug: String? = nil,
        dailyEventId: String? = nil,
        trackTitle: String,
        trackNumber: Int? = nil,
        score: Double?,
        note: String?
    ) async throws -> RatingResponse {
        let payload = RatingPayload(
            ratingTargetId: ratingTargetId,
            sessionId: sessionId,
            publishedReviewSlug: publishedReviewSlug,
            dailyEventId: dailyEventId,
            trackTitle: trackTitle,
            trackNumber: trackNumber,
            score: score.map { min(10, max(0, ($0 * 10).rounded() / 10)) },
            note: note
        )
        let request = try request(path: "/api/listening/rating/", payload: payload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(RatingResponse.self, from: data)
    }

    public func saveRatingPatch(_ payload: RatingPatchPayload) async throws -> RatingResponse {
        var normalizedPayload = payload
        if normalizedPayload.patch.scoreIsIncluded {
            normalizedPayload.patch.score = normalizedPayload.patch.score.map {
                min(10, max(0, ($0 * 10).rounded() / 10))
            }
        }
        let request = try request(path: "/api/listening/rating-patch/", payload: normalizedPayload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(RatingResponse.self, from: data)
    }

    /// Appends the listener's typed thoughts to a just-published album review.
    /// Exactly one POST on commit — there is no per-keystroke autosave here — and
    /// the response is decoded fail-soft so a well-formed 2xx with an unexpected
    /// body never crashes the dismissal path.
    public func submitAlbumNotes(reviewId: String, notes: String) async throws -> AlbumNotesResponse {
        // The trailing slash is load-bearing: the site redirects bare paths.
        let payload = AlbumNotesPayload(reviewId: reviewId, notes: notes)
        let request = try request(path: "/api/listening/album-notes/", payload: payload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return (try? decoder.decode(AlbumNotesResponse.self, from: data)) ?? AlbumNotesResponse(ok: true)
    }

    public func listeningHistory(limit: Int = 20) async throws -> ListeningHistoryResponse {
        guard let url = listeningHistoryRequestURL(limit: limit) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(ListeningHistoryResponse.self, from: data)
    }

    /// Updates one past listening row. New clients pass the complete displayed
    /// note on every request; leaving `note` nil retains the score-only wire
    /// shape used by older clients.
    public func saveHistoryRating(
        dailyEventId: String,
        score: Double?,
        note: String? = nil
    ) async throws -> ListeningHistoryRatingResponse {
        let payload = HistoryRatingPayload(
            dailyEventId: dailyEventId,
            score: score.map { min(10, max(0, ($0 * 10).rounded() / 10)) },
            note: note
        )
        let request = try request(path: "/api/listening/history/", payload: payload)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(ListeningHistoryRatingResponse.self, from: data)
    }

    public func encodedHistoryRatingPayload(_ payload: HistoryRatingPayload) throws -> Data {
        try encoder.encode(payload)
    }

    public func listeningHistoryRequestURL(limit: Int) -> URL? {
        // The trailing slash is load-bearing: the site redirects bare paths.
        guard let url = URL(string: "/api/listening/history/", relativeTo: siteURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return components.url
    }

    public func validateConnection() async throws {
        _ = try await nowPlaying(SpotifySnapshot(state: .paused))
    }

    /// Tells the site this Mac finished its own onboarding, so a browser tab
    /// still showing "one step left" can retire that card.
    ///
    /// Nothing already on the wire says this. `validateConnection()` above posts
    /// while pairing, so the site sees a live device and a listening row before
    /// the permission step the browser is waiting on.
    public func reportSetupComplete() async throws {
        // The trailing slash is load-bearing: the site redirects bare paths.
        guard let url = URL(string: "/api/devices/setup-complete/", relativeTo: siteURL)?.absoluteURL
        else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
    }

    public func encodedNowPlayingPayload(
        _ snapshot: SpotifySnapshot,
        observation: PlaybackObservation? = nil
    ) throws -> Data {
        try encoder.encode(
            NowPlayingPayload(
                playerState: snapshot.state,
                track: snapshot.track,
                provider: snapshot.provider,
                observation: observation
            )
        )
    }

    public func encodedRatingPayload(_ payload: RatingPayload) throws -> Data {
        try encoder.encode(payload)
    }

    public func encodedRatingPatchPayload(_ payload: RatingPatchPayload) throws -> Data {
        try encoder.encode(payload)
    }

    private func request<T: Encodable>(path: String, payload: T) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: siteURL)?.absoluteURL else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try encoder.encode(payload)
        return request
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let decoded = try? decoder.decode(APIErrorResponse.self, from: data)
            let message = decoded?.error ?? String(data: data, encoding: .utf8) ?? "Request failed"
            throw NSError(
                domain: "BookshelfListen",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
