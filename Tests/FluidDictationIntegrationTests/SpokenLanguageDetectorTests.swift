@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The automatic language check: a French meeting recorded with the language left on English came out as English nonsense (2026-11-10).
/// These tests cover the parts that need no model: reading a language off transcribed text, choosing which stretches of audio to listen
/// to, and what the meeting does with the answer. Every sentence and recording here is invented.
final class SpokenLanguageDetectorTests: XCTestCase {
    private let french = [
        "Bonjour tout le monde, merci d'être là, on va commencer par regarder les chiffres du dernier trimestre ensemble.",
        "Je pense que la proposition est très intéressante, mais il faudra encore discuter du calendrier avec toute l'équipe.",
        "Nous devons aussi préparer la présentation pour la semaine prochaine et envoyer les documents avant vendredi soir.",
    ]
    private let english = [
        "Hello everyone, thanks for being here, let's start by looking at the numbers from the last quarter together.",
        "I think the proposal is really interesting, but we still need to talk about the schedule with the whole team.",
        "We also have to prepare the presentation for next week and send the documents before Friday evening.",
    ]

    // MARK: Reading the language off text

    func testFrenchTextIsFrench() {
        let found = SpokenLanguageText.decide(windows: self.french)
        XCTAssertEqual(found?.languageCode, "fr")
        XCTAssertGreaterThan(found?.share ?? 0, 0.9)
    }

    func testEnglishTextIsEnglish() {
        XCTAssertEqual(SpokenLanguageText.decide(windows: self.english)?.languageCode, "en")
    }

    func testAMostlyEnglishMeetingWithAFewFrenchWordsStaysEnglish() {
        let found = SpokenLanguageText.decide(windows: self.english + self.english + [self.french[0]])
        XCTAssertEqual(found?.languageCode, "en")
    }

    func testAMixedMeetingGoesToTheMultilingualModel() {
        // Half French, half English: the English-only model would garble the French half, so the answer is not English.
        let found = SpokenLanguageText.decide(windows: self.french + self.english)
        XCTAssertEqual(found?.languageCode, "fr")
    }

    func testTooLittleTextSaysNothing() {
        XCTAssertNil(SpokenLanguageText.decide(windows: ["Bonjour tout le monde"]))
        XCTAssertNil(SpokenLanguageText.decide(windows: []))
        XCTAssertNil(SpokenLanguageText.decide(windows: ["ok", "oui", "yes", "uh huh"]))
    }

    func testALanguageTheModelDoesNotKnowIsIgnored() {
        let japanese = ["今日は会議に参加してくれてありがとうございます。まず四半期の数字を一緒に見ていきましょう。この提案はとても面白いと思います。"]
        XCTAssertNil(SpokenLanguageText.decide(windows: japanese, supported: ["en", "fr"]))
    }

    // MARK: Choosing the audio to listen to

    private func tone(seconds: Int, amplitude: Float) -> [Float] {
        (0..<(seconds * SpokenLanguageSampler.sampleRate)).map { amplitude * sin(Float($0) * 0.3) }
    }

