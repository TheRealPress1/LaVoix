import Foundation

/// The keys that drive dictation and the microphones it can listen to, read-only, so myOS can show them. Changing a shortcut needs a
/// key recorder and changing the microphone follows LaVoix's priority list, so neither is writable from here yet.
nonisolated protocol EngineShortcutsProviding: Sendable {
    /// {dictation:[text], edit, command, cancel, paste_last, mode}: each a short label such as "Fn", or empty when unset.
    func shortcuts() async -> [String: Any]
    /// {inputs:[{uid,name,preferred,default}]}
    func inputs() async -> [String: Any]
}

nonisolated struct LiveEngineShortcuts: EngineShortcutsProviding {
    func shortcuts() async -> [String: Any] {
        await MainActor.run {
            let s = SettingsStore.shared
            return [
                "dictation": s.primaryDictationShortcuts.map(\.displayString).filter { !$0.isEmpty },
                "edit": s.rewriteModeHotkeyShortcut.displayString,
                "command": s.commandModeHotkeyShortcut?.displayString ?? "",
                "cancel": s.cancelRecordingHotkeyShortcut?.displayString ?? "",
                "paste_last": s.pasteLastTranscriptionShortcutEnabled ? (s.pasteLastTranscriptionHotkeyShortcut?.displayString ?? "") : "",
            ]
        }
    }

    func inputs() async -> [String: Any] {
        await MainActor.run {
            let preferred = SettingsStore.shared.preferredInputDeviceUID
            let fallback = AudioDevice.getDefaultInputDevice()?.uid
            let list: [[String: Any]] = AudioDevice.listInputDevices().map {
                ["uid": $0.uid, "name": $0.name, "preferred": $0.uid == preferred, "default": $0.uid == fallback]
            }
            return ["inputs": list]
        }
    }
}
