@testable import FluidVoice_Debug
import Foundation
import XCTest

/// "Never discard the only speech source": a 76 minute Safari call recorded on 2026-11-06 had a call-audio track of digital silence and a
/// microphone labelled `unprotected`, so the transcript backend excluded every second of speech (0 words). These tests pin the rule that
/// turns the microphone into room audio in exactly that situation, and nowhere else. Sessions here are invented.
final class MeetingMicrophoneOnlyFallbackTests: XCTestCase {
    private func timebase() -> MeetingTimebaseMetadata {
        MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
    }

    private func chunk(from start: Int64, to end: Int64, sequence: Int = 0) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: "tracks/x/\(sequence).caf",
            presentationStart: MeetingMediaTime(value: start, timescale: 1),
            presentationEnd: MeetingMediaTime(value: end, timescale: 1),
            discontinuities: [],
            sha256: "abc",
            byteCount: 128,
            finalizationState: .finalized
        )
    }

    private func health(silentFor: Double?) -> MeetingTrackHealth {
        MeetingTrackHealth(
            status: .stopped, lastPresentationTime: nil, lastSampleAt: nil, level: 0, droppedSampleCount: 0, detail: nil, silentForSeconds: silentFor
        )
    }

    private func era(_ protection: MeetingMicrophoneEchoProtection) -> MeetingCaptureEra {
        MeetingCaptureEra(method: .screenCaptureKit, deviceUID: "mic", deviceName: "Mic", roleAtElection: .unknown, echoProtection: protection, startSeconds: 0)
    }

    private func session(
        mode: MeetingCaptureMode = .onlineCall,
        recordedSeconds: Int64 = 4600,
        callAudio: MeetingTrackHealth? = nil,
        microphoneEras: [MeetingCaptureEra]? = nil
    ) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: mode, title: "Invented call", microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        )
        var session = MeetingSession(configuration: configuration, startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: self.timebase())
        var tracks: [MeetingAudioTrack] = [
            MeetingAudioTrack(
                id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic", format: nil, timebase: self.timebase(),
                health: self.health(silentFor: 0), chunks: [self.chunk(from: 0, to: recordedSeconds)],
                captureMethod: .screenCaptureKit, captureEras: microphoneEras ?? [self.era(.unprotected)]
            ),
        ]
        if let applicationHealth = callAudio {
            tracks.append(MeetingAudioTrack(
                id: UUID(), kind: .applicationAudio, sourceIdentifier: "app", sourceDisplayName: "App", format: nil, timebase: self.timebase(),
                health: applicationHealth, chunks: [self.chunk(from: 0, to: recordedSeconds, sequence: 1)], captureMethod: .screenCaptureKit
            ))
        }
        session.audioTracks = tracks
        return session
    }

    func testSilentCallAudioWithUnprotectedMicrophoneProcessesTheMicrophoneAsRoomAudio() {
        let saved = self.session(callAudio: self.health(silentFor: 4583))
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.applies(to: saved))
        let effective = MeetingMicrophoneOnlyFallback.effectiveSession(for: saved)
        XCTAssertEqual(effective.session.mode, .inRoom)
        XCTAssertNotNil(effective.reason)
        XCTAssertEqual(saved.mode, .onlineCall, "the saved session must not be rewritten")
    }

    func testTheCanonicalRuleAdmitsTheMicrophoneOnceTheModeIsRoomAudio() {
        let saved = self.session(callAudio: self.health(silentFor: 4583))
        let before = MeetingCanonicalAdmission.rationale(captureMode: saved.mode, trackKind: .microphone, echoProtection: .unprotected)
        let effective = MeetingMicrophoneOnlyFallback.effectiveSession(for: saved).session
        let after = MeetingCanonicalAdmission.rationale(captureMode: effective.mode, trackKind: .microphone, echoProtection: .unprotected)
        XCTAssertEqual(before.decision, .inadmissible)
        XCTAssertEqual(after.decision, .admissible)
    }

    func testCallAudioThatHadSoundKeepsTheOnlineCallRule() {
        // Silent only for the last 100 s of 4600: the call track carried the other side, the microphone's echo rule stands.
        let saved = self.session(callAudio: self.health(silentFor: 100))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.applies(to: saved))
        XCTAssertEqual(MeetingMicrophoneOnlyFallback.effectiveSession(for: saved).session.mode, .onlineCall)
        XCTAssertNil(MeetingMicrophoneOnlyFallback.effectiveSession(for: saved).reason)
    }

    func testAProtectedMicrophoneNeedsNoFallback() {
        for protection in [MeetingMicrophoneEchoProtection.voiceProcessed, .acousticallyClosed, .softwareEchoCancelled] {
            let saved = self.session(callAudio: self.health(silentFor: 4583), microphoneEras: [self.era(protection)])
            XCTAssertFalse(MeetingMicrophoneOnlyFallback.applies(to: saved), "\(protection)")
        }
    }

    func testLegacyUnclassifiedAndMissingEraRecordsAlsoFallBack() {
        // The canonical rule refuses both, so a silent call track must not leave them with 0 words either.
        let legacy = self.session(callAudio: self.health(silentFor: 4583), microphoneEras: [self.era(.legacyUnclassified)])
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.applies(to: legacy))
        let none = self.session(callAudio: self.health(silentFor: 4583), microphoneEras: [])
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.applies(to: none))
    }

    func testAMixedSessionWithOneUnprotectedEraFallsBack() {
        let saved = self.session(
            callAudio: self.health(silentFor: 4583),
            microphoneEras: [self.era(.voiceProcessed), self.era(.unprotected)]
        )
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.applies(to: saved))
    }

    func testInRoomSessionsAreLeftAlone() {
        let saved = self.session(mode: .inRoom, callAudio: self.health(silentFor: 4583))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.applies(to: saved))
    }

    func testUnknownSilenceIsNotTreatedAsSilence() {
        let saved = self.session(callAudio: self.health(silentFor: nil))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: saved), "the fallback must never fire on a guess")
    }

    func testAMissingCallAudioTrackMeansTheMicrophoneIsAllThereIs() {
        let saved = self.session(callAudio: nil)
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: saved))
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.applies(to: saved))
    }

    func testAVeryShortSilentCallTrackSaysNothing() {
        let saved = self.session(recordedSeconds: 20, callAudio: self.health(silentFor: 20))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: saved))
    }

    func testTheSilenceShareIsNinetyPercentOfTheRecordedLength() {
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: self.session(recordedSeconds: 1000, callAudio: self.health(silentFor: 900))))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: self.session(recordedSeconds: 1000, callAudio: self.health(silentFor: 899))))
    }

    // MARK: - Why a transcript is empty

    private func event(_ kind: MeetingInterruptionKind, _ detail: String) -> MeetingSessionEvent {
        MeetingSessionEvent(id: UUID(), occurredAt: Date(), kind: kind, trackID: nil, detail: detail)
    }

    func testEmptyTranscriptReasonAfterTheFallbackSaysTheMicrophoneHeldNoSpeech() throws {
        var saved = self.session(callAudio: self.health(silentFor: 4583))
        saved.events = [self.event(.microphoneOnlyTranscript, MeetingMicrophoneOnlyFallback.eventDetail)]
        let reason = try XCTUnwrap(MeetingMicrophoneOnlyFallback.emptyTranscriptReason(for: saved))
        XCTAssertTrue(reason.contains("microphone"))
        XCTAssertTrue(reason.contains("no recognizable speech"))
    }

    func testEmptyTranscriptReasonNamesTheExclusionAndTheSilentCallTrack() throws {
        var saved = self.session(callAudio: self.health(silentFor: 4583))
        saved.events = [self.event(.transcriptCoverageIncomplete, "4582.4 seconds of microphone audio were excluded because capture admission was not verified.")]
        let reason = try XCTUnwrap(MeetingMicrophoneOnlyFallback.emptyTranscriptReason(for: saved))
        XCTAssertTrue(reason.contains("excluded because capture admission was not verified"))
        XCTAssertTrue(reason.contains("call audio track was also silent"))
    }

    func testEmptyTranscriptReasonForASilentCallTrackAlone() throws {
        let saved = self.session(callAudio: self.health(silentFor: 4583))
        let reason = try XCTUnwrap(MeetingMicrophoneOnlyFallback.emptyTranscriptReason(for: saved))
        XCTAssertTrue(reason.contains("nothing from the other side was recorded"))
    }

    func testNoReasonWhenNothingExplainsTheEmptyTranscript() {
        XCTAssertNil(MeetingMicrophoneOnlyFallback.emptyTranscriptReason(for: self.session(callAudio: self.health(silentFor: 5))))
    }
}
