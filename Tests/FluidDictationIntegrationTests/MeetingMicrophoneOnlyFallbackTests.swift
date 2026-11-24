@testable import FluidVoice_Debug
import AVFoundation
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

    func testACallTrackWithNoAudioAtAllIsSilentOnceTheMicrophoneHasRecordedLongEnough() {
        var saved = self.session(recordedSeconds: 600, callAudio: self.health(silentFor: nil))
        saved.audioTracks = saved.audioTracks.map { track in
            var track = track
            if track.kind == .applicationAudio { track.chunks = [] }
            return track
        }
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: saved), "a tap writes no chunks while nothing plays")
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.applies(to: saved))
        var short = self.session(recordedSeconds: 20, callAudio: self.health(silentFor: nil))
        short.audioTracks = short.audioTracks.map { track in
            var track = track
            if track.kind == .applicationAudio { track.chunks = [] }
            return track
        }
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: short), "a recording that only just began says nothing")
    }

    func testAVeryShortSilentCallTrackSaysNothing() {
        let saved = self.session(recordedSeconds: 20, callAudio: self.health(silentFor: 20))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: saved))
    }

    func testTheSilenceShareIsNinetyPercentOfTheRecordedLength() {
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: self.session(recordedSeconds: 1000, callAudio: self.health(silentFor: 900))))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.callAudioWasSilent(in: self.session(recordedSeconds: 1000, callAudio: self.health(silentFor: 899))))
    }

    // MARK: - Measured from the audio (a call track that is mostly empty without being silent at the end)

    /// Writes one 48 kHz stereo float CAF whose seconds are a tone at the given amplitude (0 = digital silence).
    private func writeCaf(_ url: URL, amplitudes: [Float]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        for amplitude in amplitudes {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            for channel in 0..<2 {
                let data = try XCTUnwrap(buffer.floatChannelData)[channel]
                for frame in 0..<48000 { data[frame] = amplitude * sinf(Float(frame) * 0.05) }
            }
            try file.write(from: buffer)
        }
    }

    /// A temporary session folder whose call-audio chunk holds `seconds` seconds shaped by `amplitude(second)`.
    private func folder(seconds: Int, amplitude: (Int) -> Float) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fallback-\(UUID().uuidString)")
        try self.writeCaf(directory.appendingPathComponent("tracks/x/1.caf"), amplitudes: (0..<seconds).map(amplitude))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testTheSoundShareCountsSecondsAtSpeechLevelNotFaintClicks() throws {
        // 100 s: 30 s of a -20 dBFS tone, 20 s of a -60 dBFS hiss (below the line), 50 s of digital silence.
        let directory = try self.folder(seconds: 100) { $0 < 30 ? 0.1 : ($0 < 50 ? 0.001 : 0) }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5))
        let track = try XCTUnwrap(saved.audioTracks.first { $0.kind == .applicationAudio })
        let share = try XCTUnwrap(MeetingMicrophoneOnlyFallback.soundShare(of: track, in: directory))
        XCTAssertEqual(share, 0.30, accuracy: 0.011)
    }

    func testAMostlyEmptyCallTrackMakesTheMicrophoneRoomAudioEvenWhenItDoesNotEndInSilence() throws {
        // The 2026-11-23 case: the call track carried sound for about a tenth of its seconds and its last run of silence was only a few seconds.
        let directory = try self.folder(seconds: 100) { $0 % 10 == 0 ? 0.1 : 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5))
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.applies(to: saved), "the older last-run rule does not catch it")
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(effective.session.mode, .inRoom)
        XCTAssertEqual(effective.reason, MeetingMicrophoneOnlyFallback.mostlyAbsentEventDetail)
        XCTAssertEqual(saved.mode, .onlineCall, "the saved session must not be rewritten")
        XCTAssertEqual(MeetingCanonicalAdmission.rationale(captureMode: effective.session.mode, trackKind: .microphone, echoProtection: .unprotected).decision, .admissible)
    }

    func testACallThatCarriedItsOtherSideKeepsTheOnlineRule() throws {
        // Sound in half the seconds, as in a normal conversation.
        let directory = try self.folder(seconds: 100) { $0 % 2 == 0 ? 0.1 : 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5))
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(effective.session.mode, .onlineCall)
        XCTAssertNil(effective.reason)
    }

    func testAnUnreadableCallTrackIsNotAbsence() throws {
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5))
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: nowhere)
        XCTAssertEqual(effective.session.mode, .onlineCall, "the fallback never fires on a guess")
        XCTAssertNil(effective.reason)
    }

    func testAProtectedMicrophoneNeverTriggersTheMeasuredFallback() throws {
        let directory = try self.folder(seconds: 100) { _ in 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5), microphoneEras: [self.era(.softwareEchoCancelled)])
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(effective.session.mode, .onlineCall)
        XCTAssertNil(effective.reason)
    }

    func testAVeryShortRecordingIsNotJudgedByTheMeasuredRule() throws {
        let directory = try self.folder(seconds: 20) { _ in 0 }
        let saved = self.session(recordedSeconds: 20, callAudio: self.health(silentFor: 5))
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(effective.session.mode, .onlineCall)
    }

    // MARK: - A raw microphone beside a call that DID carry the other side (2026-11-24: a 36 minute call whose transcript held only the other person)

    private func microphoneProtections(of session: MeetingSession) throws -> [MeetingMicrophoneEchoProtection] {
        try XCTUnwrap(session.audioTracks.first { $0.kind == .microphone }?.captureEras).map(\.echoProtection)
    }

    func testAnUnprotectedMicrophoneBesideACallThatCarriedSoundIsKeptAndItsTextIsChecked() throws {
        let directory = try self.folder(seconds: 100) { $0 % 2 == 0 ? 0.1 : 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5))
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(effective.session.mode, .onlineCall, "it stays an online call, so the call's text is what the microphone is checked against")
        XCTAssertNil(effective.reason)
        XCTAssertEqual(try self.microphoneProtections(of: effective.session), [.textEchoChecked])
        XCTAssertEqual(MeetingCanonicalAdmission.rationale(captureMode: .onlineCall, trackKind: .microphone, echoProtection: .textEchoChecked).decision, .admissible)
        XCTAssertEqual(try self.microphoneProtections(of: saved), [.unprotected], "the saved session must not be rewritten")
        XCTAssertTrue(MeetingMicrophoneOnlyFallback.keptUnprotectedMicrophone(saved: saved, effective: effective.session))
    }

    func testOnlyTheUnprotectedErasOfAMixedMicrophoneAreKept() throws {
        let directory = try self.folder(seconds: 100) { $0 % 2 == 0 ? 0.1 : 0 }
        let saved = self.session(
            recordedSeconds: 100, callAudio: self.health(silentFor: 5),
            microphoneEras: [self.era(.voiceProcessed), self.era(.unprotected), self.era(.softwareEchoCancelled)]
        )
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(try self.microphoneProtections(of: effective.session), [.voiceProcessed, .textEchoChecked, .softwareEchoCancelled])
    }

    func testAProtectedMicrophoneIsNotTouched() throws {
        let directory = try self.folder(seconds: 100) { $0 % 2 == 0 ? 0.1 : 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5), microphoneEras: [self.era(.softwareEchoCancelled)])
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(try self.microphoneProtections(of: effective.session), [.softwareEchoCancelled])
        XCTAssertFalse(MeetingMicrophoneOnlyFallback.keptUnprotectedMicrophone(saved: saved, effective: effective.session))
    }

    func testAnUnclassifiedLegacyMicrophoneStaysRefusedBesideACallThatCarriedSound() throws {
        let directory = try self.folder(seconds: 100) { $0 % 2 == 0 ? 0.1 : 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5), microphoneEras: [self.era(.legacyUnclassified)])
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(try self.microphoneProtections(of: effective.session), [.legacyUnclassified])
        XCTAssertEqual(MeetingCanonicalAdmission.rationale(captureMode: .onlineCall, trackKind: .microphone, echoProtection: .legacyUnclassified).decision, .inadmissible)
    }

    func testAMostlyEmptyCallTrackStillGoesToRoomAudioNotToTheTextCheck() throws {
        let directory = try self.folder(seconds: 100) { $0 % 10 == 0 ? 0.1 : 0 }
        let saved = self.session(recordedSeconds: 100, callAudio: self.health(silentFor: 5))
        let effective = MeetingMicrophoneOnlyFallback.effectiveSessionMeasuring(for: saved, directory: directory)
        XCTAssertEqual(effective.session.mode, .inRoom)
        XCTAssertEqual(try self.microphoneProtections(of: effective.session), [.unprotected], "room audio needs no text check")
    }

    func testTheTextCheckedStateAdmitsATranscriptAndUnprotectedStillDoesNot() {
        XCTAssertTrue(MeetingMicrophoneEchoProtection.textEchoChecked.admitsTranscript)
        XCTAssertFalse(MeetingMicrophoneEchoProtection.unprotected.admitsTranscript)
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
