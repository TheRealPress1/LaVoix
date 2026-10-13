import AppKit

/// A transparent, non-activating panel pinned to the top of the screen. It never steals focus, shows on every
/// Space and over full-screen apps, and lets clicks through while the notch is closed.
final class NotchHubWindow: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.isFloatingPanel = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false
        self.level = .mainMenu + 3
        self.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        self.ignoresMouseEvents = true
        // Become the key window only when a click lands on something that needs typing (a text field), not for
        // ordinary clicks, so the notch never takes the keyboard from the app you're working in unless you ask.
        self.becomesKeyOnlyIfNeeded = true
        // The notch is always black, so controls inside it must render for dark mode even when macOS is light.
        self.appearance = NSAppearance(named: .darkAqua)
    }

    /// Set while a reply is being typed. Kept so callers can ask for the keyboard explicitly (hovering a card).
    var allowsKey = false

    /// Always able to become key; `becomesKeyOnlyIfNeeded` keeps that from happening unless a text field is clicked.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
