import AppKit
import SwiftUI

extension NotchHubDebug {
    /// `LAVOIX_NOTCH_CARD_TYPING_TEST=1`: can you start typing a reply? It opens the real notch panel with invented chats and, for each way of answering, checks that
    /// the cursor really is in a text field afterwards (the notch is the key window and a field is being edited): hovering a message card (its reply box), pressing the
    /// reply box on a card away from the line of text, a chat opened from a card (the cursor is asked for before the notch is on screen), and the same in the
    /// WhatsApp tab. The WhatsApp data is replaced by invented chats, so the real database is never opened. The panel shows for about ten seconds.
    @MainActor static func cardTypingTestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOTCH_CARD_TYPING_TEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                FileHandle.standardOutput.write(Data("\(ok ? "PASS" : "FAIL") \(name)\n".utf8))
            }
            func note(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            @MainActor func textFields(in view: NSView) -> [NSView] {
                var found: [NSView] = []
                if view is NSTextField || view is NSTextView { found.append(view) }
                for sub in view.subviews { found += textFields(in: sub) }
                return found
            }

            let hub = NotchHubController.shared
            let messages = MessagesStore.sample()
            // Nothing typed into this panel can ever be sent.
            messages.sendHandler = { _, _ in }
            messages.sendFileHandler = { _, _ in }
            let whatsApp = WhatsAppStore()
            whatsApp.persistsSeen = false
            let chats = [WhatsAppChat(id: 1, name: "Maya Chen", phone: "15551230001", lastText: "are you coming tonight?", lastDate: Date(), unread: 0)]
            let thread = [WhatsAppMessage(id: 1, text: "are you coming tonight?", date: Date(), isFromMe: false)]
            whatsApp.recentsSource = { chats }
            whatsApp.threadSource = { _ in thread }
            whatsApp.sendHandler = { _, _ in }

            await settle(1.2)
            hub.debugIgnorePointer(true)
            hub.start()
            hub.model.debugSetWidgets([
                NotchWidget(id: "messages", title: "Messages", systemImage: "message.fill") { AnyView(MessagesWidgetView(store: messages)) },
                NotchWidget(id: "whatsapp", title: "WhatsApp", systemImage: "bubble.left.fill") { AnyView(WhatsAppWidgetView(store: whatsApp)) },
            ])
            guard let window = hub.debugWindow, let content = window.contentView else { note("CARD TYPING TEST: no window"); exit(1) }

            // What the window looks like, written under any check about the cursor that fails, so a failure explains itself.
            @MainActor func describe() -> String {
                "appActive=\(NSApp.isActive) frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none") appKeyWindow=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none") visible=\(window.isVisible) key=\(window.isKeyWindow) responder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none") editing=\(hub.isEditingText) textFields=\(textFields(in: content).count) open=\(hub.model.isOpen) widget=\(hub.model.selectedWidgetID)"
            }
            @MainActor func checkCursor(_ name: String, _ ok: Bool) {
                check(name, ok)
                if !ok { note("    state: \(describe())") }
            }

            // The hub warms up each tab off screen about 2.5 s after it starts and then lets go of those views, and a tab letting go of its view ends typing on the
            // real window (their onDisappear). That happens once, at launch; let it finish so it cannot land in the middle of a check.
            await settle(3.4)

            // Every change of key window of the notch, with what caused a loss of it (the first frames of the call stack).
            let began = Date()
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                _ = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        let lost = name == NSWindow.didResignKeyNotification
                        let cause = lost ? " <- " + Thread.callStackSymbols.dropFirst(2).prefix(40).filter { !$0.contains("cardTypingTest") && !$0.contains("CFNOTIFICATION") }.prefix(9).map { line in
                            String(line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined())
                        }.joined(separator: " < ") : ""
                        note(String(format: "    [%.2fs] notch %@%@", Date().timeIntervalSince(began), lost ? "LOST the key" : "became key", cause))
                    }
                }
            }
            note("start: \(describe())")

            // 1. A message card. Hovering it shows its reply box (what the pointer does is done by hand here) and the cursor must be in it.
            hub.debugShowBanner(NotchBannerContent(chatID: 1, chatGUID: "g1", title: "Maya Chen", subtitle: nil, text: "are you coming tonight?", date: Date()))
            await settle(0.5)
            check("a card that has just arrived does not take the keyboard", !hub.hasTextFocus)
            hub.debugSetBannerExpanded(true)
            hub.beginTextEntry()
            await settle(1.0)
            checkCursor("hovering a card puts the cursor in its reply box", hub.hasTextFocus)
            // Dictation that began with the cursor in this reply box puts its words in it (they used to go nowhere: the notch is this app, not "another app").
            let replyBox = hub.focusedTextField
            check("dictation finds the reply box that has the cursor, and it can be typed into", replyBox != nil && replyBox?.isEditable == true && replyBox.map { hub.canInsertDictatedText(into: $0) } == true)
            let drafted = replyBox?.string ?? ""
            check("dictated words go into the reply box at the cursor", replyBox.map { hub.insertDictatedText("see you at eight", into: $0) } == true && replyBox?.string == drafted + "see you at eight")
            check("no words, no change", replyBox.map { hub.insertDictatedText("", into: $0) } == false && replyBox?.string == drafted + "see you at eight")

            // 2. The cursor is gone (clicked elsewhere, the window lost the keyboard): pressing the reply box ANYWHERE on it, not only on its line of text, brings it back.
            window.makeFirstResponder(nil)
            check("with the cursor taken away, nothing is being edited", !hub.hasTextFocus)
            check("and then nothing takes dictated words either", hub.focusedTextField == nil && replyBox.map { !hub.canInsertDictatedText(into: $0) } == true)
            if let field = textFields(in: content).first {
                let rect = field.convert(field.bounds, to: nil)
                // Above the field, inside the rounded box around it (the box is taller than the line of text).
                let point = NSPoint(x: rect.midX, y: rect.maxY + 5)
                let hit = content.hitTest(point)
                note("reply field frame \(Int(rect.width))x\(Int(rect.height)); the press lands on: \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
                check("the press lands beside the line of text, not on it", !(hit is NSTextField) && !(hit is NSTextView))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                await settle(0.7)
                checkCursor("pressing the reply box beside its line of text puts the cursor in it", hub.hasTextFocus)
            } else {
                check("the reply box has a text field", false)
            }
            hub.dismissBanner()
            await settle(0.3)

            // 3. A chat opened from a card. The cursor is asked for before the notch is on screen, so the thread must take it as it appears.
            hub.debugSetOpen(true)
            await settle(0.9)
            check("opening the notch by itself does not take the keyboard", !hub.hasTextFocus)
            hub.debugSetOpen(false)
            await settle(0.7)
            messages.requestReplyFocus()
            hub.debugSetOpen(true)
            await settle(1.1)
            checkCursor("Messages: a chat opened from a card has the cursor in its reply box", hub.hasTextFocus)
            hub.endTextEntry()
            hub.debugSetOpen(false)
            await settle(0.7)

            // 4. The same in the WhatsApp tab, which had no way of asking for the cursor at all.
            hub.model.selectedWidgetID = "whatsapp"
            hub.debugSetOpen(true)
            await settle(0.9)
            check("WhatsApp: opening the tab by itself does not take the keyboard", !hub.hasTextFocus)
            hub.debugSetOpen(false)
            await settle(0.7)
            whatsApp.requestReplyFocus()
            hub.debugSetOpen(true)
            await settle(1.1)
            checkCursor("WhatsApp: a chat opened from a card has the cursor in its reply box", hub.hasTextFocus)
            hub.endTextEntry()
            window.makeFirstResponder(nil)
            check("WhatsApp: with the cursor taken away, nothing is being edited", !hub.hasTextFocus)
            whatsApp.requestReplyFocus()
            await settle(0.8)
            checkCursor("WhatsApp: picking a chat while the tab is open puts the cursor in its reply box", hub.hasTextFocus)
            let whatsAppBox = hub.focusedTextField
            check("WhatsApp: dictated words go into its reply box too", whatsAppBox.map { hub.insertDictatedText("on my way", into: $0) } == true && whatsAppBox?.string.hasSuffix("on my way") == true)

            hub.endTextEntry()
            note("end: \(describe())")
            hub.stop()
            note(failures == 0 ? "CARD TYPING TEST ALL PASSED" : "CARD TYPING TEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
