import Foundation

enum NotchMessagesSettings {
    private static let enabledKey = "LaVoixNotchMessagesEnabled"
    private static let previewsKey = "LaVoixNotchMessagesShowPreviews"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    private static let seenKey = "LaVoixNotchMessagesMarkSeenOnReply"

    /// When on, replying in the notch also shows that conversation in Messages for a moment, so Messages counts it as seen (the unread badge
    /// clears and the other person gets a read receipt). On by default.
    static var marksSeenOnReply: Bool {
        get { UserDefaults.standard.object(forKey: self.seenKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.seenKey) }
    }

    /// When off, the notch says who messaged but not what they said.
    static var showsPreviews: Bool {
        get { UserDefaults.standard.object(forKey: self.previewsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.previewsKey) }
    }
}
