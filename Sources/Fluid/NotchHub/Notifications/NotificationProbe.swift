import AppKit
import ApplicationServices

/// `LAVOIX_NOTIF_PROBE=1` (run via `open --env`): prints what macOS's notification banners look like to the
/// Accessibility API, after posting a harmless test notification. Research tool only.
enum NotificationProbe {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_NOTIF_PROBE"] == "1" else { return }
        Task.detached {
            func out(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            out("trusted=\(AXIsProcessTrusted())")
            let apps = NSWorkspace.shared.runningApplications.filter { ($0.bundleIdentifier ?? "").lowercased().contains("notificationcenter") }
            out("notification apps: \(apps.map { "\($0.bundleIdentifier ?? "?") pid=\($0.processIdentifier)" })")
            guard let app = apps.first else { out("PROBE DONE (no notification process)"); exit(0) }
            let element = AXUIElementCreateApplication(app.processIdentifier)

            out("--- baseline tree"); out(Self.dump(element, depth: 0, limit: 7))
            let env = ProcessInfo.processInfo.environment
            let seconds = Int(env["LAVOIX_NOTIF_PROBE_SECONDS"] ?? "10") ?? 10
            let script = Process()
            script.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            script.arguments = ["-e", "display notification \"probe body text\" with title \"Probe Title\" subtitle \"Probe Sub\""]
            if env["LAVOIX_NOTIF_PROBE_NOPOST"] != "1" {
                try? script.run()
                out("--- posted test notification")
            } else {
                out("--- watching for \(seconds)s: trigger a real notification now")
            }

            var seenTitles = Set<String>()
            var lastTree = ""
            for tick in 0 ..< (seconds * 4) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                var windows: CFTypeRef?
                _ = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
                let list = (windows as? [AXUIElement]) ?? []
                let titles = list.map { Self.attr($0, kAXTitleAttribute as String) ?? "(untitled)" }
                for (index, title) in titles.enumerated() where !seenTitles.contains(title) {
                    seenTitles.insert(title)
                    out("t=\(Double(tick + 1) * 0.25)s new window: \(title)")
                    if tick > 0 { out("--- NEW WINDOW TREE"); out(Self.dump(list[index], depth: 1, limit: 10)) }
                }
                let tree = Self.dump(element, depth: 0, limit: 10)
                if tree != lastTree, (tree.contains("Probe") && env["LAVOIX_NOTIF_PROBE_NOPOST"] != "1") {
                    out("--- BANNER TREE at t=\(Double(tick + 1) * 0.25)s")
                    // Print only the window that mentions the probe text.
                    for block in tree.components(separatedBy: "\n  Role=AXWindow") where block.contains("Probe") { out("  Role=AXWindow" + block) }
                    lastTree = tree
                    if tick > 6 { break }
                }
            }
            out("PROBE DONE")
            exit(0)
        }
    }

    private static func attr(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if let string = value as? String { return string.isEmpty ? nil : string }
        return nil
    }

    private static func dump(_ element: AXUIElement, depth: Int, limit: Int) -> String {
        guard depth <= limit else { return "" }
        var parts: [String] = []
        for key in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute] {
            if let value = self.attr(element, key as String) { parts.append("\(key.replacingOccurrences(of: "AX", with: ""))=\(value.prefix(80))") }
        }
        var names: CFArray?
        if AXUIElementCopyActionNames(element, &names) == .success, let actions = names as? [String], !actions.isEmpty {
            parts.append("actions=\(actions.map { $0.replacingOccurrences(of: "Name:", with: "").components(separatedBy: "\n").first ?? $0 })")
        }
        var line = String(repeating: "  ", count: depth) + parts.joined(separator: " | ") + "\n"
        var children: CFTypeRef?
        let childAttribute = depth == 0 ? kAXWindowsAttribute : kAXChildrenAttribute
        if AXUIElementCopyAttributeValue(element, childAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
            for child in list { line += self.dump(child, depth: depth + 1, limit: limit) }
        }
        return line
    }
}
