import AppKit
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
        self.model.close()
        self.window?.orderOut(nil)
        self.window = nil
    }

    // MARK: - Hover

    /// Lets the self-test drive the notch without the real pointer interfering.
    private var ignoresPointer = false

    private func pointerMoved() {
        guard !self.ignoresPointer, let screen = NotchGeometry.targetScreen() else { return }
        let point = NSEvent.mouseLocation
        if self.model.isOpen {
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
