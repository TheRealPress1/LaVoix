import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// What is on the screen right now, read once, for myOS's "Look": one window (the topmost one under the pointer, or the biggest window of an
/// app the caller names), its app, title and page address, the text in it read by Apple's on-device text recognition, and (when asked) a
/// screenshot file small enough to hand to a stronger model. One window, not the display: a display holds every other window too (a terminal,
/// a sidebar), and their words end up in the text. A window is captured even when another window covers part of it, and on any display.
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
    /// reads the whole display under the pointer instead. `region` is in global points.
    func capture(region: CGRect?, save: Bool, app: String?, scope: String) async -> [String: Any]
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
}

nonisolated struct LiveEngineLook: EngineLookProviding {
    func capture(region: CGRect?, save: Bool, app: String?, scope: String) async -> [String: Any] {
        await self.finish(await self.read(app: app, scope: scope), region: region, save: save)
    }

    /// Picks the window, asks Accessibility about it and takes the picture. Reads no text yet.
    func read(app: String?, scope: String) async -> EngineLookRead {
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

    /// Reads the text of the picture (and of `region`, in global points, on its own), and keeps a small JPEG when asked.
    func finish(_ read: EngineLookRead, region: CGRect?, save: Bool) async -> [String: Any] {
        var out = read.info
        out["screen_access"] = read.screenAccess
        out["scope"] = read.scope
        out["ocr_text"] = ""
        if let error = read.error { out["error"] = error }
        if let shot = read.shot {
            out["width"] = shot.image.width
            out["height"] = shot.image.height
            let text = await Task.detached(priority: .userInitiated) { () -> (String, String?) in
                let whole = EngineLookText.read(shot.image)
                guard let region, let crop = EngineLookScreen.crop(shot, to: region) else { return (whole, nil) }
                return (whole, EngineLookText.read(crop))
            }.value
            out["ocr_text"] = text.0
            if let r = text.1 { out["region_text"] = r }
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

    /// The display the pointer is on, at its real pixel size, with the pointer drawn and this app's own windows left out.
    static func captureDisplay(pointer: CGPoint) async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first else { throw EngineLookError.noDisplay }
        let own = Bundle.main.bundleIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.bundleIdentifier == own }, exceptingWindows: [])
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
    /// Apple's text recognition, one line per row, top to bottom and left to right. Runs on the Neural Engine or the GPU, on this Mac.
    static func read(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return "" }
        let rows: [(CGRect, String)] = (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { (observation.boundingBox, $0.string) }
        }
        // Vision's origin is bottom-left, so a higher midY is higher on the screen; rows within a hair of each other read left to right.
        let sorted = rows.sorted { a, b in abs(a.0.midY - b.0.midY) > 0.008 ? a.0.midY > b.0.midY : a.0.minX < b.0.minX }
        return String(sorted.map(\.1).joined(separator: "\n").prefix(EngineLookLimits.maxText))
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
