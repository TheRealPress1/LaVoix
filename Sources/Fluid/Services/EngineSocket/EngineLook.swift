import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// What is on the screen right now, read once, for myOS's "Look": one window (the topmost one under the pointer, or the biggest window of an
/// app the caller names), its app, title and page address, the text in it read by Apple's on-device text recognition, and (when asked) a
/// screenshot file small enough to hand to a stronger model. One window by default, not the display: a display holds every other window too (a terminal,
/// a sidebar), and their words end up in the text. A window is captured even when another window covers part of it, and on any display.
/// Scope "screen" (docs/23 in the myOS repo) is the display with every private window cut out of the picture itself (`EngineLookRules`), so neither the
/// picture nor the words read from it can hold them; it needs the lists myOS pushes (`look.rules`) and without them reads one window instead.
///
/// Rules this follows:
/// - It never asks macOS for Screen Recording. Without it the answer says `screen_access: false` and carries no text; asking is a separate,
///   explicit step the user takes in setup.
/// - Nothing is read while a meeting is recording (the socket refuses before calling this), and the one-shot screenshot shares nothing with
///   the recorder's capture.
/// - Every call here runs off the main thread: an Accessibility call into a busy app can wait seconds, and the main thread carries the
///   dictation key tap.
/// - The engine's own windows (the notch, the overlay) are left out of the picture.
/// - Nothing that was read is written to the log, only counts. The page address loses its query and fragment (they carry tokens).
/// - The screenshot file lives in the owner-only folder, is deleted after fifteen minutes, and only exists when the caller asks for it.
nonisolated protocol EngineLookProviding: Sendable {
    /// {screen_access, accessibility, scope, app?, bundle?, title?, url?, ocr_text, region_text?, screenshot?, width, height, ms, error?}
    /// `app` names an app (its name or bundle id) whose biggest window is read; without it the window under the pointer is. `scope` "display"
    /// reads the whole display under the pointer instead; "screen" reads it with the private windows cut out and adds `windows` (the apps and pages in the
    /// picture, the front one marked) and `left_out` (which apps or pages were left out and why, by name only). `region` is in global points. `find` is phrases to locate on the screen: the answer
    /// then has `found`, one entry per phrase in the same order, {phrase, x, y, w, h, line, count} in global points (null when the phrase is
    /// not there), and `frame`, where the picture sits, {x, y, w, h}.
    func capture(region: CGRect?, save: Bool, app: String?, scope: String, find: [String]) async -> [String: Any]
}

/// The cursor companion, for myOS: show it thinking while it works, fly it to a point on the screen with a few words, or let it go.
nonisolated protocol EngineBuddyProviding: Sendable {
    func think() async
    func done() async
    /// `x`, `y` are global screen points with the origin at the top left of the main display (as Accessibility and the window list give them).
    func point(x: Double, y: Double, label: String?, hold: Double?) async
}

nonisolated struct LiveEngineBuddy: EngineBuddyProviding {
    func think() async { await MainActor.run { LookBuddy.shared.begin(.thinking) } }
    func done() async { await MainActor.run { LookBuddy.shared.end() } }
    func point(x: Double, y: Double, label: String?, hold: Double?) async {
        await MainActor.run { LookBuddy.shared.point(atQuartz: CGPoint(x: x, y: y), label: label, hold: hold) }
    }
}

nonisolated enum EngineLookError: Error { case noDisplay, noWindow }

nonisolated enum EngineLookLimits {
    static let maxText = 60_000
    static let keepFilesFor: TimeInterval = 15 * 60
    /// Long edge of the file handed to a model: bigger costs more and reads no better.
    static let uploadLongEdge: CGFloat = 1568
}

