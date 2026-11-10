import AVFoundation
import Combine
import Foundation

/// Reads a translation aloud with the voice the Mac has for its language. Entirely on this Mac: nothing is sent anywhere.
@MainActor
final class FrenchSpeaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = FrenchSpeaker()

    @Published private(set) var speaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        self.synthesizer.delegate = self
    }

    /// Starts reading `text` in `language`, or stops when it is already reading.
    func toggle(_ text: String, language: CorrectionLanguage) {
        if self.speaking { self.stop(); return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: clean)
        utterance.voice = AVSpeechSynthesisVoice(language: language.voiceLanguage)
        self.speaking = true
        self.synthesizer.speak(utterance)
    }

    func stop() {
        guard self.speaking else { return }
        self.synthesizer.stopSpeaking(at: .immediate)
        self.speaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = false }
    }
}
