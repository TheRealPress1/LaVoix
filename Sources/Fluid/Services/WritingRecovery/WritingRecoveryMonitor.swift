import AppKit
import ApplicationServices
import Foundation

/// User-facing switches for Writing Recovery.
nonisolated enum WritingRecoverySettings {
    private static let enabledKey = "LaVoixWritingRecoveryEnabled"
    private static let daysKey = "LaVoixWritingRecoveryDays"
    private static let excludedKey = "LaVoixWritingRecoveryExcludedBundles"

    /// On by default: the feature is useless if you have to remember to turn it on before the writing is lost.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    static var retentionDays: Int {
        get { let d = UserDefaults.standard.integer(forKey: self.daysKey); return d > 0 ? d : 14 }
        set { UserDefaults.standard.set(newValue, forKey: self.daysKey) }
    }

    /// Apps the user excluded, on top of the built-in list.
    static var excludedBundles: [String] {
        get { UserDefaults.standard.stringArray(forKey: self.excludedKey) ?? [] }
        set { UserDefaults.standard.set(Array(Set(newValue)).sorted(), forKey: self.excludedKey) }
    }
}

/// What may be kept. Everything here runs BEFORE text reaches the store, and it errs on the side of not recording.
nonisolated enum WritingFilter {
    /// Password managers, terminals and code editors (which hold whole files that autosave anyway), plus LaVoix itself.
    static let builtInExcludedBundles: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.sublimetext.4",
        "com.lavoix.app", "com.myos.engine",
    ]
    static let excludedBundlePrefixes = ["com.jetbrains."]

    static let chromiumBundlePrefixes = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac", "org.chromium.", "company.thebrowser.", "com.vivaldi.", "com.operasoftware."]
    static func isChromiumBrowser(_ bundleID: String) -> Bool { self.chromiumBundlePrefixes.contains { bundleID.hasPrefix($0) } }

    static let allowedRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

    static func isExcluded(bundleID: String, extra: [String] = WritingRecoverySettings.excludedBundles) -> Bool {
        self.builtInExcludedBundles.contains(bundleID) || extra.contains(bundleID) || self.excludedBundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// Fields whose own label says they hold something secret ("Password", "CVV", "Card number"...).
    static func isSensitiveLabel(_ label: String) -> Bool {
        let lower = label.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if !words.isDisjoint(with: ["password", "passcode", "passwd", "pwd", "pin", "cvv", "cvc", "ssn", "otp"]) { return true }
        return ["card number", "security code", "secret key", "api key", "social security", "recovery code", "verification code", "one-time"].contains { lower.contains($0) }
    }

    /// One long unbroken token is a key, token or hash, not writing.
    static func looksLikeSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 24 && !trimmed.contains(where: { $0.isWhitespace })
    }

    static func shouldCapture(role: String?, subrole: String?, editable: Bool, label: String, bundleID: String, text: String) -> Bool {
        if self.isExcluded(bundleID: bundleID) { return false }
        if subrole == (kAXSecureTextFieldSubrole as String) || subrole == "AXSearchField" { return false }
        guard let role, self.allowedRoles.contains(role) || editable else { return false }
        if self.isSensitiveLabel(label) || self.looksLikeSecret(text) { return false }
        return true
    }
}