/// A window (or display) picked and photographed, not yet read: the session takes this when the chord goes down and reads the circled part
/// when it is released.
nonisolated struct EngineLookRead: @unchecked Sendable {
    var info: [String: Any]
    var shot: EngineLookScreen.Shot?
    var scope: String
    var screenAccess: Bool
    var error: String?
    var startedAt: Date
    /// The windows of a screen read, front to back, with whether each was left out of the picture (the Look chooses between its two reads with this).
    var layout: [EngineLookLayoutWindow] = []
}

nonisolated struct LiveEngineLook: EngineLookProviding {
    func capture(region: CGRect?, save: Bool, app: String?, scope: String, find: [String]) async -> [String: Any] {
        await self.finish(await self.read(app: app, scope: scope), region: region, save: save, find: find)
    }

    /// Picks the window, asks Accessibility about it and takes the picture. Reads no text yet.
    func read(app: String?, scope: String) async -> EngineLookRead {
        if scope == "screen", app == nil { return await self.readScreen() }
        let started = Date()
        let pointer = CGEvent(source: nil)?.location ?? .zero
        // Which window: the named app's frontmost, else the one under the pointer. A named app with no window is an error, never a quiet
        // fallback to something else on the screen. With no window under the pointer (or scope "display") the display is read instead.
        let wanted = app?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100).description ?? ""
        var pick: EngineLookTarget.Pick?
        if scope != "display" {
            if !wanted.isEmpty {
                pick = EngineLookTarget.ofApp(wanted)
                if pick == nil {
                    return EngineLookRead(info: [:], shot: nil, scope: "window", screenAccess: CGPreflightScreenCaptureAccess(), error: "No window of that app is open on a screen.", startedAt: started)
                }
            } else {
                pick = EngineLookTarget.underPointer(pointer)
            }
        }
        var info: [String: Any] = await Task.detached(priority: .userInitiated) { EngineLookWindow.info(for: pick) }.value
        guard CGPreflightScreenCaptureAccess() else {
            return EngineLookRead(info: info, shot: nil, scope: pick == nil ? "display" : "window", screenAccess: false, error: nil, startedAt: started)
        }
        do {
            if let pick {
                let shot = try await EngineLookScreen.captureWindow(pick)
                if let title = shot.title, info["title"] == nil, !title.isEmpty { info["title"] = String(title.prefix(300)) }
                return EngineLookRead(info: info, shot: shot, scope: "window", screenAccess: true, error: nil, startedAt: started)
            }
            let shot = try await EngineLookScreen.captureDisplay(pointer: pointer)
            return EngineLookRead(info: info, shot: shot, scope: "display", screenAccess: true, error: nil, startedAt: started)
        } catch {
            return EngineLookRead(info: info, shot: nil, scope: pick == nil ? "display" : "window", screenAccess: true, error: "The screen could not be read.", startedAt: started)
        }
    }

    /// The display under the pointer with the private windows cut out. Every window on that display is judged by `EngineLookRules` (the app, and for a browser the
    /// page it shows), the private ones are excluded from the capture itself, and the answer names what was left out. Without the lists myOS pushes this
    /// reads one window instead (fail closed): an unfiltered display is never taken here.
    func readScreen() async -> EngineLookRead {
        guard let rules = EngineLookRulesStore.shared.current else { return await self.read(app: nil, scope: "window") }
        let started = Date()
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard CGPreflightScreenCaptureAccess() else { return EngineLookRead(info: [:], shot: nil, scope: "screen", screenAccess: false, error: nil, startedAt: started) }
        // The windows on the display the pointer is on, front to back; the front one is the one under the pointer, as for a one-window read.
        var displays = [CGDirectDisplayID](repeating: 0, count: 4)
        var count: UInt32 = 0
        _ = CGGetDisplaysWithPoint(pointer, 4, &displays, &count)
        let bounds = count > 0 ? CGDisplayBounds(displays[0]) : CGDisplayBounds(CGMainDisplayID())
        let picks = EngineLookTarget.windows().filter { $0.bounds.intersects(bounds) }
        let front = EngineLookTarget.underPointer(pointer) ?? picks.first
        // Who each window is, quickly and all at once, within a couple of seconds; a window whose page address could not be read in time is judged without it.
        let deadline = started.addingTimeInterval(2.5)
        let facts: [CGWindowID: (facts: EngineLookWindowFacts, title: String?)] = await withTaskGroup(of: (CGWindowID, EngineLookWindowFacts, String?).self) { group in
            for pick in picks {
                let isFront = pick.windowID == front?.windowID
                group.addTask(priority: .userInitiated) {
                    let found = EngineLookWindow.lightFacts(pick, isFront: isFront, deadline: deadline)
                    return (pick.windowID, found.facts, found.title)
                }
            }
            var all: [CGWindowID: (facts: EngineLookWindowFacts, title: String?)] = [:]
            for await (id, f, title) in group { all[id] = (f, title) }
            return all
        }
        var excludedWindows = Set<CGWindowID>(), excludedApps = Set<pid_t>()
        var layout: [EngineLookLayoutWindow] = [], visible: [[String: Any]] = [], leftOut: [[String: Any]] = [], seenLeftOut = Set<String>()
        var frontLeftOut = false
        for pick in picks {
            guard let found = facts[pick.windowID] else { continue }
            let verdict = rules.verdict(for: found.facts)
            layout.append(EngineLookLayoutWindow(frame: pick.bounds, leftOut: verdict.isLeftOut))
            switch verdict {
            case .visible:
                var entry: [String: Any] = ["app": String(found.facts.app.prefix(60)), "front": found.facts.isFront]
                if let title = found.title { entry["title"] = title }
                if let url = found.facts.url.flatMap(EngineLookWindow.cleaned) { entry["url"] = String(url.prefix(200)) }
                visible.append(entry)
            case let .leftOut(reason, wholeApp):
                if wholeApp { excludedApps.insert(pick.pid) } else { excludedWindows.insert(pick.windowID) }
                if found.facts.isFront { frontLeftOut = true }
                // Names only: the app and why, never a title or an address.
                let name = String(found.facts.app.prefix(60))
                if seenLeftOut.insert(name + "|" + reason).inserted { leftOut.append(["app": name, "reason": reason]) }
            }
        }
        // What the one-window read would say about the window in front (its title, address and links) when that window is in the picture; only a name when it is not.
        var info: [String: Any] = await Task.detached(priority: .userInitiated) { EngineLookWindow.info(for: front) }.value
        let frontApp = info["app"] as? String ?? "", frontBundle = info["bundle"] as? String ?? ""
        if frontLeftOut || rules.appIsLeftOut(name: frontApp, bundle: frontBundle) {
            info = ["app": frontApp, "bundle": frontBundle, "accessibility": info["accessibility"] ?? false]
        }
        info["windows"] = Array(visible.prefix(12))
        info["left_out"] = Array(leftOut.prefix(8))
        do {
            let shot = try await EngineLookScreen.captureDisplay(pointer: pointer) { window in
                guard let app = window.owningApplication else { return false }
                // Every window of a private or conversation app (also the small ones and the banners the list above skips), and the pages judged one by one.
                return excludedApps.contains(app.processID) || excludedWindows.contains(window.windowID) || rules.appIsLeftOut(name: app.applicationName, bundle: app.bundleIdentifier)
            }
            return EngineLookRead(info: info, shot: shot, scope: "screen", screenAccess: true, error: nil, startedAt: started, layout: layout)
        } catch {
            return EngineLookRead(info: info, shot: nil, scope: "screen", screenAccess: true, error: "The screen could not be read.", startedAt: started, layout: layout)
        }
    }

    /// Reads the text of the picture (and of `region`, in global points, on its own), and keeps a small JPEG when asked.
    func finish(_ read: EngineLookRead, region: CGRect?, save: Bool, find: [String] = []) async -> [String: Any] {
        var out = read.info
        out["screen_access"] = read.screenAccess
        out["scope"] = read.scope
        out["ocr_text"] = ""
        if let error = read.error { out["error"] = error }
        if let shot = read.shot {
            out["width"] = shot.image.width
            out["height"] = shot.image.height
            let text = await Task.detached(priority: .userInitiated) { () -> (String, String?, [EngineLookText.Located?]) in
                let whole = EngineLookText.readLocating(shot.image, find: find, in: shot.frame)
                guard let region, let crop = EngineLookScreen.crop(shot, to: region) else { return (whole.text, nil, whole.found) }
                return (whole.text, EngineLookText.read(crop), whole.found)
            }.value
            out["ocr_text"] = text.0
            if let r = text.1 { out["region_text"] = r }
            out["frame"] = ["x": shot.frame.minX, "y": shot.frame.minY, "w": shot.frame.width, "h": shot.frame.height]
            if !find.isEmpty { out["found"] = text.2.map { (located: EngineLookText.Located?) -> Any in located?.json ?? NSNull() } }
            if save, let path = EngineLookFiles.saveForUpload(shot.image) { out["screenshot"] = path }
        }
        let ms = Int(Date().timeIntervalSince(read.startedAt) * 1000)
        out["ms"] = ms
        DebugLogger.shared.info("Look capture: scope=\(read.scope) access=\(read.screenAccess) ocrChars=\((out["ocr_text"] as? String)?.count ?? 0) links=\((out["links"] as? [Any])?.count ?? 0) saved=\(out["screenshot"] != nil) \(ms) ms", source: "EngineLook")
        return out
    }
}

