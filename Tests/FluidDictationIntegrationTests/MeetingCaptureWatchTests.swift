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

    func testAnUnprotectedMicrophoneNoLongerWarns() {
        // Removed 2026-11-24: a raw microphone is kept and its text is checked against the call audio's, so there is nothing for the person to do.
        for seconds in [0.0, 29, 30, 600] {
            XCTAssertNil(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 0, microphoneUnprotectedFor: seconds), "\(seconds)")
        }
    }

    func testASilentCallTrackWithAnUnprotectedMicrophoneIsJustTheSilentCallCard() throws {
        let warning = try XCTUnwrap(MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 120, microphoneUnprotectedFor: 120))
        XCTAssertEqual(warning.kind, .callAudioSilent)
        XCTAssertTrue(warning.text.contains("2 minutes"))
        XCTAssertFalse(warning.text.contains("echo"), "no word about echo protection")
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

    func testATapThatDeliversNothingIsSilenceFromTheStartOfTheRecording() {
        let start = Date(timeIntervalSince1970: 1000)
        // No sample ever: the silence is the time since the recording began.
        XCTAssertEqual(MeetingCaptureWatch.callAudioSilence(silentForSeconds: nil, lastSampleAt: nil, recordingStartedAt: start, now: start.addingTimeInterval(75)), 75)
        // Buffers of zeros (ScreenCaptureKit): its own count is larger than the time since the last sample.
        XCTAssertEqual(MeetingCaptureWatch.callAudioSilence(silentForSeconds: 600, lastSampleAt: start.addingTimeInterval(999), recordingStartedAt: start, now: start.addingTimeInterval(1000)), 600)
        // Sound just heard: no silence.
        XCTAssertEqual(MeetingCaptureWatch.callAudioSilence(silentForSeconds: 0, lastSampleAt: start.addingTimeInterval(70), recordingStartedAt: start, now: start.addingTimeInterval(71)), 1)
        // A clock that ran backwards never gives a negative silence.
        XCTAssertEqual(MeetingCaptureWatch.callAudioSilence(silentForSeconds: nil, lastSampleAt: start.addingTimeInterval(50), recordingStartedAt: start, now: start), 0)
        let warning = MeetingCaptureWatch.evaluate(mode: .onlineCall, callAudioSilentFor: 75, microphoneUnprotectedFor: nil)
        XCTAssertEqual(warning?.kind, .callAudioSilent)
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
