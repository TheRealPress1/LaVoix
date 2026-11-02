import AppKit
import ApplicationServices
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// What is on the screen right now, read once, for myOS's "Look": the app in front, its window title and page address, the text on the
/// screen read by Apple's on-device text recognition, and (when asked) a screenshot file small enough to hand to a stronger model.
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
    /// {screen_access, accessibility, app?, bundle?, title?, url?, ocr_text, region_text?, screenshot?, width, height, ms}
    func capture(region: CGRect?, save: Bool) async -> [String: Any]
}

nonisolated enum EngineLookError: Error { case noDisplay }

nonisolated enum EngineLookLimits {
    static let maxText = 60_000
    static let keepFilesFor: TimeInterval = 15 * 60
    /// Long edge of the file handed to a model: bigger costs more and reads no better.
    static let uploadLongEdge: CGFloat = 1568
}

nonisolated struct LiveEngineLook: EngineLookProviding {
    func capture(region: CGRect?, save: Bool) async -> [String: Any] {
        let started = Date()
        var out: [String: Any] = await Task.detached(priority: .userInitiated) { EngineLookWindow.frontmost() }.value
        guard CGPreflightScreenCaptureAccess() else {
            out["screen_access"] = false
            out["ocr_text"] = ""
            out["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            return out
        }
        out["screen_access"] = true
        do {
            let shot = try await EngineLookScreen.capture()
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
        } catch {
            out["ocr_text"] = ""
            out["error"] = "The screen could not be read."
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        out["ms"] = ms
        DebugLogger.shared.info("Look capture: access=\(out["screen_access"] ?? false) ocrChars=\((out["ocr_text"] as? String)?.count ?? 0) saved=\(out["screenshot"] != nil) \(ms) ms", source: "EngineLook")
        return out
    }
}

// MARK: - The app in front

nonisolated enum EngineLookWindow {
    /// {app, bundle, accessibility, title?, url?}. The address is only there when the browser lets Accessibility read it.
    static func frontmost() -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ["accessibility": AXIsProcessTrusted()] }
        var result: [String: Any] = ["app": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? ""]
        guard AXIsProcessTrusted() else {
            result["accessibility"] = false
            return result
        }
        result["accessibility"] = true
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 1.0)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return result }
        let window = focused as! AXUIElement
        if let title = self.string(window, kAXTitleAttribute), !title.isEmpty { result["title"] = String(title.prefix(300)) }
        if let url = self.pageURL(in: window) { result["url"] = url }
        return result
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
        /// The display in points, in the same top-left coordinates the mouse uses.
        let frame: CGRect
    }

    /// The display the pointer is on, at its real pixel size, with the pointer drawn and this app's own windows left out.
    static func capture() async throws -> Shot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pointer = CGEvent(source: nil)?.location ?? .zero
        guard let display = content.displays.first(where: { $0.frame.contains(pointer) }) ?? content.displays.first else { throw EngineLookError.noDisplay }
        let own = Bundle.main.bundleIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.bundleIdentifier == own }, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        configuration.width = mode?.pixelWidth ?? Int(display.frame.width * 2)
        configuration.height = mode?.pixelHeight ?? Int(display.frame.height * 2)
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return Shot(image: image, frame: display.frame)
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
