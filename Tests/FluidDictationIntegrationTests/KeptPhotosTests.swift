@testable import FluidVoice_Debug
import AppKit
import SQLite3
import XCTest

/// A conversation with no picture of its own gets the one myOS keeps for that person. The people and pictures are made up, in a temporary place.
final class KeptPhotosTests: XCTestCase {
    private var root: URL!
    private var photos: URL!
    private var database: URL!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("kept-photos-\(UUID().uuidString)", isDirectory: true)
        self.photos = self.root.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: self.photos, withIntermediateDirectories: true)
        self.database = self.root.appendingPathComponent("system.db")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(self.database.path, &db), SQLITE_OK)
        for sql in [
            "CREATE TABLE person (id TEXT PRIMARY KEY, display_name TEXT NOT NULL, merged_into TEXT)",
            "CREATE TABLE identity (kind TEXT NOT NULL, value_norm TEXT NOT NULL, person_id TEXT NOT NULL, PRIMARY KEY (kind, value_norm))",
            "INSERT INTO person VALUES ('p-a-1', 'Maya Rao', NULL), ('p-b-2', 'Maya R', 'p-a-1'), ('p-c-3', 'Lee Park', NULL), ('../evil', 'Evil', NULL)",
            "INSERT INTO identity VALUES ('phone', '+15551230001', 'p-a-1'), ('email', 'maya@example.com', 'p-a-1'), ('phone', '+15551230002', 'p-b-2'), ('phone', '+15551230003', 'p-c-3'), ('contacts_id', 'CARD-1', 'p-a-1'), ('phone', '+15551230004', '../evil')",
        ] { sqlite3_exec(db, sql, nil, nil, nil) }
        sqlite3_close(db)
        let image = NSImage(size: NSSize(width: 400, height: 400), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: self.photos.appendingPathComponent("p-a-1.img"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
    }

    private func found(_ key: String, card: String? = nil) -> String? {
        PeopleDatabase.photoFile(forHandle: key, contactID: card, url: self.database, photosDirectory: self.photos)?.lastPathComponent
    }

    func testAPersonIsFoundByPhoneNumberEmailOrContactsCard() {
        XCTAssertEqual(self.found("5551230001"), "p-a-1.img", "the end of their phone number")
        XCTAssertEqual(self.found("Maya@Example.com"), "p-a-1.img", "their email, whatever its case")
        XCTAssertEqual(self.found("9990000000", card: "CARD-1"), "p-a-1.img", "the Contacts card the conversation came from")
    }

    func testAMergedPersonIsFollowedToTheOneWithThePicture() {
        XCTAssertEqual(self.found("5551230002"), "p-a-1.img")
    }

    func testNoPictureNoMatchAndHandlesThatMeanNothingGiveNothing() {
        XCTAssertNil(self.found("5551230003"), "a person with no picture")
        for key in ["5559999999", "nobody@example.com", "1234", ""] { XCTAssertNil(self.found(key), key) }
        XCTAssertNil(PeopleDatabase.photoFile(forHandle: "5551230001", url: self.root.appendingPathComponent("missing.db"), photosDirectory: self.photos))
    }

    func testAnIdThatIsNotLettersDigitsAndDashesIsNeverAFilePath() {
        XCTAssertNil(self.found("5551230004"))
    }

    func testAPictureIsScaledDownToAvatarSizeAndAFileThatIsNotOneIsRefused() throws {
        let data = try XCTUnwrap(ContactResolver.avatarData(at: self.photos.appendingPathComponent("p-a-1.img"), maxPixels: 64))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(max(rep.pixelsWide, rep.pixelsHigh), 64)
        let junk = self.photos.appendingPathComponent("junk.img")
        try Data("not an image".utf8).write(to: junk)
        XCTAssertNil(ContactResolver.avatarData(at: junk))
    }
}