// MARK: - Which window

nonisolated enum EngineLookTarget {
    struct Pick: Sendable {
        let windowID: CGWindowID
        let pid: pid_t
        let owner: String
        /// In global points, the same top-left coordinates the pointer uses.
        let bounds: CGRect
    }

    /// The normal windows that are on a screen, front to back, without this app's own windows (the notch, the overlay) and without tiny or
    /// see-through ones. Only where each window is and who owns it is read here; no window's contents.
    static func windows() -> [Pick] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                  bounds.width >= 120, bounds.height >= 80,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 else { return nil }
            return Pick(windowID: id, pid: pid, owner: info[kCGWindowOwnerName as String] as? String ?? "", bounds: bounds)
        }
    }

    /// The topmost window that holds the point.
    static func underPointer(_ point: CGPoint) -> Pick? {
        self.windows().first { $0.bounds.contains(point) }
    }

    /// The window of the app called `name` (its name or its bundle id, in any case) that is furthest forward, ignoring small ones such as a
    /// palette or a pop-up: it must be at least half the size of the app's biggest window.
    static func ofApp(_ name: String) -> Pick? {
        let wanted = name.lowercased()
        let mine = self.windows().filter { pick in
            pick.owner.lowercased() == wanted || NSRunningApplication(processIdentifier: pick.pid)?.bundleIdentifier?.lowercased() == wanted
        }
        let biggest = mine.map { $0.bounds.width * $0.bounds.height }.max() ?? 0
        return mine.first { $0.bounds.width * $0.bounds.height >= biggest / 2 }
    }
}

