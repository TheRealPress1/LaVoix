import AppKit
import Combine
import SwiftUI

/// Owns the notch window and decides when it opens and closes. Hover is detected with mouse-moved monitors
/// (no polling), so while the pointer is elsewhere this does almost no work.
@MainActor
final class NotchHubController {
    static let shared = NotchHubController()

    let model = NotchHubModel()

    private var window: NotchHubWindow?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var unreadObserver: AnyCancellable?
    private var resignObserver: NSObjectProtocol?
    private(set) var isEditingText = false

    private let openDelay: UInt64 = 90_000_000
    private let closeDelay: UInt64 = 260_000_000

    var isRunning: Bool { self.window != nil }

    private init() {}

    func applyEnabledSetting() {
        if NotchHubSettings.isEnabled { self.start() } else { self.stop() }
    }

    func start() {
        guard self.window == nil, let screen = NotchGeometry.targetScreen() else { return }
        self.model.setClosedSize(NotchGeometry.closedSize(for: screen))

        let window = NotchHubWindow(frame: NotchGeometry.windowFrame(for: screen))
        let hosting = NSHostingView(rootView: NotchHubView(model: self.model))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window

        self.globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.pointerMoved() }
            return event
        }
        self.resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.endTextEntry() }
        }
        self.startMessagesIfEnabled()
        self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionWindow() }
        }
    }

    func stop() {
        self.openTask?.cancel()
        self.closeTask?.cancel()
        self.releaseTask?.cancel()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        self.globalMonitor = nil
        self.localMonitor = nil
        self.screenObserver = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        self.resignObserver = nil
        self.peekTask?.cancel()
        self.endTextEntry()
        MessagesStore.shared.stop()
        self.unreadObserver = nil
        self.model.close()
        self.window?.orderOut(nil)
        self.window = nil
    }

    // MARK: - Messages

    /// Starts or stops the iMessage widget to match its setting.
    func messagesSettingChanged() {
        guard self.isRunning else { return }
        self.model.reloadWidgets()
        if NotchMessagesSettings.isEnabled {
            self.startMessagesIfEnabled()
        } else {
            MessagesStore.shared.stop()
            self.unreadObserver = nil
            self.model.setBadge("messages", 0)
        }
    }

    private func startMessagesIfEnabled() {
        guard NotchMessagesSettings.isEnabled else { return }
        self.model.reloadWidgets()
        let store = MessagesStore.shared
        store.onIncoming = { [weak self] message, name in
            self?.peek(widgetID: "messages", chatID: message.chatID, seconds: 6)
            _ = name
        }
        self.unreadObserver = store.$unreadTotal.sink { [weak self] count in
            self?.model.setBadge("messages", count)
        }
        store.start()
    }

    /// Opens the notch on its own for a few seconds, e.g. when a message arrives.
    func peek(widgetID: String, chatID: Int64? = nil, seconds: Double) {
        guard self.isRunning, !self.recordingOverlayIsVisible, !self.isEditingText else { return }
        self.model.selectedWidgetID = widgetID
        if let chatID { MessagesStore.shared.select(chatID) }
        self.open()
        self.peekTask?.cancel()
        self.peekTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isEditingText else { return }
            if let screen = NotchGeometry.targetScreen(),
               NotchGeometry.openRect(for: screen).contains(NSEvent.mouseLocation) { return }
            self.close()
        }
    }

    // MARK: - Typing

    /// Lets the notch take the keyboard while a reply is being typed.
    func beginTextEntry() {
        guard let window else { return }
        self.isEditingText = true
        self.closeTask?.cancel()
        self.closeTask = nil
        window.allowsKey = true
        window.makeKey()
    }

    func endTextEntry() {
        guard self.isEditingText else { return }
        self.isEditingText = false
        window?.allowsKey = false
        window?.resignKey()
    }

    // MARK: - Hover

    /// Lets the self-test drive the notch without the real pointer interfering.
    private var ignoresPointer = false

    private func pointerMoved() {
        guard !self.ignoresPointer, let screen = NotchGeometry.targetScreen() else { return }
        let point = NSEvent.mouseLocation
        if self.model.isOpen {
            if self.isEditingText { return }
            if NotchGeometry.openRect(for: screen).contains(point), !self.recordingOverlayIsVisible {
                self.closeTask?.cancel()
                self.closeTask = nil
            } else {
                self.scheduleClose()
            }
        } else if NotchGeometry.triggerRect(for: screen).contains(point) {
            self.scheduleOpen()
        } else {
            self.openTask?.cancel()
            self.openTask = nil
        }
    }

    /// The dictation overlay uses the same spot; stay out of its way.
    private var recordingOverlayIsVisible: Bool {
        NotchOverlayManager.shared.isAnyNotchVisible
    }

    private func scheduleOpen() {
        guard self.openTask == nil, !self.recordingOverlayIsVisible, NSEvent.pressedMouseButtons == 0 else { return }
        let delay = self.openDelay
        self.openTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.openTask = nil
            guard let screen = NotchGeometry.targetScreen(),
                  NotchGeometry.triggerRect(for: screen).contains(NSEvent.mouseLocation),
                  !self.recordingOverlayIsVisible else { return }
            self.open()
        }
    }

    private func scheduleClose() {
        guard self.closeTask == nil else { return }
        let delay = self.closeDelay
        self.closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.closeTask = nil
            if let screen = NotchGeometry.targetScreen(),
               NotchGeometry.openRect(for: screen).contains(NSEvent.mouseLocation),
               !self.recordingOverlayIsVisible { return }
            self.close()
        }
    }

    private func open() {
        self.releaseTask?.cancel()
        self.window?.ignoresMouseEvents = false
        self.model.open()
    }

    private func close() {
        self.model.close()
        // Let the closing animation finish before clicks start passing through again.
        self.releaseTask?.cancel()
        self.releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, !self.model.isOpen else { return }
            self.window?.ignoresMouseEvents = true
        }
    }

    // MARK: - Debug

    func debugIgnorePointer(_ value: Bool) { self.ignoresPointer = value }

    func debugSetOpen(_ open: Bool) {
        if open { self.open() } else { self.close() }
    }

    func debugReport(_ label: String) -> String {
        guard let window else { return "[\(label)] no window" }
        let f = window.frame
        var line = "[\(label)] open=\(self.model.isOpen) visible=\(window.isVisible) clickThrough=\(window.ignoresMouseEvents) "
        line += "level=\(window.level.rawValue) frame=(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))) "
        if let screen = NotchGeometry.targetScreen() {
            let closed = NotchGeometry.closedSize(for: screen)
            line += "screen=\(Int(screen.frame.width))x\(Int(screen.frame.height)) hasNotch=\(screen.safeAreaInsets.top > 0) closed=\(Int(closed.width))x\(Int(closed.height)) "
            line += "centered=\(abs(f.midX - screen.frame.midX) < 1) flushTop=\(abs(f.maxY - screen.frame.maxY) < 1)"
        }
        return line
    }

    private func repositionWindow() {
        guard let window, let screen = NotchGeometry.targetScreen() else { return }
        self.model.setClosedSize(NotchGeometry.closedSize(for: screen))
        window.setFrame(NotchGeometry.windowFrame(for: screen), display: true)
    }
}
