import AVFoundation
#if arch(arm64)
import FluidAudio
#endif
import Foundation
import NaturalLanguage

/// Which language the people in a recording are speaking.
///
/// The English speech model (Parakeet v2) turns any other language into English-looking nonsense, so a French meeting recorded with the
/// language left on English came out as gibberish. The multilingual model (Parakeet v3) writes what it hears in the language it hears, so
/// the check listens to a few short stretches of the recording with it, then reads the language off the words it wrote. Nothing is sent
/// anywhere: the model, the audio and the text all stay on this Mac, and the text of the check is thrown away (only the language, its
/// share of the words and the word count are kept and logged).

nonisolated struct SpokenLanguageDetection: Equatable, Sendable {
    /// An ISO code the multilingual model supports ("fr", "en", ...).
    let languageCode: String
    /// The share of the checked words that are in this language, 0 to 1.
    let share: Double
    let wordCount: Int
}

/// The pure part of the check: which language a handful of transcribed stretches add up to.
nonisolated enum SpokenLanguageText {
    /// Fewer words than this in all and there is not enough to say anything.
    static let minimumTotalWords = 25
    /// A stretch with fewer words than this is not read (one or two words say nothing about a language).
    static let minimumWindowWords = 8
    /// A stretch whose best language guess is weaker than this is not counted.
    static let minimumWindowConfidence = 0.6
    /// English stays English when at least this share of the words are English. Below it the meeting is mixed or not English, and the
    /// multilingual model (which also handles the English parts) is the right one.
    static let englishShare = 0.8

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && $0 != "'" && $0 != "\u{2019}" }.count
    }

    /// The best single language for one stretch of text, or nil when it is too short or too unsure.
    static func language(of text: String, supported: Set<String>) -> String? {
        guard self.wordCount(text) >= self.minimumWindowWords else { return nil }
        // No constraint to the supported set: with one, a language the model cannot read (Japanese, say) would be squeezed into the
        // closest supported one with a high score. The best guess over every language must itself be supported.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
              best.value >= self.minimumWindowConfidence,
              supported.contains(best.key.rawValue)
        else { return nil }
        return best.key.rawValue
    }

    /// The language the stretches add up to: English when English carries at least `englishShare` of the words, otherwise the most
    /// spoken other language. Nil when there are too few words to tell.
    static func decide(
        windows: [String],
        supported: Set<String> = VoiceEngineLanguageCatalog.parakeetV3LanguageIDs
    ) -> SpokenLanguageDetection? {
        var words: [String: Int] = [:]
        var total = 0
        for text in windows {
            guard let code = self.language(of: text, supported: supported) else { continue }
            let n = self.wordCount(text)
            words[code, default: 0] += n
            total += n
        }
        guard total >= self.minimumTotalWords else { return nil }
        let english = words["en", default: 0]
        if Double(english) / Double(total) >= self.englishShare {
            return SpokenLanguageDetection(languageCode: "en", share: Double(english) / Double(total), wordCount: total)
        }
        guard let other = words.filter({ $0.key != "en" }).max(by: { $0.value < $1.value }) else { return nil }
        return SpokenLanguageDetection(languageCode: other.key, share: Double(other.value) / Double(total), wordCount: total)
    }
}