// MARK: - The app in front

nonisolated enum EngineLookWindow {
    /// {app, bundle, accessibility, title?, url?} for the window picked, or for the app in front when there is none. The address is only
    /// there when the browser lets Accessibility read it.
    static func info(for pick: EngineLookTarget.Pick?) -> [String: Any] {
        let app = pick.flatMap { NSRunningApplication(processIdentifier: $0.pid) } ?? NSWorkspace.shared.frontmostApplication
        guard let app else { return ["accessibility": AXIsProcessTrusted()] }
        var result: [String: Any] = ["app": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? ""]
        guard AXIsProcessTrusted() else {
            result["accessibility"] = false
            return result
        }
        result["accessibility"] = true
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)
        guard let window = self.axWindow(of: element, matching: pick?.bounds) else { return result }
        if let title = self.string(window, kAXTitleAttribute), !title.isEmpty { result["title"] = String(title.prefix(300)) }
        if let url = self.pageURL(in: window) { result["url"] = url }
        let links = self.links(in: window)
        if !links.isEmpty { result["links"] = links }
        return result
    }

    /// Who a window is, fast: its app and bundle, and for a browser its page address (found without the links and without a long walk). Used for every window
    /// of a screen read; each Accessibility call is held to half a second and the whole thing to `deadline`, after which the address is simply missing.
    static func lightFacts(_ pick: EngineLookTarget.Pick, isFront: Bool, deadline: Date) -> (facts: EngineLookWindowFacts, title: String?) {
        let running = NSRunningApplication(processIdentifier: pick.pid)
        var facts = EngineLookWindowFacts(app: running?.localizedName ?? pick.owner, bundle: running?.bundleIdentifier ?? "", url: nil, isFront: isFront)
        let isBrowser = EngineLookRules.browserBundles.contains(facts.bundle.lowercased()) || EngineLookRules.browserNames.contains(EngineLookRules.fold(facts.app))
        guard AXIsProcessTrusted(), Date() < deadline, let running else { return (facts, nil) }
        let element = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        guard let window = self.axWindow(of: element, matching: pick.bounds) else { return (facts, nil) }
        let title = self.string(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        if isBrowser, Date() < deadline { facts.url = self.pageURL(in: window) }
        return (facts, title)
    }

    /// The page's links as {text, href}: http(s) addresses (query and fragment removed) and mailto: addresses, at most sixty, found by walking
    /// the window's Accessibility tree, which is bounded in nodes and in time (an icon-only link, such as a LinkedIn button, has its address
    /// here and nowhere in the picture's text).
    static func links(in window: AXUIElement) -> [[String: String]] {
        var found: [[String: String]] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(1.5)
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var next = 0
        while next < queue.count, next < 2500, found.count < 60, Date() < deadline {
            let (element, depth) = queue[next]
            next += 1
            if self.string(element, kAXRoleAttribute) == "AXLink", let raw = self.string(element, "AXURL"), let href = self.linkTarget(raw), seen.insert(href).inserted {
                let text = self.string(element, kAXTitleAttribute) ?? self.string(element, kAXDescriptionAttribute) ?? ""
                found.append(["text": String(text.prefix(120)), "href": href])
            }
            guard depth < 30 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let kids = children as? [AXUIElement] {
                for child in kids.prefix(60) { queue.append((child, depth + 1)) }
            }
        }
        return found
    }

    /// "mailto:a@b.com?subject=x" becomes "mailto:a@b.com"; an http(s) address loses its query and fragment; anything else is not a link we keep.
    static func linkTarget(_ raw: String) -> String? {
        if raw.lowercased().hasPrefix("mailto:") {
            let address = raw.dropFirst(7).split(separator: "?").first.map(String.init) ?? ""
            return address.contains("@") && address.count <= 200 ? "mailto:\(address)" : nil
        }
        return self.cleaned(raw)
    }

    /// The Accessibility window at the picked window's place (so an app with several windows reports the right one's title and address), or
    /// the app's focused window when none was picked.
    private static func axWindow(of app: AXUIElement, matching bounds: CGRect?) -> AXUIElement? {
        if let bounds {
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
                for window in list.prefix(30) {
                    guard let origin = self.point(window, kAXPositionAttribute), let size = self.size(window, kAXSizeAttribute) else { continue }
                    if abs(origin.x - bounds.minX) < 3, abs(origin.y - bounds.minY) < 3, abs(size.width - bounds.width) < 3, abs(size.height - bounds.height) < 3 { return window }
                }
            }
            return nil
        }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &sz) ? sz : nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
        if CFGetTypeID(value) == CFURLGetTypeID() { return CFURLGetString((value as! CFURL)) as String? }
        return nil
    }

    /// Safari and some browsers say the page's address on the window or its web area; Chromium only when its accessibility tree is on, which
    /// this does not switch on (that would change the user's browser). So the address can be missing, and the caller must cope.
    private static func pageURL(in window: AXUIElement) -> String? {
        if let document = self.string(window, "AXDocument"), let clean = self.cleaned(document) { return clean }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 300 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if self.string(element, kAXRoleAttribute) == "AXWebArea", let url = self.string(element, "AXURL"), let clean = self.cleaned(url) { return clean }
            guard depth < 7 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let kids = children as? [AXUIElement] {
                for child in kids.prefix(40) { queue.append((child, depth + 1)) }
            }
        }
        return nil
    }

    /// An http(s) address without its query and fragment, or nil for anything else.
    static func cleaned(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }
}

