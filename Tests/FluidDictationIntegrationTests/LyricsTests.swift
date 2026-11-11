@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The Lyrics tab of Now Playing: reading timed lines, which line is being sung, how a title is cleaned for the search, the addresses asked for, and what an
/// answer from the service is turned into. Nothing here reaches the network.
final class LyricsTests: XCTestCase {
    func testTimedLinesAreReadInOrderAndTagsAreNotLines() {
        let lrc = "[ar:Someone]\n[00:12.50] Hello there\n[00:20.00]\n[01:05.5][02:10.25]  Chorus line \nnot a lyric line\n[length: 03:00]"
        let lines = LyricsParser.parseSynced(lrc)
        XCTAssertEqual(lines.map(\.time), [12.5, 20.0, 65.5, 130.25])
        XCTAssertEqual(lines.map(\.text), ["Hello there", "", "Chorus line", "Chorus line"])
    }

    func testAFractionOfASecondIsReadWhateverItsLength() {
        for stamp in ["[00:01.5]", "[00:01.50]", "[00:01.500]"] { XCTAssertEqual(LyricsParser.parseSynced(stamp + "a")[0].time, 1.5, stamp) }
        XCTAssertEqual(LyricsParser.parseSynced("[00:01]a")[0].time, 1.0)
        XCTAssertEqual(LyricsParser.parseSynced("[75:00.00]a")[0].time, 4500)
    }

    func testTheLineBeingSungFollowsTheClockAMomentEarly() {
        let lines = LyricsParser.parseSynced("[00:12.50]a\n[00:20.00]b\n[01:05.50]c\n[02:10.25]d")
        XCTAssertNil(LyricsParser.currentIndex(in: lines, at: 0))
        XCTAssertNil(LyricsParser.currentIndex(in: lines, at: 12.0))
        XCTAssertEqual(LyricsParser.currentIndex(in: lines, at: 12.4), 0)
        XCTAssertEqual(LyricsParser.currentIndex(in: lines, at: 30), 1)
        XCTAssertEqual(LyricsParser.currentIndex(in: lines, at: 200), 3)
    }

    func testWhatAStreamingServiceAddsToATitleIsCutForTheSearch() {
        XCTAssertEqual(LyricsQuery.cleanTitle("Love Story - 2024 Remastered Version"), "Love Story")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song (feat. Someone Else)"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("Song [Live]"), "Song")
        XCTAssertEqual(LyricsQuery.cleanTitle("What We On (with Don Toliver)"), "What We On")
        XCTAssertEqual(LyricsQuery.cleanTitle("Fade (Remastered 2009)"), "Fade")
        XCTAssertEqual(LyricsQuery.cleanTitle("Title - Live at Wembley"), "Title")
        for plain in ["EdEddnEddy", "Don't Stop - Believin", "Live"] { XCTAssertEqual(LyricsQuery.cleanTitle(plain), plain) }
    }

    func testTheAddressesNameTheSongEncoded() {
        XCTAssertEqual(LyricsClient.getURL(title: "EdEddnEddy", artist: "Simon & Garfunkel", album: "The Forever Story", duration: 138.6)?.absoluteString,
                       "https://lrclib.net/api/get?track_name=EdEddnEddy&artist_name=Simon%20%26%20Garfunkel&album_name=The%20Forever%20Story&duration=139")
        XCTAssertEqual(LyricsClient.getURL(title: "A", artist: "B", album: nil, duration: nil)?.absoluteString, "https://lrclib.net/api/get?track_name=A&artist_name=B")
        XCTAssertEqual(LyricsClient.searchURL(title: "A b", artist: "C")?.absoluteString, "https://lrclib.net/api/search?track_name=A%20b&artist_name=C")
    }

    func testAnAnswerIsTurnedIntoTimedLinesAndPlainWords() {
        let timed: [String: Any] = ["duration": 139.0, "plainLyrics": "a\nb", "syncedLyrics": "[00:01.00]a\n[00:02.00]b"]
        XCTAssertEqual(LyricsClient.lyrics(from: timed)?.synced.count, 2)
        XCTAssertEqual(LyricsClient.lyrics(from: timed)?.plain, ["a", "b"])
        XCTAssertEqual(LyricsClient.lyrics(from: ["syncedLyrics": "[00:01.00]a\n[00:02.00]b"])?.plain, ["a", "b"])
        XCTAssertEqual(LyricsClient.lyrics(from: ["instrumental": true])?.instrumental, true)
        XCTAssertNil(LyricsClient.lyrics(from: ["plainLyrics": ""]))
        XCTAssertNil(LyricsClient.lyrics(from: [:]))
    }

    func testASearchAnswerIsTheOneOfAboutTheSongsLengthWithTimedLinesFirst() {
        let timed: [String: Any] = ["duration": 139.0, "plainLyrics": "a\nb", "syncedLyrics": "[00:01.00]a\n[00:02.00]b"]
        let other: [String: Any] = ["duration": 200.0, "plainLyrics": "x\ny"]
        XCTAssertEqual(LyricsClient.best(in: [other, timed], duration: 139)?.synced.count, 2)
        XCTAssertNil(LyricsClient.best(in: [other], duration: 139))
        XCTAssertEqual(LyricsClient.best(in: [other], duration: nil)?.plain, ["x", "y"])
    }

    @MainActor func testTheStoreAsksOncePerSongKeepsTheNewestAndTriesAgainAfterAFailure() async {
        let store = LyricsStore()
        var asked: [String] = []
        store.find = { query in
            asked.append(query.title)
            if query.title == "Missing" { return .notFound }
            if query.title == "Offline" { return .failed }
            return .found(Lyrics(synced: [], plain: ["words of \(query.title)"]))
        }
        @MainActor func settle() async { for _ in 0..<100 { if store.state != .loading { return }; try? await Task.sleep(nanoseconds: 20_000_000) } }
        func song(_ title: String) -> LyricsQuery { LyricsQuery(title: title, artist: "Artist", album: nil, duration: 120) }
        store.load(song("One"))
        XCTAssertEqual(store.state, .loading)
        await settle()
        XCTAssertEqual(store.state, .found(Lyrics(synced: [], plain: ["words of One"])))
        store.load(song("One"))
        XCTAssertEqual(asked, ["One"], "the song already shown is not asked for again")
        store.load(song("Two")); await settle()
        store.load(song("One"))
        XCTAssertEqual(asked, ["One", "Two"], "a song already fetched comes from memory")
        store.load(song("Missing")); await settle()
        XCTAssertEqual(store.state, .notFound)
        store.load(song("Offline")); await settle()
        XCTAssertEqual(store.state, .failed)
        store.load(song("Offline")); await settle()
        XCTAssertEqual(asked.filter { $0 == "Offline" }.count, 2, "a failure is tried again")
        store.stop()
        XCTAssertEqual(store.state, .idle)
    }
}
