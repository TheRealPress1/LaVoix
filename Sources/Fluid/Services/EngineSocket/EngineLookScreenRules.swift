import CoreGraphics
import Foundation

// A whole-screen Look (Fn+Control with no circle, docs/23 in the myOS repo) takes a picture of the display with the PRIVATE windows cut out of it, so neither the
// picture nor the words read from it can hold them. This file is the rules for that and nothing else: which windows are left out, and which of two reads
// a Look should use once the circle (or no circle) is known. No screen, no Accessibility and no clock here, so every rule can be checked on its own.
//
// Who owns the lists: myOS (cloud_model.rs) is the single source; it pushes them with `look.rules` when it starts and whenever the engine says it has none.
// The engine keeps them in memory only, so a restarted engine has none until myOS pushes again, and with no lists a whole-screen Look is never taken
// (the one-window read is used instead): fail closed.

/// The lists myOS pushed, lower case.
nonisolated struct EngineLookRules: Equatable, Sendable {
    /// App names that are never in the picture (passwords, wallets, myOS itself).
    var privateApps: [String]
    /// Site hosts that are never in the picture, with their sub-domains (banks, payment sites).
    var privateSites: [String]
    /// A word that makes any host private ("bank").
    var privateHostWords: [String]
    /// Conversation apps (Messages, Mail, WhatsApp, Signal, Telegram): left out of a whole screen; read only when circled, by the old circled-text path.
    var messagingApps: [String]
    /// Conversation sites in a browser (Gmail, Outlook, WhatsApp web).
    var messagingSites: [String]

    static let maxEntries = 200
    static let maxLength = 80

    /// Never in the picture, whatever myOS pushed (so an old or empty push still keeps these out). Notification banners show the text of messages, so the
    /// Notification Center is on this list; the rest are password managers, the keychain, and myOS itself.
    static let alwaysLeftOutBundles: Set<String> = [
        "com.apple.notificationcenterui", "com.apple.passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.passbook", "com.gaspard.myos", "com.myos.engine",
    ]
    /// Conversation apps by bundle id, as a second way to recognise what the names might miss (an app's name can carry an invisible mark).
    static let messagingBundles: Set<String> = [
        "com.apple.mobilesms", "com.apple.mail", "net.whatsapp.whatsapp", "org.whispersystems.signal-desktop", "ru.keepcoder.telegram", "org.telegram.desktop", "com.tdesktop.telegram",
    ]
    /// Browsers (by bundle id): a window of one of these is judged by the page it shows.
    static let browserBundles: Set<String> = [
        "com.apple.safari", "com.apple.safaritechnologypreview", "com.google.chrome", "com.google.chrome.canary", "com.brave.browser", "company.thebrowser.browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.operasoftware.opera", "com.vivaldi.vivaldi", "com.kagi.kagimacos", "org.chromium.chromium", "com.sigmaos.sigmaos.macos",
    ]
    static let browserNames: Set<String> = ["safari", "google chrome", "brave browser", "arc", "dia", "firefox", "microsoft edge", "opera", "vivaldi", "orion", "chromium", "sigmaos"]

    /// The lists in a `look.rules` request, cleaned: lower case, trimmed, nothing empty or longer than 80 characters, at most 200 of each. `private_apps` must be
    /// there (a push with nothing in it is a mistake, not a way to switch the rules off); the others may be missing.
    static func parse(_ object: [String: Any]) -> EngineLookRules? {
        func list(_ key: String) -> [String]? {
            guard let raw = object[key] as? [Any] else { return nil }
            let cleaned = raw.compactMap { ($0 as? String).map { Self.fold($0) } }.filter { !$0.isEmpty && $0.count <= Self.maxLength }
            return Array(Set(cleaned)).sorted().prefix(Self.maxEntries).map { $0 }
        }
        guard let apps = list("private_apps"), !apps.isEmpty else { return nil }
        return EngineLookRules(privateApps: apps, privateSites: list("private_sites") ?? [], privateHostWords: list("private_host_words") ?? [], messagingApps: list("messaging_apps") ?? [], messagingSites: list("messaging_sites") ?? [])
    }

    /// Lower case, trimmed, and without the invisible marks some apps put in their names (WhatsApp's name starts with a left-to-right mark).
    static func fold(_ text: String) -> String {
        let visible = text.unicodeScalars.filter { $0.properties.generalCategory != .format }
        return String(String.UnicodeScalarView(visible)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The host of a page address, lower case without "www.", or "" when there is none.
    static func host(of url: String?) -> String {
        guard let url, let host = URLComponents(string: url)?.host?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What is known about one window when its fate is decided.
nonisolated struct EngineLookWindowFacts: Equatable, Sendable {
    var app: String
    var bundle: String
    var url: String?
    /// The window the pointer was over when Control went down: judged as the one-window read always judged it.
    var isFront: Bool
}

nonisolated enum EngineLookVerdict: Equatable, Sendable {
    case visible
    /// `wholeApp`: every window of the app is left out (a private or conversation app); otherwise only this window (a browser page).
    case leftOut(reason: String, wholeApp: Bool)

    var isLeftOut: Bool { if case .leftOut = self { return true } else { return false } }
}

extension EngineLookRules {
    /// Whether a window is in the picture. A window is seen only if it can be shown not to be private:
    /// - an app on a never-sent list, or an always-left-out bundle: no (private);
    /// - a conversation app (by name or bundle): no (conversation);
    /// - a browser page on a private or conversation site: no, this window only;
    /// - a browser window whose page address could not be read: no, unless it is the front window (judged as today);
    /// - anything else: yes.
    func verdict(for window: EngineLookWindowFacts) -> EngineLookVerdict {
        let app = Self.fold(window.app), bundle = window.bundle.lowercased()
        if Self.alwaysLeftOutBundles.contains(bundle) || self.privateApps.contains(app) { return .leftOut(reason: "private", wholeApp: true) }
        if Self.messagingBundles.contains(bundle) || self.messagingApps.contains(app) { return .leftOut(reason: "conversation", wholeApp: true) }
        let host = Self.host(of: window.url)
        if !host.isEmpty {
            if self.privateHostWords.contains(where: { host.contains($0) }) || self.privateSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .leftOut(reason: "private", wholeApp: false) }
            if self.messagingSites.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return .leftOut(reason: "conversation", wholeApp: false) }
            return .visible
        }
        let isBrowser = Self.browserBundles.contains(bundle) || Self.browserNames.contains(app)
        if isBrowser, !window.isFront { return .leftOut(reason: "address unreadable", wholeApp: false) }
        return .visible
    }

    /// The same for an app that has no window of its own in the list (a pop-up, a notification banner): only the app-level rules apply.
    func appIsLeftOut(name: String, bundle: String) -> Bool {
        let app = Self.fold(name), id = bundle.lowercased()
        return Self.alwaysLeftOutBundles.contains(id) || Self.messagingBundles.contains(id) || self.privateApps.contains(app) || self.messagingApps.contains(app)
    }
}

/// The rules the engine holds, in memory only.
nonisolated final class EngineLookRulesStore: @unchecked Sendable {
    static let shared = EngineLookRulesStore()
    private let lock = NSLock()
    private var rules: EngineLookRules?

    var current: EngineLookRules? {
        get { self.lock.lock(); defer { self.lock.unlock() }; return self.rules }
        set { self.lock.lock(); self.rules = newValue; self.lock.unlock() }
    }
}

/// A window of the display, front to back, as the choice between the two reads needs it.
nonisolated struct EngineLookLayoutWindow: Equatable, Sendable {
    var frame: CGRect
    var leftOut: Bool
}

/// A whole-screen Look takes two reads when Control goes down (the display with private windows cut out, and the one window under the pointer, as always),
/// because only afterwards is it known whether the user circled something.
nonisolated enum EngineLookChoice {
    /// True when the display read is the one to use. No circle: the display. A circle over a window that is in the picture: the display, narrowed to the
    /// circle. A circle over a window that was left out: the one-window read, whose rules (private never, conversation circled-text-only) are unchanged.
    static func useScreen(region: CGRect?, layout: [EngineLookLayoutWindow]) -> Bool {
        guard let region else { return true }
        let center = CGPoint(x: region.midX, y: region.midY)
        guard let top = layout.first(where: { $0.frame.contains(center) }) else { return true }
        return !top.leftOut
    }
}