// MARK: - The picture

nonisolated enum EngineLookScreen {
    struct Shot: @unchecked Sendable {
        let image: CGImage
        /// What was captured, in points, in the same top-left coordinates the mouse uses (a display's frame, or a window's).
        let frame: CGRect
        let title: String?
    }

    /// One window at its real pixel size, whatever covers it and whichever display it is on.
    static func captureWindow(_ pick: EngineLookTarget.Pick) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == pick.windowID }) else { throw EngineLookError.noWindow }
        let middle = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let display = content.displays.first { $0.frame.contains(middle) } ?? content.displays.first
        let mode = display.flatMap { CGDisplayCopyDisplayMode($0.displayID) }
        let scale = display.flatMap { d in mode.map { CGFloat($0.pixelWidth) / max(d.frame.width, 1) } } ?? 2
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(window.frame.width * scale))
        configuration.height = max(1, Int(window.frame.height * scale))
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
        return Shot(image: image, frame: window.frame, title: window.title)
    }

    /// The display the pointer is on, at its real pixel size, with the pointer drawn and this app's own windows left out. With `leaving`, every window it says
    /// yes to is left out of the picture too (cut out by the capture itself, so what was behind it shows and nothing of it is in the pixels).
    static func captureDisplay(pointer: CGPoint, leaving: ((SCWindow) -> Bool)? = nil) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first else { throw EngineLookError.noDisplay }
        let own = Bundle.main.bundleIdentifier
        let filter: SCContentFilter
        if let leaving {
            filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.bundleIdentifier == own || leaving($0) })
        } else {
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.bundleIdentifier == own }, exceptingWindows: [])
        }
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        configuration.width = mode?.pixelWidth ?? Int(display.frame.width * 2)
        configuration.height = mode?.pixelHeight ?? Int(display.frame.height * 2)
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return Shot(image: image, frame: display.frame, title: nil)
    }

    /// The part of the picture inside `region` (global points), or nil when it is outside this display or too small to hold text.
    static func crop(_ shot: Shot, to region: CGRect) -> CGImage? {
        let scale = CGFloat(shot.image.width) / max(shot.frame.width, 1)
        let pixels = CGRect(x: (region.minX - shot.frame.minX) * scale, y: (region.minY - shot.frame.minY) * scale, width: region.width * scale, height: region.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: shot.image.width, height: shot.image.height))
        guard !pixels.isNull, pixels.width >= 8, pixels.height >= 8 else { return nil }
        return shot.image.cropping(to: pixels)
    }
}

