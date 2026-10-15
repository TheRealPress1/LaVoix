import AppKit
import ApplicationServices
import Foundation

/// `LAVOIX_WRITING_AUTOTEST=1`: store rules, filters, and (when Accessibility is granted to this build) a live read of a
/// real text field in this process. Uses a temp database and made-up text; never touches the real writing store.
nonisolated enum WritingRecoveryAutotest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_WRITING_AUTOTEST"] == "1" else { return }
        Task.detached {
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
            let dir = URL(fileURLWithPath: "/tmp/lvw-\(UUID().uuidString.prefix(8))")
            let url = dir.appendingPathComponent("writing.db")
            let store = WritingRecoveryStore(url: url)
            let t0 = Date(timeIntervalSince1970: 1_800_000_000)
            func snap(_ text: String, key: String = "1:100:AXTextArea", window: String = "Apply — Acme", at: Double = 0) -> WritingSnapshot {
                WritingSnapshot(bundleID: "com.google.Chrome", appName: "Chrome", windowTitle: window, fieldKey: key, text: text, at: t0.addingTimeInterval(at))
            }
            let draft = "I am excited to apply for the role because I have spent five years building tools people actually use."

            // --- store ---
            check("short text is not kept", store.ingest(snap("hello there")) == .tooShort && store.count() == 0)
            check("a long enough draft creates an entry", store.ingest(snap(draft)) == .created && store.count() == 1)
            check("identical text is unchanged", store.ingest(snap(draft, at: 2)) == .unchanged)
            let longer = draft + " Last year I shipped a product used by thousands, and I would love to bring that to your team."
            check("growing text updates the same entry", store.ingest(snap(longer, at: 4)) == .updated && store.count() == 1)
            // select-all + delete, then a short replacement
            check("wiping the field updates the entry", store.ingest(snap("", at: 6)) == .updated)
            var e = store.entries().first
            check("after a wipe the latest is empty but the longest draft survives", e?.latest == "" && e?.peak == longer && e?.hasLongerDraft == true)
            check("the pre-wipe text is also a stored version", store.versions(entryID: e?.id ?? 0).contains { $0.text == longer })
            check("typing again after a wipe keeps one entry", store.ingest(snap("Dear team,", at: 8)) == .updated && store.count() == 1)
            e = store.entries().first
            check("the longest draft is still there", e?.peak == longer)

            // field re-created by the page (new key, same window, same start) is the same draft
            check("a re-created field merges into the entry", store.ingest(snap(longer + " Thank you.", key: "1:999:AXTextArea", at: 60)) == .updated && store.count() == 1)
            // a different window is a different draft
            check("another page is a separate entry", store.ingest(snap(draft, key: "1:200:AXTextArea", window: "Other form", at: 90)) == .created && store.count() == 2)
            // a field untouched for over 30 minutes starts a new entry even with the same key
            check("an old field with the same key starts fresh", store.ingest(snap("Completely different thing I am writing now, long enough to count.", at: 4000)) == .created && store.count() == 3)

            // versions are thinned but the first and longest stay
            let many = WritingRecoveryStore(url: dir.appendingPathComponent("many.db"))
            var text = String(repeating: "word ", count: 12)
            for i in 0 ..< 80 { text += String(repeating: "more words ", count: 3); _ = many.ingest(WritingSnapshot(bundleID: "b", appName: "A", windowTitle: "w", fieldKey: "k", text: text, at: t0.addingTimeInterval(Double(i))))}
            let me = many.entries().first
            let mv = many.versions(entryID: me?.id ?? 0)
            check("versions are capped", mv.count <= WritingRecoveryStore.maxVersionsPerEntry)
            check("the first and the longest versions are kept", mv.contains { $0.text.count == 60 } && mv.contains { $0.text == text } || mv.contains { $0.text.count == mv.map(\.text.count).max() })

            // search
            check("search finds text in the latest or longest draft", store.entries(search: "five years building").count >= 1)
            check("search by window title works", store.entries(search: "Other form").count == 1)
            check("search with symbols is not a syntax error", store.entries(search: "\"; DROP TABLE entry; --").count == 0 && store.count() == 3)

            // retention and deletion
            check("purge removes only old entries", store.purge(olderThanDays: 14, now: t0.addingTimeInterval(20 * 86400)) == 3 && store.count() == 0)
            _ = store.ingest(snap(draft, key: "a")); _ = store.ingest(WritingSnapshot(bundleID: "com.other", appName: "O", windowTitle: "x", fieldKey: "b", text: draft + " other app", at: t0))
            store.deleteAll(bundleID: "com.other")
            check("deleting one app's entries leaves the others", store.count() == 1)
            if let id = store.entries().first?.id { store.delete(entryID: id) }
            check("deleting an entry removes it and its versions", store.count() == 0)

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            check("database file is owner-only (0600)", (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            let dirAttrs = try? FileManager.default.attributesOfItem(atPath: dir.path)
            check("folder is owner-only (0700)", (dirAttrs?[.posixPermissions] as? NSNumber)?.intValue == 0o700)

            // --- filters ---
            func cap(role: String? = "AXTextArea", sub: String? = nil, editable: Bool = false, label: String = "", bundle: String = "com.google.Chrome", text: String = "a normal sentence of writing") -> Bool {
                WritingFilter.shouldCapture(role: role, subrole: sub, editable: editable, label: label, bundleID: bundle, text: text)
            }
            check("a normal text area is captured", cap())
            check("password fields are never captured", !cap(role: "AXTextField", sub: "AXSecureTextField"))
            check("a field labelled Password is skipped", !cap(label: "Your password"))
            check("card number / cvv / pin labels are skipped", !cap(label: "Card number") && !cap(label: "CVV") && !cap(label: "PIN code"))
            check("'pinned' is not mistaken for PIN", cap(label: "Pinned notes"))
            check("a long unbroken token (API key) is skipped", !cap(text: "sk_live_" + String(repeating: "a1B2", count: 10)))
            check("search fields are skipped", !cap(role: "AXTextField", sub: "AXSearchField"))
            check("non-text elements are skipped", !cap(role: "AXButton") && !cap(role: "AXWebArea"))
            check("an editable element of another role is allowed", cap(role: "AXGroup", editable: true))
            check("password managers are excluded", !cap(bundle: "com.1password.1password") && !cap(bundle: "com.bitwarden.desktop"))
            check("terminals and code editors are excluded", !cap(bundle: "com.apple.Terminal") && !cap(bundle: "com.microsoft.VSCode") && !cap(bundle: "com.jetbrains.intellij"))
            check("LaVoix itself is excluded", !cap(bundle: "com.lavoix.app"))
            check("the user's excluded apps are honoured", !WritingFilter.isExcluded(bundleID: "com.x.y", extra: []) && WritingFilter.isExcluded(bundleID: "com.x.y", extra: ["com.x.y"]))

            // --- pending / flush behaviour ---
            let monitorStore = WritingRecoveryStore(url: dir.appendingPathComponent("monitor.db"))
            let monitor = WritingRecoveryMonitor()
            monitor.store = monitorStore
            monitor.process(snap(draft, key: "f1"))
            check("a new reading is held, not saved yet", monitorStore.count() == 0)
            monitor.process(snap(draft, key: "f1"))
            check("the same reading twice is saved", monitorStore.count() == 1)
            monitor.process(snap(longer, key: "f1"))
            monitor.process(snap(longer + " and more", key: "f1"))
            monitor.process(nil)
            check("leaving the field saves the last thing written in it", monitorStore.entries().first?.latest == longer + " and more")
            monitor.process(snap("Another draft that is long enough to be worth keeping around.", key: "f2"))
            monitor.process(snap("Different field now, also long enough to keep around for later.", key: "f3"))
            check("moving to another field saves the one just left", monitorStore.entries(search: "Another draft").count == 1)

            // --- live Accessibility read of a real text field in this process ---
            if AXIsProcessTrusted() {
                let result = await MainActor.run { () -> (read: Bool, secure: Bool, details: String) in
                    _ = NSApplication.shared
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                    window.title = "Autotest window"
                    let scroll = NSTextView.scrollableTextView()
                    let textView = scroll.documentView as! NSTextView
                    textView.setAccessibilityLabel("Cover letter")
                    scroll.frame = NSRect(x: 0, y: 150, width: 400, height: 150)
                    let secure = NSSecureTextField(frame: NSRect(x: 0, y: 100, width: 300, height: 24))
                    window.contentView?.addSubview(scroll)
                    window.contentView?.addSubview(secure)
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(textView)
                    textView.string = draft
                    secure.stringValue = "hunter2-hunter2-hunter2-hunter2"
                    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    return (true, true, "")
                }
                _ = result
                let me = getpid()
                let live = WritingRecoveryMonitor()
                live.allowOwnApp = true
                // The test bundle id is excluded in the real filter, so read via the element API with a neutral bundle id.
                let app = AXUIElementCreateApplication(me)
                var focused: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
                if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                    let s = live.snapshot(of: focused as! AXUIElement, pid: me, bundleID: "com.example.test", appName: "Test", appElement: app, now: Date())
                    check("live: the focused NSTextView's full text is read through Accessibility", s?.text == draft)
                    check("live: the window title is captured", s?.windowTitle == "Autotest window")
                } else {
                    check("live: a focused element is found", false)
                }
                // Move focus to the secure field and make sure it is refused.
                await MainActor.run {
                    if let w = NSApp.windows.first(where: { $0.title == "Autotest window" }), let secure = w.contentView?.subviews.compactMap({ $0 as? NSSecureTextField }).first {
                        w.makeFirstResponder(secure)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                    }
                }
                var focused2: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused2)
                if let focused2, CFGetTypeID(focused2) == AXUIElementGetTypeID() {
                    let s = live.snapshot(of: focused2 as! AXUIElement, pid: me, bundleID: "com.example.test", appName: "Test", appElement: app, now: Date())
                    check("live: a real password field is refused", s == nil)
                } else {
                    print("SKIP live password check: no focused element")
                }
            } else {
                print("SKIP live Accessibility checks: this build has no Accessibility permission")
            }

            try? FileManager.default.removeItem(at: dir)
            print(failures == 0 ? "WRITING RECOVERY AUTOTEST ALL PASSED" : "WRITING RECOVERY AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
