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
    }

    /// Becomes true only while the user is typing a reply, so the notch never steals focus otherwise.
    var allowsKey = false

    override var canBecomeKey: Bool { self.allowsKey }
    override var canBecomeMain: Bool { false }
}
