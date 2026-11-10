@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Which calendar meetings were recorded, and the request that opens a recording in myOS. The recordings are made-up folders in a temporary place:
/// nothing here reads a real recording, and the checks only ever need a title, two times and a state.
final class RecordedMeetingsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("recorded-meetings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
    }

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ hour: Int, _ minute: Int) -> Date {
        self.utc.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: hour, minute: minute))!
    }

    @discardableResult
    private func write(_ folder: String, state: String = "completed", start: String = "2026-11-10T15:00:00Z", end: String? = "2026-11-10T15:30:00Z", title: String = "Standup", raw: String? = nil, modified: Date? = nil) throws -> UUID {
        let id = UUID()
        let directory = self.root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = raw ?? #"{"id":"\#(id.uuidString)","title":"\#(title)","startedAt":"\#(start)","endedAt":\#(end.map { "\"\($0)\"" } ?? "null"),"state":"\#(state)","transcriptSegments":[{"text":"never read"}]}"#
        let file = directory.appendingPathComponent("session.json")
        try body.write(to: file, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
        return id
    }

    private let longAgo = Date(timeIntervalSince1970: 1_790_000_000)

    func testRecordingsAreListedFromTheirFoldersWithoutTheOldAndTheUnreadable() throws {
        let standup = try self.write("a")
        try self.write("b", state: "failed", title: "Broken")
        try self.write("c", title: "Old", modified: Date(timeIntervalSince1970: 1_767_000_000))
        try self.write("d", raw: "{ this is not json")
        let found = RecordedMeetings.scan(root: self.root, modifiedSince: self.longAgo)
        XCTAssertEqual(found.entries.map(\.title).sorted(), ["Broken", "Standup"])
        XCTAssertEqual(found.entries.first { $0.title == "Standup" }?.id, standup)
    }

    func testAFileThatDidNotChangeIsNotReadAgain() throws {
        try self.write("a")
        let first = RecordedMeetings.scan(root: self.root, modifiedSince: self.longAgo)
        let second = RecordedMeetings.scan(root: self.root, modifiedSince: self.longAgo, cache: first.cache)
        XCTAssertEqual(first.entries, second.entries)
        XCTAssertEqual(first.cache, second.cache)
    }

    func testAMeetingIsMatchedToTheRecordingThatOverlapsIt() throws {
        try self.write("a")
        try self.write("b", state: "failed", start: "2026-11-10T16:00:00Z", end: "2026-11-10T16:30:00Z", title: "Broken")
        let entries = RecordedMeetings.scan(root: self.root, modifiedSince: self.longAgo).entries
        XCTAssertEqual(RecordedMeetings.match(title: "Standup", start: self.at(15, 0), end: self.at(15, 30), in: entries)?.title, "Standup")
        XCTAssertNil(RecordedMeetings.match(title: "Broken", start: self.at(16, 0), end: self.at(16, 30), in: entries), "a recording that failed is not a recording")
        XCTAssertNil(RecordedMeetings.match(title: "Standup", start: self.at(9, 0), end: self.at(9, 30), in: entries), "another time")
        XCTAssertNil(RecordedMeetings.match(title: "Long", start: self.at(14, 0), end: self.at(15, 0).addingTimeInterval(30), in: entries), "touching the end by half a minute is not it")
        XCTAssertEqual(RecordedMeetings.match(title: "Call", start: self.at(15, 8), end: self.at(15, 38), in: entries)?.title, "Standup", "a recording that started a few minutes early still counts")
    }

    func testAnAccidentalRecordingAndTheBestNameAreHandled() {
        let tiny = RecordedMeetings.Entry(id: UUID(), title: "Standup", start: self.at(15, 0), end: self.at(15, 0).addingTimeInterval(40), state: "completed")
        XCTAssertNil(RecordedMeetings.match(title: "Standup", start: self.at(15, 0), end: self.at(15, 30), in: [tiny]), "under a minute is an accident")
        let other = RecordedMeetings.Entry(id: UUID(), title: "Something else", start: self.at(15, 0), end: self.at(15, 30), state: "completed")
        let named = RecordedMeetings.Entry(id: UUID(), title: "Standup", start: self.at(15, 0), end: self.at(15, 30), state: "completed")
        XCTAssertEqual(RecordedMeetings.match(title: "standup", start: self.at(15, 0), end: self.at(15, 30), in: [other, named])?.id, named.id)
        let live = RecordedMeetings.Entry(id: UUID(), title: "Standup", start: self.at(15, 0), end: nil, state: "recording")
        XCTAssertNil(RecordedMeetings.match(title: "Standup", start: self.at(15, 0), end: self.at(15, 30), in: [live], now: self.at(15, 20)), "a recording still going has no notes yet")
    }

    func testTheRequestMyOSIsGivenNamesThePageTheMeetingAndTheTime() throws {
        let body = MyOSLink.requestBody(path: "/meetings", query: "id=abc", now: Date(timeIntervalSince1970: 1_800_000_000))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["path"] as? String, "/meetings")
        XCTAssertEqual(object["query"] as? String, "id=abc")
        XCTAssertEqual(object["requested_at"] as? Int, 1_800_000_000)
    }
}
