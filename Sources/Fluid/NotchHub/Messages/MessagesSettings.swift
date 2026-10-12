import Foundation

enum NotchMessagesSettings {
    private static let enabledKey = "LaVoixNotchMessagesEnabled"
    private static let previewsKey = "LaVoixNotchMessagesShowPreviews"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    /// When off, the notch says who messaged but not what they said.
    static var showsPreviews: Bool {
        get { UserDefaults.standard.object(forKey: self.previewsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.previewsKey) }
    }
}