/// Picks the stretches of audio to listen to.
nonisolated enum SpokenLanguageSampler {
    static let sampleRate = 16_000
    /// How long each listened-to stretch is, and how many to listen to at most.
    static let windowSeconds = 20
    static let maximumWindows = 6

    /// `count` indices spread evenly over `0..<n` (all of them when `count >= n`).
    static func evenlySpaced(_ n: Int, count: Int) -> [Int] {
        guard n > 0, count > 0 else { return [] }
        if count >= n { return Array(0..<n) }
        return (0..<count).map { ($0 * n + n / 2) / count }.reduce(into: [Int]()) { if $1 < n, !$0.contains($1) { $0.append($1) } }
    }

    /// The loudest `seconds`-long stretch of 16 kHz `samples` (found in one-second steps), or nil when even the loudest is close to
    /// silence. Shorter audio is returned whole when it is at least three seconds long and not silent.
    static func loudestWindow(of samples: [Float], seconds: Int = SpokenLanguageSampler.windowSeconds, minimumRMS: Float = 0.004) -> [Float]? {
        let rate = self.sampleRate
        guard samples.count >= rate * 3 else { return nil }
        let blocks = samples.count / rate
        var energy = [Double](repeating: 0, count: blocks)
        for block in 0..<blocks {
            var sum = 0.0
            for i in (block * rate)..<((block + 1) * rate) { sum += Double(samples[i]) * Double(samples[i]) }
            energy[block] = sum
        }
        let span = min(seconds, blocks)
        var running = energy[0..<span].reduce(0, +)
        var best = running
        var bestStart = 0
        if blocks > span {
            for start in 1...(blocks - span) {
                running += energy[start + span - 1] - energy[start - 1]
                if running > best { best = running; bestStart = start }
            }
        }
        let rms = Float((best / Double(span * rate)).squareRoot())
        guard rms >= minimumRMS else { return nil }
        return Array(samples[(bestStart * rate)..<((bestStart + span) * rate)])
    }

    /// The finished audio chunk files of a session, oldest first, as `(file, sequence)`.
    static func chunkFiles(of session: MeetingSession, in directory: URL) -> [URL] {
        var found: [(sequence: Int, url: URL)] = []
        for track in session.audioTracks {
            for chunk in track.chunks where chunk.finalizationState != .failed {
                let relative = chunk.captureAnalysisAsset?.relativeFilePath ?? chunk.relativeFilePath
                let url = directory.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) { found.append((chunk.sequence, url)) }
            }
        }
        return found.sorted { $0.sequence < $1.sequence }.map(\.url)
    }

    /// Reads one audio file as 16 kHz mono samples (a chunk is about a minute, so it is read whole).
    static func samples(of url: URL, maximumSeconds: Double = 150) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate > 0 else { return [] }
        let frames = AVAudioFrameCount(min(Double(file.length), maximumSeconds * format.sampleRate))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        try file.read(into: buffer, frameCount: frames)
        return try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: Double(self.sampleRate))
    }

    /// Up to `maximumWindows` loud stretches spread over a finished meeting's audio (all tracks), 16 kHz mono. Reads at most twice
    /// that many chunk files; a quiet chunk contributes nothing.
    static func windows(of session: MeetingSession, in directory: URL) -> [[Float]] {
        let files = self.chunkFiles(of: session, in: directory)
        var windows: [[Float]] = []
        for index in self.evenlySpaced(files.count, count: self.maximumWindows * 2) {
            guard windows.count < self.maximumWindows else { break }
            guard let all = try? self.samples(of: files[index]), let window = self.loudestWindow(of: all) else { continue }
            windows.append(window)
        }
        return windows
    }

    /// The same for a plain audio file (a transcription of a file): stretches spread over its whole length.
    static func windows(ofAudioFile url: URL) -> [[Float]] {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return [] }
        let rate = file.processingFormat.sampleRate
        let total = Double(file.length) / rate
        let slice = 60.0
        let slices = max(1, Int((total / slice).rounded(.up)))
        var windows: [[Float]] = []
        for index in self.evenlySpaced(slices, count: self.maximumWindows * 2) {
            guard windows.count < self.maximumWindows else { break }
            let start = AVAudioFramePosition(Double(index) * slice * rate)
            let frames = AVAudioFrameCount(min(slice * rate, Double(file.length - start)))
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { continue }
            file.framePosition = start
            guard (try? file.read(into: buffer, frameCount: frames)) != nil,
                  let all = try? AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: Double(self.sampleRate)),
                  let window = self.loudestWindow(of: all) else { continue }
            windows.append(window)
        }
        return windows
    }
}

/// How the check ended.
nonisolated enum SpokenLanguageOutcome: Equatable, Sendable {
    case detected(SpokenLanguageDetection)
    /// Heard something, but too little or too mixed to say.
    case undecided(words: Int)
    /// There was no usable speech to listen to.
    case noSpeech
    /// The multilingual model is not installed on this Mac, so the language cannot be checked.
    case modelMissing
    case failed(String)
}

