import Foundation

enum NotchHubSettings {
    private static let enabledKey = "LaVoixNotchHubEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }
}
