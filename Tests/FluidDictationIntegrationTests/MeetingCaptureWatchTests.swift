@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingCaptureWatchTests: XCTestCase {
    func testASilentCallTrackWarnsAfterAMinuteAndNotBefore() throws {
        XCTAssertNil(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 59, microphoneUnprotectedFor: nil))
        let warning = try XCTUnwrap(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 60, microphoneUnprotectedFor: nil))
        XCTAssertEqual(warning.kind, .callAudioSilent)
        XCTAssertTrue(warning.text.contains("a minute"))
        let longer = try XCTUnwrap(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 190, microphoneUnprotectedFor: nil))
        XCTAssertTrue(longer.text.contains("3 minutes"))
    }

    func testAnUnprotectedMicrophoneWarnsAfterThirtySecondsOfSettling() throws {
        XCTAssertNil(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 0, microphoneUnprotectedFor: 29))
        let warning = try XCTUnwrap(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 0, microphoneUnprotectedFor: 30))
        XCTAssertEqual(warning.kind, .microphoneUnprotected)
    }

    func testBothProblemsAreOneCardThatSaysWhatWillHappen() throws {
        let warning = try XCTUnwrap(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 120, microphoneUnprotectedFor: 120))
        XCTAssertEqual(warning.kind, .callAudioSilentAndMicrophoneUnprotected)
        XCTAssertTrue(warning.text.contains("microphone alone"))
    }

    func testAnInRoomMeetingIsNeverJudgedOnCallAudio() {
        XCTAssertNil(MeetingCaptureWatch.evaluate(mode: .inRoom, callAudioSilentFor: 600, microphoneUnprotectedFor: 600))
    }

    func testUnknownReadingsNeverWarn() {
        XCTAssertNil(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: nil, microphoneUnprotectedFor: nil))
    }

    func testTheUnprotectedClockCountsARunAndResetsWhenProtectionReturns() {
        var clock = MeetingUnprotectedMicrophoneClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(clock.observe(.unprotected, at: t0), 0)
        XCTAssertEqual(clock.observe(.unprotected, at: t0.addingTimeInterval(45)), 45)
        XCTAssertNil(clock.observe(.softwareEchoCancelled, at: t0.addingTimeInterval(50)))
        XCTAssertEqual(clock.observe(.unprotected, at: t0.addingTimeInterval(60)), 0, "a new run starts from zero")
        XCTAssertNil(clock.observe(nil, at: t0.addingTimeInterval(70)), "an unknown reading ends the run")
    }

    func testCallEndedOffersToStopAndKeepRecording() {
        let notice = MeetingNotice.callEnded
        XCTAssertEqual(notice.stopTitle, "Stop recording")
        XCTAssertEqual(notice.dismissTitle, "Keep recording")
        XCTAssertTrue(notice.text.contains("Stop recording?"))
    }

    func testDictationBlockedByARecordingOffersToStopItButNotByATranscription() {
        let recording = MeetingNotice.dictationBlocked(meetingIsRecording: true)
        XCTAssertNotNil(recording.stopTitle)
        XCTAssertTrue(recording.text.contains("Stop the meeting recording?"))
        let transcribing = MeetingNotice.dictationBlocked(meetingIsRecording: false)
        XCTAssertNil(transcribing.stopTitle, "there is nothing to stop once the recording has ended")
    }

    func testACaptureWarningNoticeCarriesItsKindAndOnlyDismisses() {
        let warning = MeetingCaptureWarning(kind: .callAudioSilent, text: "x")
        let notice = MeetingNotice.captureWarning(warning)
        XCTAssertEqual(notice.kind, .captureWarning(.callAudioSilent))
        XCTAssertNil(notice.stopTitle)
    }
}
