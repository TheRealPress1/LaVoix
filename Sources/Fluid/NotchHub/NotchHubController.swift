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
    private var dragMonitor: Any?
    private var dragEndMonitor: Any?
    /// The half of the drop split the dragged file is over, and the wait that opens it once the file has stayed there long enough.
    private var dwellTarget: NotchDropTarget?
    private var dwellTask: Task<Void, Never>?
    private var dragEndTask: Task<Void, Never>?
    private var holdsNowPlayingListener = false
    private var prewarmTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var bannerHovered = false
    /// True while the card's reply box has text in it, so leaving the card doesn't throw the draft away.
    var bannerHasDraft = false
    private var unreadObserver: AnyCancellable?
    private var whatsAppBadgeObserver: AnyCancellable?
    private var resignObserver: NSObjectProtocol?
    private var becomeKeyObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var stallTask: Task<Void, Never>?
    private(set) var isEditingText = false

    private let openDelay: UInt64 = 90_000_000
    private let closeDelay: UInt64 = 350_000_000
    /// After opening, ignore "pointer left" for this long, so a twitch or the opening animation can't close it.
    private let minimumOpenSeconds: TimeInterval = 0.8
    private var openedAt = Date.distantPast

    var isRunning: Bool { self.window != nil }

    private init() {}

    func applyEnabledSetting() {
        if NotchHubSettings.isEnabled { self.start() } else { self.stop() }
    }

    func start() {
        guard self.window == nil, let screen = NotchGeometry.targetScreen() else { return }
        self.model.setClosedSize(NotchGeometry.closedSize(for: screen))
        self.model.onExtraHeightChange = { [weak self] in self?.repositionWindow() }

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
            // Handled right away, in order with becoming key: a delayed task here could run after a later "became key" and
            // leave the typing flag stuck on.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isEditingText = false
                self.window?.allowsKey = false
                if self.model.banner != nil, !self.bannerHovered { self.scheduleBannerDismiss(after: 4, force: true) }
            }
        }
        self.becomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            // The panel only becomes key when a text field is clicked; keep the notch open while typing.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isEditingText = true
                self.closeTask?.cancel()
                self.closeTask = nil
            }
        }
        // Clicks that reach us through the *global* monitor were delivered to another app. If one lands on the open notch,
        // the window was click-through when it shouldn't have been.
        self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.checkClickPassedThrough() }
        }
        // Clicks delivered to this app while the notch is open: says which window and view took them.
        self.localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            // The notch only takes the keyboard when told to, and a click on a text field in a window that cannot be the key window never focuses it: the
            // first click must make the window key before the field sees it, or typing goes nowhere until a second click happens to work.
            if let self, self.clickIsOnTextField(event), !(self.window?.isKeyWindow ?? false) { self.beginTextEntry() }
            self?.noteClickInsideApp(event)
            // The title's arrow is handled here, not left to the SwiftUI button: a click that also made the notch the key window (and
            // moved the focus into a text field) was often used up by that, so it took a second click to unfold the tab icons.
            if self?.toggleTabsIfTitleClicked(event) == true { return nil }
            return event
        }
        self.startMessagesIfEnabled()
        self.startWhatsAppAlertsIfEnabled()
        ConnectionsStore.shared.restoreBadge()
        NotchMeetingCardController.shared.hubStateChanged()
        if NotchClipboardSettings.isEnabled { ClipboardStore.shared.start() }
        self.startCalendarIfEnabled()
        self.syncNowPlayingHistory()
        SystemStatsSampler.prefetch()
        self.prewarmTask = Task { @MainActor [weak self] in
            // A little after launch, while nothing else is going on, so the first real open isn't the first time any of it runs.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await self?.prewarmWidgets()
        }
        self.dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.fileDragMoved() }
        }
        self.dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in self?.fileDragEnded() }
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
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        self.resignObserver = nil
        if let becomeKeyObserver { NotificationCenter.default.removeObserver(becomeKeyObserver) }
        self.becomeKeyObserver = nil
        self.peekTask?.cancel()
        self.bannerTask?.cancel()
        self.model.hideBanner()
        self.endTextEntry()
        MessagesStore.shared.stop()
        self.unreadObserver = nil
        WhatsAppAlerts.shared.stop()
        self.whatsAppBadgeObserver = nil
        self.model.close()
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        self.dragMonitor = nil
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }
        self.dragEndMonitor = nil
        self.dwellTask?.cancel()
        self.dragEndTask?.cancel()
        self.dwellTarget = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        self.clickMonitor = nil
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        self.localClickMonitor = nil
        self.stopStallWatch()
        self.prewarmTask?.cancel()
        ClipboardStore.shared.stop()
        CalendarStore.shared.stop()
        self.releaseNowPlayingHistory()
        self.window?.orderOut(nil)
        self.window = nil
        NotchMeetingCardController.shared.hubStateChanged()
    }

    // MARK: - Warm-up

    /// Builds each tab's view once, off screen and one at a time, so SwiftUI has already done its first-use work (fonts,
    /// symbols, layout) before the notch is opened for real. Nothing is shown or started.
    func prewarmWidgets() async {
        for widget in self.model.widgets {
            if Task.isCancelled || self.model.isOpen { return }
            let host = NSHostingView(rootView: widget.content().environment(\.notchWidgetActive, false).frame(width: 592, height: 176))
            host.frame = NSRect(x: 0, y: 0, width: 592, height: 176)
            host.layoutSubtreeIfNeeded()
            _ = host.fittingSize
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    // MARK: - Clipboard and shelf

    /// Called when the clipboard or shelf setting changes.
    func widgetSettingsChanged() {
        guard self.isRunning else { return }
        self.model.reloadWidgets()
        if NotchClipboardSettings.isEnabled { ClipboardStore.shared.start() } else { ClipboardStore.shared.stop() }
        self.startCalendarIfEnabled()
    }

    /// Keeps the music listener running in the background while history is on, so songs are logged with the notch closed.
    func syncNowPlayingHistory() {
        guard self.isRunning else { return }
        if NotchNowPlayingSettings.keepsHistory {
            guard !self.holdsNowPlayingListener else { return }
            self.holdsNowPlayingListener = true
            NowPlayingStore.shared.start()
        } else {
            self.releaseNowPlayingHistory()
        }
        self.model.reloadWidgets()
    }

    private func releaseNowPlayingHistory() {
        guard self.holdsNowPlayingListener else { return }
        self.holdsNowPlayingListener = false
        NowPlayingStore.shared.stop()
    }

    private func startCalendarIfEnabled() {
        guard NotchCalendarSettings.isEnabled else { CalendarStore.shared.stop(); return }
        CalendarStore.shared.onMeetingDue = { event in NotchMeetingCardController.shared.presentStarting(event) }
        CalendarStore.shared.start()
    }

    /// While a file is being dragged, open the notch as soon as the pointer reaches it. With both Shelf and Messages available it opens as a split
    /// (Shelf on the left, iMessage on the right); holding the file over one half for `NotchDropSplitView.holdSeconds` opens that tab at full size.
    private func fileDragMoved() {
        guard let screen = NotchGeometry.targetScreen() else { return }
        let hasShelf = self.model.widgets.contains { $0.id == "shelf" }
        let hasMessages = self.model.widgets.contains { $0.id == "messages" }
        guard hasShelf || hasMessages else { return }
        let point = NSEvent.mouseLocation
        if self.model.isOpen {
            // Keep it open while the drag is over it, close once the drag leaves.
            if NotchGeometry.openRect(for: screen).contains(point) {
                self.closeTask?.cancel()
                self.closeTask = nil
                if self.model.dropSplit { self.setDropDwell(self.dropHalf(at: point, screen: screen)) }
            } else {
                if self.model.dropSplit { self.setDropDwell(nil) }
                self.scheduleClose()
            }
            return
        }
        guard NotchGeometry.triggerRect(for: screen).insetBy(dx: -24, dy: -10).contains(point),
              Self.dragPasteboardHasFiles else { return }
        if hasShelf && hasMessages {
            self.model.beginDropSplit()
        } else {
            self.model.selectedWidgetID = hasShelf ? "shelf" : "messages"
        }
        self.open()
    }

    /// Under the band behind the camera, the left half of the open notch is Shelf and the right half is iMessage.
    private func dropHalf(at point: NSPoint, screen: NSScreen) -> NotchDropTarget? {
        guard point.y <= screen.frame.maxY - self.model.closedSize.height else { return nil }
        return point.x < screen.frame.midX ? .shelf : .messages
    }

    /// Notes which half the file is over. Staying over the same half for `holdSeconds` opens it; moving to the other half (or off both) starts over.
    private func setDropDwell(_ target: NotchDropTarget?) {
        guard target != self.dwellTarget else { return }
        self.dwellTarget = target
        self.dwellTask?.cancel()
        self.dwellTask = nil
        self.model.setDropHover(target)
        guard let target else { return }
        self.dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NotchDropSplitView.holdSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.dwellTarget == target, self.model.dropSplit else { return }
            self.chooseDropHalf(target)
        }
    }

    /// The split gives way to the chosen tab, at full size, under the file that is still being held.
    private func chooseDropHalf(_ target: NotchDropTarget) {
        self.dwellTask = nil
        self.dwellTarget = nil
        self.model.selectedWidgetID = target == .shelf ? "shelf" : "messages"
        self.model.endDropSplit()
    }

    /// A file was dropped on one half of the split before the hold finished: it goes there at once and that tab opens.
    func dropFinished(on target: NotchDropTarget, urls: [URL]) {
        self.dragEndTask?.cancel()
        self.dwellTask?.cancel()
        self.dwellTask = nil
        self.dwellTarget = nil
        guard !urls.isEmpty else { self.model.endDropSplit(); return }
        switch target {
        case .shelf:
            ShelfStore.shared.add(urls)
            self.model.selectedWidgetID = "shelf"
        case .messages:
            MessagesStore.shared.stage(urls)
            self.model.selectedWidgetID = "messages"
        }
        self.model.endDropSplit()
    }

    /// The mouse button went up. If the split is still showing a moment later, nothing took the drop (it was let go over the camera band, or the
    /// drag was cancelled), so the notch closes.
    private func fileDragEnded() {
        guard self.model.dropSplit else { return }
        self.dragEndTask?.cancel()
        self.dragEndTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, self.model.dropSplit else { return }
            self.dwellTask?.cancel()
            self.dwellTask = nil
            self.dwellTarget = nil
            self.close()
        }
    }

    private static var dragPasteboardHasFiles: Bool {
        let types = NSPasteboard(name: .drag).types ?? []
        return types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
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
            let title = message.isGroup ? store.groupTitle(chatID: message.chatID, groupName: message.groupName) : name
            self?.showBanner(NotchBannerContent(
                chatID: message.chatID,
                chatGUID: message.chatGUID,
                title: title,
                avatarHandle: message.isGroup ? nil : message.senderHandle,
                groupHandles: message.isGroup ? store.participantHandles(chatID: message.chatID) : [],
                subtitle: message.isGroup ? name : nil,
                text: NotchMessagesSettings.showsPreviews ? message.text : "New message",
                date: message.date
            ))
        }
        store.onConnectionAlert = { [weak self] title, text, symbol in
            self?.showBanner(NotchBannerContent(chatID: 0, chatGUID: "", title: title, subtitle: nil, text: text, date: Date(), alertSymbol: symbol))
        }
        store.isBusy = { [weak self] in self?.recordingOverlayIsVisible ?? false }
        self.unreadObserver = store.$unreadTotal.sink { [weak self] count in
            self?.model.setBadge("messages", count)
        }
        store.start()
    }

    // MARK: - WhatsApp cards

    /// Starts or stops the cards for new WhatsApp messages to match their setting.
    func whatsAppSettingChanged() {
        guard self.isRunning else { return }
        self.startWhatsAppAlertsIfEnabled()
    }

    private func startWhatsAppAlertsIfEnabled() {
        guard NotchWhatsAppSettings.alertsEnabled, WhatsAppSender.isAvailable else {
            WhatsAppAlerts.shared.stop()
            self.whatsAppBadgeObserver = nil
            self.model.setBadge("whatsapp", 0)
            return
        }
        WhatsAppAlerts.shared.onIncoming = { [weak self] message in
            self?.showBanner(NotchBannerContent(
                chatID: message.chatID,
                chatGUID: "",
                title: message.name,
                avatarHandle: "+" + message.phone,
                subtitle: nil,
                text: NotchMessagesSettings.showsPreviews ? message.text : "New message",
                date: message.date,
                whatsAppPhone: message.phone
            ))
        }
        self.whatsAppBadgeObserver = WhatsAppStore.shared.$unreadChats.sink { [weak self] count in
            self?.model.setBadge("whatsapp", count)
        }
        WhatsAppStore.shared.refreshRecents()
        WhatsAppAlerts.shared.start()
    }

    // MARK: - Notification card

    /// Drops a notification card out of the notch. Hover expands it for a reply; it dismisses itself otherwise.
    func showBanner(_ content: NotchBannerContent) {
        // A text-entry flag left over from a panel that is no longer the key window would block cards forever.
        if self.isEditingText, !(self.window?.isKeyWindow ?? false) { self.isEditingText = false; self.window?.allowsKey = false }
        let blocker = !self.isRunning ? "hub not running"
            : self.recordingOverlayIsVisible ? "dictation overlay showing"
            : self.isEditingText ? "typing a reply"
            : self.model.isOpen ? "notch is open"
            : NotchMeetingCardController.shared.blocksBanners ? "meeting recording card"
            : nil
        if let blocker {
            DebugLogger.shared.debug("Message card not shown: \(blocker)", source: "NotchHub")
            return
        }
        NotchMeetingCardController.shared.dismissPrompt()
        self.releaseTask?.cancel()
        self.window?.ignoresMouseEvents = false
        self.bannerHovered = false
        self.model.showBanner(content)
        self.scheduleBannerDismiss(after: content.alertSymbol == nil ? 6 : (content.actionID == nil ? 12 : 30))
    }

    /// A card about a connection that broke (from the engine socket's `notch.alert`, sent by myOS). Clicking it opens myOS.
    func showAlert(title: String, text: String, symbol: String, icon: String? = nil, actionLabel: String? = nil, actionID: String? = nil) {
        self.showBanner(NotchBannerContent(chatID: 0, chatGUID: "", title: title, subtitle: nil, text: text, date: Date(), alertSymbol: symbol, alertIcon: icon, alertAction: .openMyOS, actionLabel: actionLabel, actionID: actionID))
    }

    func dismissBanner() {
        self.bannerTask?.cancel()
        self.bannerHovered = false
        self.bannerHasDraft = false
        self.endTextEntry()
        self.model.hideBanner()
        self.releaseClickThroughSoon()
    }

    /// Clicking the card opens the full conversation.
    func openConversationFromBanner() {
        guard let banner = self.model.banner else { return }
        self.bannerTask?.cancel()
        self.bannerHovered = false
        self.endTextEntry()
        self.model.hideBanner()
        if let actionID = banner.actionID {
            // Pressing the card itself does what its button does.
            ConnectionsWidgetView.press(actionID)
            return
        }
        if banner.alertSymbol != nil {
            // A connection alert: take the user to where it is fixed.
            switch banner.alertAction {
            case .fullDiskAccess:
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
            case .openMyOS:
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/myOS.app"))
            }
            return
        }
        if let phone = banner.whatsAppPhone {
            if self.model.widgets.contains(where: { $0.id == "whatsapp" }) {
                self.model.selectedWidgetID = "whatsapp"
                WhatsAppStore.shared.open(phone: phone, name: banner.title)
                self.open()
            } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "net.whatsapp.WhatsApp") {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        self.model.selectedWidgetID = "messages"
        MessagesStore.shared.select(banner.chatID)
        self.open()
    }

    func sendFromBanner(_ text: String, content: NotchBannerContent) {
        if let phone = content.whatsAppPhone {
            WhatsAppStore.shared.send(text, toPhone: phone) { [weak self] reason in
                self?.showAlert(title: "WhatsApp message not sent", text: reason, symbol: "exclamationmark.triangle.fill")
            }
        } else {
            MessagesStore.shared.send(text, toChatGUID: content.chatGUID)
        }
        self.endTextEntry()
        self.scheduleBannerDismiss(after: 1.4, force: true)
    }

    private func scheduleBannerDismiss(after seconds: Double, force: Bool = false) {
        self.bannerTask?.cancel()
        self.bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            if !force, self.isEditingText || self.bannerHovered { return }
            self.dismissBanner()
        }
    }

    private func releaseClickThroughSoon() {
        self.releaseTask?.cancel()
        self.releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, !self.model.isOpen, self.model.banner == nil else { return }
            self.window?.ignoresMouseEvents = true
        }
    }

    /// Opens the notch on its own for a few seconds, e.g. when a message arrives.
    func peek(widgetID: String, chatID: Int64? = nil, seconds: Double) {
        guard self.isRunning, !self.recordingOverlayIsVisible, !self.isEditingText else { return }
        self.model.selectedWidgetID = widgetID
        if let chatID { MessagesStore.shared.select(chatID) }
        self.isPeeking = true
        self.open()
        self.isPeeking = false
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
        // If the panel is no longer the key window, typing is over, whatever the flag says.
        if self.isEditingText, !(self.window?.isKeyWindow ?? false) { self.isEditingText = false; self.window?.allowsKey = false }
        let point = NSEvent.mouseLocation
        if self.model.banner != nil, !self.model.isOpen {
            let inside = NotchGeometry.bannerRect(for: screen, content: self.model.banner, expanded: self.model.bannerExpanded).contains(point)
            if inside, !self.bannerHovered {
                self.bannerHovered = true
                self.bannerTask?.cancel()
                self.model.setBannerExpanded(true)
                // Hovering is enough to start typing: take the keyboard now.
                self.beginTextEntry()
            } else if !inside, self.bannerHovered, !self.bannerHasDraft {
                self.bannerHovered = false
                self.endTextEntry()
                self.model.setBannerExpanded(false)
                self.scheduleBannerDismiss(after: 2.5)
            }
            return
        }
        if self.model.isOpen {
            if self.isEditingText { return }
            if NotchGeometry.openRect(for: screen).contains(point) {
                // Self-heal: whatever flipped the window to click-through, an open notch under the pointer takes clicks.
                if self.window?.ignoresMouseEvents == true {
                    DebugLogger.shared.warning("Open notch was click-through under the pointer; clicks re-enabled", source: "NotchHub")
                    self.releaseTask?.cancel()
                    self.window?.ignoresMouseEvents = false
                }
            }
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
        let grace = max(0, self.minimumOpenSeconds - Date().timeIntervalSince(self.openedAt))
        let delay = self.closeDelay + UInt64(grace * 1_000_000_000)
        self.closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.closeTask = nil
            if let screen = NotchGeometry.targetScreen(),
               NotchGeometry.openRect(for: screen).contains(NSEvent.mouseLocation) {
                if !self.recordingOverlayIsVisible { return }
                DebugLogger.shared.warning("Closing the notch under the pointer because the dictation overlay reports visible", source: "NotchHub")
            }
            self.close()
        }
    }

    private var isPeeking = false

    private func open() {
        if !self.model.isOpen {
            self.openedAt = Date()
            // Opening by hovering lands on Now Playing while something plays; a peek has already chosen its own tab.
            if !self.isPeeking, NotchNowPlayingStrip.shared.isPlayingAudibly || BookshelfCapture.shared.now.state == .playing, self.model.widgets.contains(where: { $0.id == "nowplaying" }) {
                self.model.selectedWidgetID = "nowplaying"
            }
        }
        self.releaseTask?.cancel()
        self.window?.ignoresMouseEvents = false
        self.model.open()
        self.startStallWatch()
    }

    private func close() {
        self.dwellTask?.cancel()
        self.dwellTask = nil
        self.dwellTarget = nil
        self.model.close()
        self.stopStallWatch()
        // Let the closing animation finish before clicks start passing through again.
        self.releaseTask?.cancel()
        self.releaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self, !self.model.isOpen else { return }
            self.window?.ignoresMouseEvents = true
        }
    }

    // MARK: - Diagnostics

    private func checkClickPassedThrough() {
        guard self.model.isOpen, let screen = NotchGeometry.targetScreen(),
              NotchGeometry.openRect(for: screen).contains(NSEvent.mouseLocation) else { return }
        DebugLogger.shared.warning("Click passed through the open notch: \(self.stateSummary)", source: "NotchHub")
        if self.window?.ignoresMouseEvents == true {
            self.releaseTask?.cancel()
            self.window?.ignoresMouseEvents = false
        }
    }

    /// Where the title and its arrow sit in the open notch (the band behind the camera, left side), in the window's own top-left coordinates.
    private func titleBandRect(contentWidth: CGFloat) -> CGRect {
        let left = (contentWidth - NotchGeometry.openSize.width) / 2 + 38
        let width = (NotchGeometry.openSize.width - self.model.closedSize.width) / 2 - 46
        return CGRect(x: left, y: 0, width: max(60, width), height: max(self.model.closedSize.height, 28))
    }

    /// A click on the title's arrow folds or unfolds the tab icons. Returns true when it was one (and has been handled).
    private func toggleTabsIfTitleClicked(_ event: NSEvent) -> Bool {
        guard self.model.isOpen, event.window === self.window, let content = self.window?.contentView else { return false }
        let point = event.locationInWindow
        let fromTop = CGPoint(x: point.x, y: content.bounds.height - point.y)
        guard self.titleBandRect(contentWidth: content.bounds.width).contains(fromTop) else { return false }
        self.model.tabsExpanded.toggle()
        DebugLogger.shared.info("Tabs \(self.model.tabsExpanded ? "unfolded" : "folded") by a click on the title", source: "NotchHub")
        return true
    }

    /// True when the click landed on a text field (or its editor) of the notch window.
    private func clickIsOnTextField(_ event: NSEvent) -> Bool {
        guard let window = self.window, event.window === window, self.model.isOpen || self.model.banner != nil,
              var view = window.contentView?.hitTest(event.locationInWindow) else { return false }
        while true {
            if view is NSTextField || view is NSTextView { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    private func noteClickInsideApp(_ event: NSEvent) {
        guard self.model.isOpen, let screen = NotchGeometry.targetScreen() else { return }
        let point = NSEvent.mouseLocation
        guard NotchGeometry.openRect(for: screen).contains(point) else { return }
        let target = event.window
        let isHub = target === self.window
        let hit = target?.contentView?.hitTest(event.locationInWindow).map { String(describing: type(of: $0)) } ?? "none"
        let name = target.map { String(describing: type(of: $0)) } ?? "no window"
        DebugLogger.shared.info("Click in open notch: window=\(isHub ? "hub" : name) level=\(target?.level.rawValue ?? 0) hit=\(hit) \(self.stateSummary)", source: "NotchHub")
    }

    /// While the notch is open, notes every time the main thread was too busy to run a 100 ms sleep on time. A stall
    /// here is what makes tab clicks queue up.
    private func startStallWatch() {
        guard self.stallTask == nil else { return }
        self.stallTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let before = ContinuousClock.now
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self else { return }
                let late = (ContinuousClock.now - before) - .milliseconds(100)
                let ms = Int(late.components.seconds * 1000 + late.components.attoseconds / 1_000_000_000_000_000)
                if ms > 150 {
                    DebugLogger.shared.warning("Main thread stalled \(ms) ms while the notch was open (tab: \(self.model.selectedWidgetID))", source: "NotchHub")
                }
            }
        }
    }

    private func stopStallWatch() {
        self.stallTask?.cancel()
        self.stallTask = nil
    }

    var stateSummary: String {
        "open=\(self.model.isOpen) clickThrough=\(self.window?.ignoresMouseEvents ?? false) key=\(self.window?.isKeyWindow ?? false) editing=\(self.isEditingText) dictationOverlay=\(self.recordingOverlayIsVisible) banner=\(self.model.banner != nil) tab=\(self.model.selectedWidgetID)"
    }

    /// Called after a tab click; says so in the log if the selection did not change.
    func verifyTabSwitch(to id: String) {
        DebugLogger.shared.info("Tab click on \(id) (was \(self.model.selectedWidgetID))", source: "NotchHub")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, self.model.selectedWidgetID != id else { return }
            DebugLogger.shared.warning("Tab click on \(id) did not switch: \(self.stateSummary)", source: "NotchHub")
        }
    }

    // MARK: - Debug

    func debugIgnorePointer(_ value: Bool) { self.ignoresPointer = value }
    var debugWindow: NSWindow? { self.window }

    func debugShowBanner(_ content: NotchBannerContent) { self.showBanner(content) }
    func debugSetBannerExpanded(_ expanded: Bool) { self.model.setBannerExpanded(expanded) }

    func debugSetOpen(_ open: Bool) {
        if open { self.open() } else { self.close() }
    }

    func debugReport(_ label: String) -> String {
        guard let window else { return "[\(label)] no window" }
        let f = window.frame
        var line = "[\(label)] key=\(window.isKeyWindow) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none") open=\(self.model.isOpen) visible=\(window.isVisible) clickThrough=\(window.ignoresMouseEvents) "
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
