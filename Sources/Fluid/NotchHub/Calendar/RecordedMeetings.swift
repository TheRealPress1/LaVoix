import Combine
import Foundation

/// Which calendar meetings have a recording. A recording is not tied to the calendar event it came from in any file the notch can read (the link is
/// only kept in memory while it records), so the notch matches by time: a finished recording that overlaps the meeting.
///
/// Only the title, the times and the state of each recording are read, from its `session.json`; the words that were said are never looked at.
nonisolated enum RecordedMeetings {
    struct Entry: Equatable, Identifiable {
        let id: UUID
        let title: String
        let start: Date
        let end: Date?
        let state: String
    }

    /// What is kept from one `session.json` between looks, so a file that did not change is not read again.
    struct Cached: Equatable {
        let modified: Date
        let entry: Entry?
    }

    /// The few keys of `session.json` that are read; the decoder ignores every other key.
    private struct Header: Decodable {
        let id: UUID
        let title: String
        let startedAt: Date
        let endedAt: Date?
        let state: String
    }

    /// A recording whose audio is kept and that has run its course: finished, being written up, or cut short (the audio is saved).
    static let finishedStates: Set<String> = ["completed", "processing", "stopping", "interrupted"]

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FluidVoice", isDirectory: true).appendingPathComponent("Meetings", isDirectory: true)
    }

    /// The recordings whose file changed on or after `modifiedSince`, with `cache` carrying what earlier looks found. A recording that cannot be read
    /// is left out.
    static func scan(root: URL = defaultRoot, modifiedSince: Date, cache: [String: Cached] = [:], fileManager: FileManager = .default) -> (entries: [Entry], cache: [String: Cached]) {
        guard let folders = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return ([], cache) }
        var kept: [String: Cached] = [:]
        var entries: [Entry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for folder in folders {
            let file = folder.appendingPathComponent("session.json")
            guard let modified = (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date, modified >= modifiedSince else { continue }
            let key = folder.lastPathComponent
            if let known = cache[key], known.modified == modified {
                kept[key] = known
                if let entry = known.entry { entries.append(entry) }
                continue
            }
            var entry: Entry?
            if let data = try? Data(contentsOf: file, options: .mappedIfSafe), let header = try? decoder.decode(Header.self, from: data) {
                entry = Entry(id: header.id, title: header.title, start: header.startedAt, end: header.endedAt, state: header.state)
            }
            kept[key] = Cached(modified: modified, entry: entry)
            if let entry { entries.append(entry) }
        }
        return (entries.sorted { $0.start > $1.start }, kept)
    }

    /// The recording of a meeting: a finished recording of at least a minute that overlaps it by two minutes, or by a quarter of the meeting, or that
    /// started within ten minutes of it. The one with the most overlap wins, and one named like the meeting beats the rest.
    static func match(title: String, start: Date, end: Date, in entries: [Entry], now: Date = Date()) -> Entry? {
        let length = max(60, end.timeIntervalSince(start))
        let wanted = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var best: (entry: Entry, score: Double)?
        for entry in entries where self.finishedStates.contains(entry.state) {
            let entryEnd = entry.end ?? now
            guard entryEnd.timeIntervalSince(entry.start) >= 60 else { continue }
            let overlap = min(end, entryEnd).timeIntervalSince(max(start, entry.start))
            guard overlap > 0 else { continue }
            let nearStart = abs(entry.start.timeIntervalSince(start)) <= 10 * 60
            guard overlap >= 120 || overlap / length >= 0.25 || nearStart else { continue }
            let named = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
            let score = overlap + (named ? 1_000_000 : 0)
            if best == nil || score > best!.score { best = (entry, score) }
        }
        return best?.entry
    }
}

/// The recordings the notch's calendar knows about, refreshed while the Calendar tab is on screen.
@MainActor
final class RecordedMeetingsStore: ObservableObject {
    static let shared = RecordedMeetingsStore()

    @Published private(set) var entries: [RecordedMeetings.Entry] = []
    private var cache: [String: RecordedMeetings.Cached] = [:]
    private var scanning = false

    /// A store that only holds what it was given (render previews and tests); it never reads the disk.
    static func fixed(_ entries: [RecordedMeetings.Entry]) -> RecordedMeetingsStore {
        let store = RecordedMeetingsStore()
        store.entries = entries
        store.isFixed = true
        return store
    }

    private var isFixed = false

    /// Looks again for recordings that changed since the day before `day` (a recording of a meeting on `day` was last written on or after it).
    func refresh(since day: Date) async {
        guard !self.isFixed, !self.scanning else { return }
        self.scanning = true
        defer { self.scanning = false }
        let since = Calendar.current.startOfDay(for: day).addingTimeInterval(-86400)
        let known = self.cache
        let found = await Task.detached(priority: .utility) { RecordedMeetings.scan(modifiedSince: since, cache: known) }.value
        self.cache = found.cache
        if found.entries != self.entries { self.entries = found.entries }
    }

    /// The recording of this meeting, if there is one.
    func recording(for event: CalendarStore.Event) -> RecordedMeetings.Entry? {
        guard !event.isAllDay else { return nil }
        return RecordedMeetings.match(title: event.title, start: event.start, end: event.end, in: self.entries)
    }
}
