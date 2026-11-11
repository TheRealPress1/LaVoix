import Combine
import Foundation

/// The Lyrics tab of Now Playing. Lyrics come from LRCLIB (lrclib.net), an open lyrics service that needs no account or key and often has the
/// time of every line, so the line being sung can follow the song.
///
/// What is sent is the song's artist, title, album and length, and only while the Lyrics tab is the one on screen. Nothing is looked up when the tab is not open,
/// and the lyrics found are kept in memory only (a few songs, until the notch restarts).

/// One line of a song and when it starts (seconds from the start). An empty `text` is a gap in the singing.
nonisolated struct LyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

nonisolated struct Lyrics: Equatable {
    /// Timed lines, when the service has them.
    var synced: [LyricLine] = []
    /// The same words without times (always there when there are lyrics at all).
    var plain: [String] = []
    var instrumental = false

    var isEmpty: Bool { self.synced.isEmpty && self.plain.isEmpty && !self.instrumental }
}

/// The song to look for.
nonisolated struct LyricsQuery: Equatable {
    var title: String
    var artist: String
    var album: String?
    var duration: TimeInterval?

    /// A song in the cache is found by this.
    var key: String { "\(self.artist.lowercased())|\(self.title.lowercased())|\(self.album?.lowercased() ?? "")|\(Int(self.duration ?? 0))" }

    /// The title without what a streaming service adds after it ("Love Story - 2024 Remastered Version", "Song (feat. Someone)", "Song [Live]"), so a
    /// search can find the song the lyrics are filed under.
    static func cleanTitle(_ title: String) -> String {
        var text = title
        // " - Remastered 2011", " - 2024 Remaster", " - Radio Edit", " - Live at ...": a dash and then something that is a version, not the name.
        let marker = #"(?i)\s+[-–—]\s+.*\b(remaster(?:ed)?|remix|version|mono|stereo|deluxe|live|edit|mix|bonus|acoustic|instrumental|demo|from)\b.*$"#
        text = text.replacingOccurrences(of: marker, with: "", options: .regularExpression)
        // "(feat. X)", "[Live]", "(Remastered 2009)".
        let bracket = #"(?i)\s*[\(\[][^\)\]]*\b(feat\.?|ft\.?|featuring|with|remaster(?:ed)?|remix|version|live|edit|mix|deluxe|bonus|acoustic|from)\b[^\)\]]*[\)\]]"#
        text = text.replacingOccurrences(of: bracket, with: "", options: .regularExpression)
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? title : clean
    }
}

