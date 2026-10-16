import AppKit
import SwiftUI

/// `LAVOIX_SNAPSHOT_DIR=<dir> LAVOIX_SNAPSHOT_ITEMS=voice,ai,...` renders the main window to PNGs (one per page) and exits.
/// It draws the window's own views, so it needs no screen-recording permission. Quit the installed app first: a second
/// copy would otherwise take over its socket and shortcuts while it runs. Pages that show personal text (history,
/// meetings) are for the user to look at, not for this tool.
@MainActor
enum DebugWindowSnapshot {
    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["LAVOIX_SNAPSHOT_DIR"] else { return }
        let items = (env["LAVOIX_SNAPSHOT_ITEMS"] ?? "dashboard").split(separator: ",").map(String.init)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            NSApp.activate(ignoringOtherApps: true)
            // LAVOIX_SNAPSHOT_DARK=1 forces the dark look for this run only (nothing is saved to the user's settings).
            if env["LAVOIX_SNAPSHOT_DARK"] == "1" { NSApp.appearance = NSAppearance(named: .darkAqua) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            var wrote = 0
            for item in items {
                NotificationCenter.default.post(name: .lavoixDebugNavigate, object: item)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let window = NSApp.windows.filter({ $0.isVisible && $0.frame.width > 600 }).max(by: { $0.frame.width < $1.frame.width }),
                      let view = window.contentView?.superview ?? window.contentView else { print("SNAPSHOT no window for \(item)"); continue }
                guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(item).png"))
                    wrote += 1
                }
            }
            print("SNAPSHOT WROTE \(wrote) of \(items.count) to \(directory)")
            exit(0)
        }
    }
}