// MARK: - The words

nonisolated enum EngineLookText {
    /// A phrase found on the screen: where its text is (global points, top-left origin, the same coordinates as the pointer), and the line
    /// it is in. `count` is how many lines hold it; the one reported is the highest on the screen.
    struct Located: @unchecked Sendable {
        let phrase: String
        let rect: CGRect
        let line: String
        let count: Int
        var json: [String: Any] {
            ["phrase": self.phrase, "x": self.rect.minX, "y": self.rect.minY, "w": self.rect.width, "h": self.rect.height, "line": String(self.line.prefix(120)), "count": self.count]
        }
    }

    /// Apple's text recognition, one line per row, top to bottom and left to right. Runs on the Neural Engine or the GPU, on this Mac.
    static func read(_ image: CGImage) -> String { self.readLocating(image, find: [], in: .zero).text }

    /// The same read, and where each phrase in `find` stands inside `frame` (the global points the picture covers). The box is the phrase's own
    /// letters, not the whole line (Vision measures a stretch of a line), so a pointer can land on the email address inside a sentence.
    static func readLocating(_ image: CGImage, find phrases: [String], in frame: CGRect) -> (text: String, found: [Located?]) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return ("", phrases.map { _ in nil }) }
        let rows: [(box: CGRect, text: VNRecognizedText)] = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { (observation.boundingBox, $0) }
        }
        // Vision's origin is bottom-left, so a higher midY is higher on the screen; rows within a hair of each other read left to right.
        let sorted = rows.sorted { a, b in abs(a.box.midY - b.box.midY) > 0.008 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX }
        let text = String(sorted.map(\.text.string).joined(separator: "\n").prefix(EngineLookLimits.maxText))
        let found: [Located?] = phrases.map { phrase in
            var first: Located?
            var count = 0
            for row in sorted {
                guard let range = EngineLookFind.range(of: phrase, in: row.text.string) else { continue }
                count += 1
                if first == nil, let box = try? row.text.boundingBox(for: range) {
                    first = Located(phrase: phrase, rect: EngineLookFind.globalRect(normalized: box.boundingBox, in: frame), line: row.text.string, count: 0)
                }
            }
            return first.map { Located(phrase: $0.phrase, rect: $0.rect, line: $0.line, count: count) }
        }
        return (text, found)
    }
}

