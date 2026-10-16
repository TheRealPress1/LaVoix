import Foundation

/// The settings bridge: myOS shows and changes LaVoix's settings over the engine socket, through a fixed list. A setting is
/// only reachable if it is listed here, with its type and limits, so myOS can never write an arbitrary key (an API key, a
/// private-message switch, a path) and a wrong value is refused rather than stored. Plain dictionaries so the socket sends them
/// as JSON.
nonisolated protocol EngineSettingsProviding: Sendable {
    func list() async -> [[String: Any]]
    /// Returns the setting as it now is, or throws `EngineSettingsError`.
    func set(key: String, value: Any) async throws -> [String: Any]
}

nonisolated enum EngineSettingsError: LocalizedError, Equatable {
    case unknownKey, wrongType(String), outOfRange(String), unknownChoice
    var errorDescription: String? {
        switch self {
        case .unknownKey: "That setting does not exist."
        case let .wrongType(t): "That setting needs \(t)."
        case let .outOfRange(r): "That value is outside \(r)."
        case .unknownChoice: "That is not one of the choices."
        }
    }
}

nonisolated enum SettingKind: Sendable {
    case bool
    case int(min: Int, max: Int)
    case double(min: Double, max: Double, step: Double)
    case text
    case choice([(id: String, label: String)])

    var name: String {
        switch self {
        case .bool: "bool"
        case .int: "int"
        case .double: "double"
        case .text: "text"
        case .choice: "choice"
        }
    }

    /// The value as it will be stored, or why it is refused.
    func coerce(_ raw: Any) throws -> Any {
        switch self {
        case .bool:
            guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw EngineSettingsError.wrongType("true or false") }
            return n.boolValue
        case let .int(lo, hi):
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue == n.doubleValue.rounded() else { throw EngineSettingsError.wrongType("a whole number") }
            guard n.intValue >= lo, n.intValue <= hi else { throw EngineSettingsError.outOfRange("\(lo) to \(hi)") }
            return n.intValue
        case let .double(lo, hi, _):
            guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { throw EngineSettingsError.wrongType("a number") }
            guard n.doubleValue >= lo, n.doubleValue <= hi else { throw EngineSettingsError.outOfRange("\(lo) to \(hi)") }
            return n.doubleValue
        case .text:
            guard let s = raw as? String else { throw EngineSettingsError.wrongType("text") }
            guard s.count <= 2000 else { throw EngineSettingsError.outOfRange("2000 characters") }
            return s
        case let .choice(options):
            guard let s = raw as? String else { throw EngineSettingsError.wrongType("one of the choices") }
            guard options.contains(where: { $0.id == s }) else { throw EngineSettingsError.unknownChoice }
            return s
        }
    }
}

/// One exposed setting. `read`/`write` run on the main actor, where the settings store lives.
nonisolated struct SettingSpec: @unchecked Sendable {
    let key: String
    let group: String
    let title: String
    let detail: String
    let kind: SettingKind
    let read: @MainActor () -> Any
    let write: @MainActor (Any) -> Void

    @MainActor func describe() -> [String: Any] {
        var out: [String: Any] = ["key": self.key, "group": self.group, "title": self.title, "detail": self.detail, "kind": self.kind.name, "value": self.read()]
        switch self.kind {
        case let .int(lo, hi): out["min"] = lo; out["max"] = hi
        case let .double(lo, hi, step): out["min"] = lo; out["max"] = hi; out["step"] = step
        case let .choice(options): out["options"] = options.map { ["id": $0.id, "label": $0.label] }
        case .bool, .text: break
        }
        return out
    }
}

/// The list. Add a line here to expose a setting; nothing else is reachable.
@MainActor
enum SettingsRegistry {
    private static var s: SettingsStore { SettingsStore.shared }

    private static func bool(_ key: String, _ group: String, _ title: String, _ detail: String, _ path: ReferenceWritableKeyPath<SettingsStore, Bool>) -> SettingSpec {
        SettingSpec(key: key, group: group, title: title, detail: detail, kind: .bool, read: { s[keyPath: path] }, write: { s[keyPath: path] = ($0 as? Bool) ?? s[keyPath: path] })
    }

    private static func int(_ key: String, _ group: String, _ title: String, _ detail: String, min: Int, max: Int, _ path: ReferenceWritableKeyPath<SettingsStore, Int>) -> SettingSpec {
        SettingSpec(key: key, group: group, title: title, detail: detail, kind: .int(min: min, max: max), read: { s[keyPath: path] }, write: { s[keyPath: path] = ($0 as? Int) ?? s[keyPath: path] })
    }

    private static func text(_ key: String, _ group: String, _ title: String, _ detail: String, _ path: ReferenceWritableKeyPath<SettingsStore, String>) -> SettingSpec {
        SettingSpec(key: key, group: group, title: title, detail: detail, kind: .text, read: { s[keyPath: path] }, write: { s[keyPath: path] = ($0 as? String) ?? s[keyPath: path] })
    }

    private static func choice<E: RawRepresentable>(_ key: String, _ group: String, _ title: String, _ detail: String, _ options: [(E, String)], _ path: ReferenceWritableKeyPath<SettingsStore, E>) -> SettingSpec where E.RawValue == String {
        SettingSpec(
            key: key, group: group, title: title, detail: detail, kind: .choice(options.map { ($0.0.rawValue, $0.1) }),
            read: { s[keyPath: path].rawValue },
            write: { if let raw = $0 as? String, let value = E(rawValue: raw) { s[keyPath: path] = value } }
        )
    }