/// Watches the focused text field while you type and saves what it holds, so a draft survives a stray click, a closed tab
/// or a reload. It reads through Accessibility (the full field contents), not keystrokes, so cursor moves, paste, undo and
/// autocorrect all just work, and macOS withholds password fields. It only looks while you are typing, and only on this Mac.
nonisolated final class WritingRecoveryMonitor: @unchecked Sendable {
    static let shared = WritingRecoveryMonitor()

    private let queue = DispatchQueue(label: "lavoix.writing-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var primedPIDs = Set<pid_t>()
    private var pending: WritingSnapshot?
    private var pendingSaved = true
    private var lastPurge = Date.distantPast
    private var lastState = ""

    var store: WritingRecoveryStore = .shared
    /// Only read fields within this many seconds of a key press (tests turn it off).
    var typingWindow: TimeInterval? = 10
    var allowOwnApp = false
    var interval: TimeInterval = 1.0

    var isRunning: Bool { self.queue.sync { self.timer != nil } }

    /// Starts or stops to match the setting and the Accessibility permission. Safe to call repeatedly.
    func apply() {
        self.queue.async {
            let enabled = WritingRecoverySettings.isEnabled
            let trusted = AXIsProcessTrusted()
            let shouldRun = enabled && trusted
            if enabled, !trusted {
                // Permission may be granted later in System Settings: look again in a while, without a restart.
                self.queue.asyncAfter(deadline: .now() + 30) { [weak self] in self?.apply() }
            }
            if self.lastState != "\(enabled)-\(trusted)" {
                self.lastState = "\(enabled)-\(trusted)"
                DebugLogger.shared.info("Writing recovery: enabled=\(enabled) accessibility=\(trusted)", source: "WritingRecovery")
            }
            if shouldRun, self.timer == nil {
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now() + 1, repeating: self.interval)
                t.setEventHandler { [weak self] in self?.tick() }
                t.resume()
                self.timer = t
                self.store.purge(olderThanDays: WritingRecoverySettings.retentionDays)
            } else if !shouldRun, let t = self.timer {
                t.cancel()
                self.timer = nil
                self.flush()
            }
        }
    }

    // MARK: One look

    private func tick() {
        if Date().timeIntervalSince(self.lastPurge) > 3600 {
            self.lastPurge = Date()
            self.store.purge(olderThanDays: WritingRecoverySettings.retentionDays)
        }
        // Diagnostic: `defaults write com.lavoix.app LaVoixWritingRecoveryAlwaysRead -bool true` skips the typing gate (testing only).
        let alwaysRead = UserDefaults.standard.bool(forKey: "LaVoixWritingRecoveryAlwaysRead")
        if !alwaysRead, let window = self.typingWindow, CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > window {
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { self.diagnose("no frontmost app"); self.process(nil); return }
        self.diagnose("tick frontmost=\(bundle)")
        if !self.allowOwnApp, app.processIdentifier == getpid() { self.process(nil); return }
        self.process(self.snapshot(pid: app.processIdentifier, bundleID: bundle, appName: app.localizedName ?? bundle, now: Date()))
    }

    /// Reads the focused field of an app, or nil when it is not something we may keep.
    func snapshot(pid: pid_t, bundleID: String, appName: String, now: Date) -> WritingSnapshot? {
        if WritingFilter.isExcluded(bundleID: bundleID) { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        if !self.primedPIDs.contains(pid) {
            // Chromium and Electron apps only build their accessibility tree for web content when asked.
            self.primedPIDs.insert(pid)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if WritingFilter.isChromiumBrowser(bundleID) {
                // Chromium browsers build the accessibility tree for page content only for an assistive technology.
                // AXEnhancedUserInterface can disturb window managers in other apps, so it is set for browsers only.
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        if UserDefaults.standard.bool(forKey: "LaVoixWritingRecoveryAlwaysRead"), let w = Self.copy(app, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            // Diagnostic: how many text areas does this app expose in its front window, focused or not?
            var queue: [(AXUIElement, Int)] = [(w as! AXUIElement, 0)]
            var seen = 0, areas = 0, longest = 0
            while !queue.isEmpty, seen < 4000 {
                let (el, depth) = queue.removeFirst()
                seen += 1
                if (Self.copy(el, kAXRoleAttribute) as? String) == "AXTextArea" {
                    areas += 1
                    longest = max(longest, (Self.copy(el, kAXValueAttribute) as? String)?.count ?? 0)
                }
                if depth < 25, let kids = Self.copy(el, kAXChildrenAttribute) as? [AXUIElement] { queue.append(contentsOf: kids.map { ($0, depth + 1) }) }
            }
            self.diagnose("\(bundleID): tree scan nodes=\(seen) textAreas=\(areas) longestValue=\(longest)")
        }
        guard let focusedRef = Self.copy(app, kAXFocusedUIElementAttribute), CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            self.diagnose("\(bundleID): no focused element")
            return nil
        }
        let element = focusedRef as! AXUIElement
        if UserDefaults.standard.bool(forKey: "LaVoixWritingRecoveryAlwaysRead") {
            let role = Self.copy(element, kAXRoleAttribute) as? String ?? "nil"
            let sub = Self.copy(element, kAXSubroleAttribute) as? String ?? "nil"
            let len = (Self.copy(element, kAXValueAttribute) as? String)?.count ?? -1
            self.diagnose("\(bundleID): role=\(role) subrole=\(sub) valueLength=\(len)")
        }
        return self.snapshot(of: element, pid: pid, bundleID: bundleID, appName: appName, appElement: app, now: now)
    }

    func snapshot(of element: AXUIElement, pid: pid_t, bundleID: String, appName: String, appElement: AXUIElement?, now: Date) -> WritingSnapshot? {
        AXUIElementSetMessagingTimeout(element, 1.0)
        let role = Self.copy(element, kAXRoleAttribute) as? String
        let subrole = Self.copy(element, kAXSubroleAttribute) as? String
        let editable = (Self.copy(element, "AXEditable") as? Bool) ?? false
        guard let text = Self.copy(element, kAXValueAttribute) as? String else { return nil }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXIdentifierAttribute, kAXHelpAttribute]
            .compactMap { Self.copy(element, $0) as? String }.joined(separator: " ")
        guard WritingFilter.shouldCapture(role: role, subrole: subrole, editable: editable, label: label, bundleID: bundleID, text: text) else { return nil }
        var windowTitle = ""
        if let appElement, let w = Self.copy(appElement, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            windowTitle = (Self.copy(w as! AXUIElement, kAXTitleAttribute) as? String) ?? ""
        }
        return WritingSnapshot(bundleID: bundleID, appName: appName, windowTitle: windowTitle, fieldKey: "\(pid):\(CFHash(element)):\(role ?? "")", text: text, at: now)
    }

    /// Saves a field once it has been still for a moment, and immediately when focus moves away from it (so the last thing
    /// you wrote in a field you just left is never lost).
    func process(_ snap: WritingSnapshot?) {
        guard let snap else { self.flush(); self.pending = nil; return }
        if let p = self.pending, p.fieldKey == snap.fieldKey {
            if p.text != snap.text {
                self.pending = snap
                self.pendingSaved = false
            } else if !self.pendingSaved {
                self.store.ingest(snap)
                self.pendingSaved = true
            }
        } else {
            self.flush()
            self.pending = snap
            self.pendingSaved = false
        }
    }

    func flush() {
        if let p = self.pending, !self.pendingSaved { self.store.ingest(p) }
        self.pendingSaved = true
    }

    /// Saves anything not yet saved; for app quit (the monitor's own work runs on its queue).
    func flushSync() { self.queue.sync { self.flush() } }

    /// Test hook: run on the monitor's queue.
    func sync<T>(_ body: () -> T) -> T { self.queue.sync(execute: body) }

    private func diagnose(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "LaVoixWritingRecoveryAlwaysRead") else { return }
        DebugLogger.shared.info(message, source: "WritingRecovery")
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
}