/// Where a phrase is: the rules, apart from the picture.
nonisolated enum EngineLookFind {
    static let maxPhrases = 8
    static let maxPhraseLength = 200

    /// The phrases asked for, cleaned: only strings, trimmed, none empty or over 200 characters, at most eight.
    static func phrases(from raw: Any?) -> [String] {
        let all = (raw as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return Array(all.filter { !$0.isEmpty && $0.count <= self.maxPhraseLength }.prefix(self.maxPhrases))
    }

    /// Where `phrase` stands in `line`, ignoring case, accents and how much white space sits between words; nil when it is not there.
    static func range(of phrase: String, in line: String) -> Range<String.Index>? {
        let wanted = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        if let found = line.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) { return found }
        let words = wanted.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard words.count > 1, let regex = try? NSRegularExpression(pattern: words.joined(separator: "\\s+"), options: [.caseInsensitive]) else { return nil }
        let length = (line as NSString).length
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: length)) else { return nil }
        return Range(match.range, in: line)
    }

    /// A box normalised to the picture (origin bottom-left, as Vision gives it) as global points (origin top-left) inside the picture's frame.
    static func globalRect(normalized n: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + n.minX * frame.width, y: frame.minY + (1 - n.maxY) * frame.height, width: n.width * frame.width, height: n.height * frame.height)
    }
}

// MARK: - The file handed to a model

nonisolated enum EngineLookFiles {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/private/look", isDirectory: true)
    }

    /// A JPEG of the picture, shrunk to the size a model reads well, in the owner-only folder. Older files are removed first.
    static func saveForUpload(_ image: CGImage, now: Date = Date()) -> String? {
        let manager = FileManager.default
        do { try manager.createDirectory(at: self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { return nil }
        self.prune(now: now)
        let scale = min(1, EngineLookLimits.uploadLongEdge / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale)), height = max(1, Int(CGFloat(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        let url = self.folder.appendingPathComponent("look-\(Int(now.timeIntervalSince1970 * 1000)).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, small, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    static func prune(now: Date) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: self.folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for file in files where file.lastPathComponent.hasPrefix("look-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > EngineLookLimits.keepFilesFor { try? manager.removeItem(at: file) }
        }
    }
}