    static var all: [SettingSpec] {
        [
            // Dictation
            bool("dictation.copy_to_clipboard", "Dictation", "Copy to clipboard", "Also copy each dictation to the clipboard.", \.copyTranscriptionToClipboard),
            bool("dictation.return_to_field", "Dictation", "Return to the starting field", "Type into the field you started in, even if you switched apps while talking.", \.returnDictationToStartingField),
            bool("dictation.streaming_preview", "Dictation", "Live preview", "Show words in the overlay while you speak.", \.enableStreamingPreview),
            bool("dictation.skip_silent", "Dictation", "Skip silent recordings", "Do nothing when no speech was heard.", \.skipSilentRecordingsEnabled),
            choice("dictation.shortcut_mode", "Dictation", "Shortcut behaviour", "How the dictation shortcut starts and stops recording.", [
                (HotkeyActivationMode.toggle, "Press to start, press to stop"), (.hold, "Hold to talk"),
                (.automatic, "Automatic (both)"), (.doubleTapLatch, "Hold, or double-tap to latch"),
            ], \.hotkeyMode),
            bool("dictation.sounds", "Dictation", "Sounds", "Play a sound when dictation starts and stops.", \.enableTranscriptionSounds),
            // Cleanup
            bool("cleanup.ai", "Cleanup", "Clean up with AI", "Tidy each dictation with the on-device model (or your chosen provider) before typing it.", \.enableAIProcessing),
            bool("cleanup.filler_words", "Cleanup", "Remove filler words", "Drop \"um\", \"uh\" and the like.", \.removeFillerWordsEnabled),
            bool("cleanup.punctuation", "Cleanup", "Spoken punctuation", "Turn \"comma\" and \"new line\" into the symbol.", \.autoConvertPunctuationEnabled),
            bool("cleanup.literal", "Cleanup", "Literal formatting", "Keep what you said exactly, without rewriting numbers and symbols.", \.literalDictationFormattingEnabled),
            // History
            bool("history.save", "History", "Keep a history", "Save each dictation so you can find it later.", \.saveTranscriptionHistory),
            bool("history.save_audio", "History", "Keep the audio too", "Save the recording next to each history entry.", \.saveAudioWithTranscriptionHistory),
            bool("history.metrics", "History", "Show timing details", "Show how long recognition and cleanup took.", \.showHistoryPerformanceMetrics),
            int("stats.typing_wpm", "History", "Your typing speed", "Words per minute, used to estimate the time dictation saves you.", min: 10, max: 250, \.userTypingWPM),
            // Meetings
            bool("meetings.auto_detect", "Meetings", "Offer to record meetings", "Show the record card when a call starts.", \.meetingAutoDetectEnabled),
            bool("meetings.auto_detect_browser", "Meetings", "Detect calls in the browser", "Also notice Google Meet and similar in browser tabs.", \.meetingAutoDetectBrowserEnabled),
            bool("meetings.auto_notes", "Meetings", "Write notes automatically", "Write the summary when a meeting ends.", \.meetingAutoNotesEnabled),
            text("meetings.notes_command", "Meetings", "Notes command", "Optional command that writes the notes instead of the on-device model, for example claude -p.", \.meetingNotesCommand),
            choice("meetings.audio_retention", "Meetings", "Keep meeting audio", "How long recordings are kept after the transcript is made.", [
                (MeetingAudioRetentionPolicy.afterTranscription, "Delete after transcription"), (.days7, "7 days"), (.days30, "30 days"), (.never, "Forever"),
            ], \.meetingAudioRetentionPolicy),
            // Look
            choice("appearance.theme", "Look", "Theme", "Light, dark or follow the system.", [
                (SettingsStore.ThemePreference.system, "System"), (.light, "Light"), (.dark, "Dark"),
            ], \.themePreference),
            choice("notch.presentation", "Notch & overlay", "Notch style", "How the notch shows dictation.", [
                (SettingsStore.NotchPresentationMode.standard, "Standard"), (.minimal, "Minimal"),
            ], \.notchPresentationMode),
            choice("overlay.position", "Notch & overlay", "Overlay position", "Where the dictation overlay appears.", [
                (SettingsStore.OverlayPosition.top, "Top of screen"), (.bottom, "Bottom of screen"),
            ], \.overlayPosition),
            choice("overlay.size", "Notch & overlay", "Overlay size", "", [
                (SettingsStore.OverlaySize.pill, "Pill"), (.small, "Small"), (.medium, "Medium"), (.large, "Large"),
            ], \.overlaySize),
            choice("meetings.overlay", "Notch & overlay", "While recording a meeting", "Show a small pill or live captions.", [
                (MeetingOverlayPreference.pill, "Pill"), (.captions, "Live captions"),
            ], \.meetingOverlayPreference),
            // Startup
            bool("startup.launch_at_login", "Startup", "Open at login", "Start when you log in to your Mac.", \.launchAtStartup),
            bool("startup.show_in_dock", "Startup", "Show in the Dock", "", \.showInDock),
        ]
    }
}

nonisolated struct LiveEngineSettings: EngineSettingsProviding {
    func list() async -> [[String: Any]] {
        await MainActor.run { SettingsRegistry.all.map { $0.describe() } }
    }

    func set(key: String, value: Any) async throws -> [String: Any] {
        try await MainActor.run {
            guard let spec = SettingsRegistry.all.first(where: { $0.key == key }) else { throw EngineSettingsError.unknownKey }
            let clean = try spec.kind.coerce(value)
            spec.write(clean)
            return spec.describe()
        }
    }
}