    func testTheLoudestStretchIsChosen() {
        // 30 s of near silence, then 20 s of speech-level sound: the window must sit in the loud part.
        let samples = self.tone(seconds: 30, amplitude: 0.001) + self.tone(seconds: 20, amplitude: 0.2)
        let window = SpokenLanguageSampler.loudestWindow(of: samples)
        XCTAssertEqual(window?.count, 20 * SpokenLanguageSampler.sampleRate)
        let peak = window?.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.15)
        let firstSecond = window.map { Array($0[0..<SpokenLanguageSampler.sampleRate]) } ?? []
        XCTAssertGreaterThan(firstSecond.map { abs($0) }.max() ?? 0, 0.15, "the window starts in the loud part")
    }

    func testSilenceAndVeryShortAudioGiveNoWindow() {
        XCTAssertNil(SpokenLanguageSampler.loudestWindow(of: [Float](repeating: 0, count: 40 * SpokenLanguageSampler.sampleRate)))
        XCTAssertNil(SpokenLanguageSampler.loudestWindow(of: self.tone(seconds: 2, amplitude: 0.3)))
    }

    func testShorterAudioIsUsedWhole() {
        let samples = self.tone(seconds: 7, amplitude: 0.2)
        XCTAssertEqual(SpokenLanguageSampler.loudestWindow(of: samples)?.count, samples.count - samples.count % SpokenLanguageSampler.sampleRate)
    }

    func testEvenlySpacedPicks() {
        XCTAssertEqual(SpokenLanguageSampler.evenlySpaced(0, count: 6), [])
        XCTAssertEqual(SpokenLanguageSampler.evenlySpaced(3, count: 6), [0, 1, 2])
        let picks = SpokenLanguageSampler.evenlySpaced(50, count: 12)
        XCTAssertEqual(picks.count, 12)
        XCTAssertEqual(picks, picks.sorted())
        XCTAssertTrue(picks.allSatisfy { (0..<50).contains($0) })
        XCTAssertGreaterThan(picks.last! - picks.first!, 35, "the picks cover the whole recording, not just the start")
    }

    // MARK: What the meeting does with the answer

    private func session(language: String = "en", chosen: Bool? = nil) -> MeetingSession {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom, title: "Invented call", languageCode: language,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic")
        )
        var session = MeetingSession(configuration: configuration, startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.languageChosenByUser = chosen
        return session
    }

    private func attempt(_ language: String?) -> MeetingProcessingAttempt {
        MeetingProcessingAttempt(
            id: UUID(), startedAt: Date(), completedAt: Date(), stage: .completed, pipelineVersion: 13, asrProvider: nil, asrModel: nil,
            languageCode: language, diarizationModel: nil, lastCompletedTrackID: nil, errorCode: nil
        )
    }

    private func resolve(
        _ session: MeetingSession, enabled: Bool = true, outcome: SpokenLanguageOutcome
    ) async -> (resolution: MeetingLanguageResolution?, note: String) {
        await MeetingLanguageResolver.resolve(
            session: session, directory: URL(fileURLWithPath: "/nonexistent"), enabled: enabled,
            windows: { _, _ in [[0.1]] }, detect: { _ in outcome }
        )
    }

    func testAFrenchMeetingRecordedAsEnglishIsCorrected() async {
        let heard = SpokenLanguageDetection(languageCode: "fr", share: 0.97, wordCount: 312)
        let result = await self.resolve(self.session(language: "en"), outcome: .detected(heard))
        XCTAssertEqual(result.resolution?.languageCode, "fr")
        XCTAssertTrue(result.note.contains("fr") && result.note.contains("was set to en"))
    }

    func testTheSameLanguageChangesNothing() async {
        let heard = SpokenLanguageDetection(languageCode: "en", share: 0.99, wordCount: 300)
        let result = await self.resolve(self.session(language: "en"), outcome: .detected(heard))
        XCTAssertNil(result.resolution)
    }

    func testALanguageThePersonChoseIsNeverSecondGuessed() async {
        let heard = SpokenLanguageDetection(languageCode: "fr", share: 0.97, wordCount: 312)
        let result = await self.resolve(self.session(language: "en", chosen: true), outcome: .detected(heard))
        XCTAssertNil(result.resolution)
    }

    func testTheSwitchTurnsTheCheckOff() async {
        let heard = SpokenLanguageDetection(languageCode: "fr", share: 0.97, wordCount: 312)
        let result = await self.resolve(self.session(language: "en"), enabled: false, outcome: .detected(heard))
        XCTAssertNil(result.resolution)
    }

    func testNoAnswerKeepsTheLanguageAndSaysWhy() async {
        for outcome in [SpokenLanguageOutcome.modelMissing, .noSpeech, .undecided(words: 4), .failed("boom")] {
            let result = await self.resolve(self.session(language: "en"), outcome: outcome)
            XCTAssertNil(result.resolution, "\(outcome)")
            XCTAssertTrue(result.note.contains("keeping en"), result.note)
        }
    }

    func testChoosingALanguageSticksAndAutoHandsTheChoiceBack() {
        let base = self.session(language: "en")
        let french = MeetingSessionCoordinator.applyingLanguageChoice("fr", to: base)
        XCTAssertEqual(french.languageCode, "fr")
        XCTAssertEqual(french.languageChosenByUser, true)
        let auto = MeetingSessionCoordinator.applyingLanguageChoice("auto", to: french)
        XCTAssertEqual(auto.languageCode, "fr", "auto keeps the current language until the check decides")
        XCTAssertNil(auto.languageChosenByUser)
        XCTAssertEqual(MeetingSessionCoordinator.applyingLanguageChoice(nil, to: base), base)
    }

    func testOldSessionsWithoutTheFlagStillLoad() throws {
        let data = try JSONEncoder().encode(self.session(language: "fr"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(object?["languageChosenByUser"], "an unset flag is not written, so older builds read the file unchanged")
        XCTAssertEqual(try JSONDecoder().decode(MeetingSession.self, from: data).languageChosenByUser, nil)
    }

    func testTranscribingAgainInAnotherLanguageKeepsTheEarlierAttemptHonest() throws {
        var session = self.session(language: "fr")
        session.processingAttempts = [self.attempt("en"), self.attempt("fr")]
        XCTAssertNoThrow(try session.validateForPersistence(), "the newest attempt matches the meeting")
        session.processingAttempts = [self.attempt("fr"), self.attempt("en")]
        XCTAssertThrowsError(try session.validateForPersistence(), "a newest attempt in another language than the meeting is still refused")
    }
}