nonisolated enum SpokenLanguageDetector {
    /// `defaults write com.myos.engine MeetingLanguageAutoDetect -bool false` turns the automatic check off (the chosen language is then used as it is).
    static let defaultsKey = "MeetingLanguageAutoDetect"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: self.defaultsKey) as? Bool ?? true }

    #if arch(arm64)
    /// Listens to `windows` (16 kHz mono) with the multilingual model and decides the language. The model must already be installed:
    /// this never downloads anything.
    @MainActor static func detect(windows: [[Float]]) async -> SpokenLanguageOutcome {
        guard !windows.isEmpty else { return .noSpeech }
        guard ParakeetSpeechModelCatalog.v3.isInstalledOnThisMac else { return .modelMissing }
        let provider = FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false)
        do {
            try await provider.prepare(progressHandler: nil)
            var texts: [String] = []
            for window in windows {
                try Task.checkCancellation()
                texts.append(try await provider.transcribe(window).text)
            }
            if let detection = SpokenLanguageText.decide(windows: texts) { return .detected(detection) }
            return .undecided(words: texts.reduce(0) { $0 + SpokenLanguageText.wordCount($1) })
        } catch {
            return .failed(error.localizedDescription)
        }
    }
    #else
    @MainActor static func detect(windows: [[Float]]) async -> SpokenLanguageOutcome { .modelMissing }
    #endif
}

extension ParakeetSpeechModelCatalog.Descriptor {
    /// True when this model's files are all in the engine's model folder (a filesystem check; nothing is downloaded).
    nonisolated var isInstalledOnThisMac: Bool {
        #if arch(arm64)
        let root = AsrModels.defaultCacheDirectory().deletingLastPathComponent()
        return self.artifactsAreComplete(at: self.cacheDirectory(in: root))
        #else
        return false
        #endif
    }
}

/// A language the check found for a meeting that differs from the one it was recorded with.
nonisolated struct MeetingLanguageResolution: Equatable, Sendable {
    let languageCode: String
    let detection: SpokenLanguageDetection
}

/// Checks a finished meeting's language before it is transcribed. A language the person chose for that meeting (the "Transcribe again
/// in..." menu) is never second-guessed; otherwise what is spoken wins over what the setup said, because a wrong setup is exactly how a
/// French meeting came out as English nonsense.
nonisolated enum MeetingLanguageResolver {
    /// `resolution` is nil when the meeting's language should stay as it is; `note` says why or what was found (a log line, never any of the words).
    static func resolve(
        session: MeetingSession,
        directory: URL,
        enabled: Bool = SpokenLanguageDetector.isEnabled,
        windows: ((MeetingSession, URL) async -> [[Float]])? = nil,
        detect: (([[Float]]) async -> SpokenLanguageOutcome)? = nil
    ) async -> (resolution: MeetingLanguageResolution?, note: String) {
        guard enabled else { return (nil, "language check is off") }
        guard session.languageChosenByUser != true else { return (nil, "language \(session.languageCode) was chosen for this meeting") }
        let heard: [[Float]]
        if let windows {
            heard = await windows(session, directory)
        } else {
            heard = await Task.detached(priority: .userInitiated) { SpokenLanguageSampler.windows(of: session, in: directory) }.value
        }
        let outcome: SpokenLanguageOutcome
        if let detect { outcome = await detect(heard) } else { outcome = await SpokenLanguageDetector.detect(windows: heard) }
        switch outcome {
        case let .detected(detection):
            let share = String(format: "%.2f", detection.share)
            if detection.languageCode == session.languageCode {
                return (nil, "heard \(detection.languageCode) (share \(share), \(detection.wordCount) words), as set")
            }
            return (
                MeetingLanguageResolution(languageCode: detection.languageCode, detection: detection),
                "heard \(detection.languageCode) (share \(share), \(detection.wordCount) words), was set to \(session.languageCode)"
            )
        case let .undecided(words): return (nil, "could not tell from \(words) words; keeping \(session.languageCode)")
        case .noSpeech: return (nil, "no speech to listen to; keeping \(session.languageCode)")
        case .modelMissing: return (nil, "the multilingual model is not installed, so the language was not checked; keeping \(session.languageCode)")
        case let .failed(why): return (nil, "the check failed (\(why)); keeping \(session.languageCode)")
        }
    }
}