nonisolated enum LyricsParser {
    private static let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)

    /// `[01:23.45] words` lines (a line may carry several stamps), in time order. Tags like `[ar:Someone]` and lines with no stamp are not lines of the song.
    static func parseSynced(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let range = NSRange(line.startIndex..., in: line)
            let matches = stamp.matches(in: line, range: range)
            guard !matches.isEmpty, let last = matches.last, let tail = Range(last.range, in: line) else { continue }
            let words = line[tail.upperBound...].trimmingCharacters(in: .whitespaces)
            for match in matches {
                func number(_ index: Int) -> Double? {
                    guard match.range(at: index).location != NSNotFound, let r = Range(match.range(at: index), in: line) else { return nil }
                    return Double(line[r])
                }
                guard let minutes = number(1), let seconds = number(2) else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound, let r = Range(match.range(at: 3), in: line) {
                    let digits = String(line[r])
                    fraction = (Double(digits) ?? 0) / pow(10, Double(digits.count))
                }
                lines.append(LyricLine(time: minutes * 60 + seconds + fraction, text: words))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    static func parsePlain(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The index of the line being sung at `time` (a little early, so the highlight is not behind the voice), or nil before the first line.
    static func currentIndex(in lines: [LyricLine], at time: TimeInterval, lead: TimeInterval = 0.35) -> Int? {
        var found: Int?
        for (index, line) in lines.enumerated() {
            if line.time <= time + lead { found = index } else { break }
        }
        return found
    }
}

nonisolated enum LyricsClient {
    static let base = "https://lrclib.net/api"

    private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func getURL(title: String, artist: String, album: String?, duration: TimeInterval?) -> URL? {
        var parts = ["track_name=\(self.encoded(title))", "artist_name=\(self.encoded(artist))"]
        if let album, !album.isEmpty { parts.append("album_name=\(self.encoded(album))") }
        if let duration, duration > 0 { parts.append("duration=\(Int(duration.rounded()))") }
        return URL(string: "\(self.base)/get?\(parts.joined(separator: "&"))")
    }

    static func searchURL(title: String, artist: String) -> URL? {
        URL(string: "\(self.base)/search?track_name=\(self.encoded(title))&artist_name=\(self.encoded(artist))")
    }

    /// One record of the service's answer, as lyrics. nil for a record with no words and not instrumental.
    static func lyrics(from object: [String: Any]) -> Lyrics? {
        var result = Lyrics()
        result.instrumental = object["instrumental"] as? Bool ?? false
        if let synced = object["syncedLyrics"] as? String, !synced.isEmpty { result.synced = LyricsParser.parseSynced(synced) }
        if let plain = object["plainLyrics"] as? String, !plain.isEmpty {
            result.plain = LyricsParser.parsePlain(plain)
        } else if !result.synced.isEmpty {
            result.plain = result.synced.map(\.text)
        }
        return result.isEmpty ? nil : result
    }

    /// The record that is the song, among a search's answers: one whose length is within five seconds of the song's (when it is known), preferring one that has
    /// timed lines.
    static func best(in records: [[String: Any]], duration: TimeInterval?) -> Lyrics? {
        let candidates = records.filter { record in
            guard let duration, duration > 0, let other = (record["duration"] as? NSNumber)?.doubleValue else { return true }
            return abs(other - duration) <= 5
        }
        let found = candidates.compactMap(self.lyrics(from:))
        return found.first { !$0.synced.isEmpty } ?? found.first
    }

    private static func fetch(_ url: URL?, session: URLSession) async -> (status: Int, data: Data)? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("LaVoix notch lyrics (a personal, local-first Mac app)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, data)
    }

    enum Outcome: Equatable {
        case found(Lyrics)
        case notFound
        case failed
    }

    /// The song's lyrics: an exact lookup first, then the same without the extras streaming services add to the title, then a search.
    static func find(_ query: LyricsQuery, session: URLSession = .shared) async -> Outcome {
        var reached = false
        let cleaned = LyricsQuery.cleanTitle(query.title)
        let attempts: [URL?] = [
            self.getURL(title: query.title, artist: query.artist, album: query.album, duration: query.duration),
            cleaned != query.title ? self.getURL(title: cleaned, artist: query.artist, album: query.album, duration: query.duration) : nil,
        ]
        for url in attempts.compactMap({ $0 }) {
            guard let answer = await self.fetch(url, session: session) else { continue }
            reached = true
            if answer.status == 200, let object = (try? JSONSerialization.jsonObject(with: answer.data)) as? [String: Any], let found = self.lyrics(from: object) { return .found(found) }
        }
        if let answer = await self.fetch(self.searchURL(title: cleaned, artist: query.artist), session: session) {
            reached = true
            if answer.status == 200, let records = (try? JSONSerialization.jsonObject(with: answer.data)) as? [[String: Any]], let found = self.best(in: records, duration: query.duration) { return .found(found) }
        }
        return reached ? .notFound : .failed
    }
}

/// What the Lyrics tab shows, and the lyrics it has already fetched.
@MainActor
final class LyricsStore: ObservableObject {
    static let shared = LyricsStore()

    enum State: Equatable {
        case idle, loading, found(Lyrics), notFound, failed
    }

    @Published private(set) var state: State = .idle
    private var current: String?
    private var cache: [String: Lyrics] = [:]
    private var order: [String] = []
    private var task: Task<Void, Never>?
    static let maxCached = 30

    /// How the lyrics are fetched. Tests replace this.
    var find: (LyricsQuery) async -> LyricsClient.Outcome = { await LyricsClient.find($0) }

    /// A store that shows what it was given and never reaches the network (previews and tests).
    static func fixed(_ state: State) -> LyricsStore {
        let store = LyricsStore()
        store.state = state
        store.current = "fixed"
        store.find = { _ in .failed }
        return store
    }

    /// Shows the lyrics of `query`: from the cache, or by asking the service. Asking again for the song already shown does nothing.
    func load(_ query: LyricsQuery, force: Bool = false) {
        let key = query.key
        if !force, key == self.current, self.state != .idle { if self.state != .failed { return } }
        self.task?.cancel()
        self.current = key
        if let cached = self.cache[key] { self.state = .found(cached); return }
        self.state = .loading
        self.task = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.find(query)
            guard !Task.isCancelled, self.current == key else { return }
            switch outcome {
            case let .found(lyrics):
                self.remember(lyrics, for: key)
                self.state = .found(lyrics)
            case .notFound: self.state = .notFound
            case .failed: self.state = .failed
            }
        }
    }

    private func remember(_ lyrics: Lyrics, for key: String) {
        self.cache[key] = lyrics
        self.order.removeAll { $0 == key }
        self.order.append(key)
        while self.order.count > Self.maxCached { self.cache[self.order.removeFirst()] = nil }
    }

    /// The tab is closed or the song is gone: nothing is shown and nothing more is asked for.
    func stop() {
        self.task?.cancel()
        self.task = nil
        self.current = nil
        self.state = .idle
    }
}
