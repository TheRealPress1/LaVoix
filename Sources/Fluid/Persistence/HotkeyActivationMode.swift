import Foundation

enum HotkeyActivationMode: String, Codable, CaseIterable, Identifiable {
    case toggle, hold, automatic, doubleTapLatch

    var id: String { self.rawValue }

    var displayName: String {
        switch self {
        case .toggle: return "Toggle"
        case .hold: return "Hold"
        case .automatic: return "Automatic (Both)"
        case .doubleTapLatch: return "Hold + Double-tap"
        }
    }

    var description: String {
        switch self {
        case .toggle: return "Tap once to start, tap again to stop."
        case .hold: return "Record only while the shortcut is held."
        case .automatic: return "Tap to toggle, hold for push-to-talk."
        case .doubleTapLatch: return "Hold to talk. Double-tap to keep recording hands-free, then tap once to stop."
        }
    }
}
