// Looks at the Look cursor companion without the engine: draws it over a backdrop of its own and takes small screenshots of that backdrop,
// so nothing of the user's screen is ever in a picture. It does not touch the pointer or the engine.
//
//   swiftc -swift-version 5 -default-isolation MainActor -parse-as-library \
//     Sources/Fluid/Services/Look/LookBuddy.swift tools/look_buddy_probe.swift -o /tmp/look_buddy_probe
//   /tmp/look_buddy_probe <output folder>        (about 14 seconds; writes <folder>/<name>.png and prints each name)
import AppKit

@main
@MainActor
enum LookBuddyProbe {
    static var backdrop: NSWindow?
    static var out = ""
    static var phase = 0.0
    static var level: CGFloat = 0.5
    static var backdropFrame = NSRect(x: 260, y: 360, width: 720, height: 460)

    static func main() {
        guard CommandLine.arguments.count > 1 else { print("usage: look_buddy_probe <output folder>"); exit(2) }
        out = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let primary = NSScreen.screens.first?.frame ?? .zero
        backdropFrame.origin.y = min(backdropFrame.origin.y, primary.height - backdropFrame.height - 80)
        let window = NSWindow(contentRect: backdropFrame, styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.orderFrontRegardless()
        backdrop = window
        // The microphone level the waveform follows: a speaking-like swell, loud then quiet.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in
                phase += 1.0 / 30
                level = CGFloat(0.55 + 0.4 * sin(phase * 2 * .pi * 0.9))
                LookBuddy.shared.setLevel(level)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { script() }
        app.run()
    }

    /// Quartz rectangle (top-left origin) of a rectangle given in AppKit points.
    static func quartz(_ r: NSRect) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func shoot(_ name: String, _ r: NSRect) {
        let q = quartz(r)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(Int(q.minX)),\(Int(q.minY)),\(Int(q.width)),\(Int(q.height))", "\(out)/\(name).png"]
        try? p.run()
        p.waitUntilExit()
        print("shot \(name) level=\(String(format: "%.2f", level))")
    }

    static func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { Task { @MainActor in body() } }
    }

    static func script() {
        let centre = CGPoint(x: backdropFrame.midX - 120, y: backdropFrame.midY - 40)
        let near = NSRect(x: centre.x - 60, y: centre.y - 40, width: 120, height: 80)
        LookBuddy.shared.begin(.listening)
        LookBuddy.shared.park(at: centre)
        after(0.8) { shoot("1_listening_a", near) }
        after(1.3) { shoot("1_listening_b", near) }
        after(1.7) { shoot("1_listening_c", near) }
        after(2.2) { LookBuddy.shared.setMode(.thinking) }
        after(2.7) { shoot("2_thinking_a", near) }
        after(2.85) { shoot("2_thinking_b", near) }
        after(3.4) { LookBuddy.shared.setMode(.following) }
        after(3.9) { shoot("3_rest", near) }
        // Point at a place in the top right of the backdrop (Quartz point), with a label.
        after(4.4) {
            let target = CGPoint(x: backdropFrame.maxX - 130, y: (NSScreen.screens.first?.frame.height ?? 0) - (backdropFrame.maxY - 70))
            LookBuddy.shared.point(atQuartz: target, label: "the email address", hold: 2.5)
        }
        after(4.4 + 0.30) { shoot("4_flight_early", backdropFrame) }
        after(4.4 + 0.55) { shoot("4_flight_mid", backdropFrame) }
        after(4.4 + 0.85) { shoot("4_flight_late", backdropFrame) }
        after(4.4 + 1.9) { shoot("5_pointing", backdropFrame) }
        after(4.4 + 2.3) { shoot("5_pointing_full", backdropFrame) }
        after(10.5) {
            LookBuddy.shared.end()
            print("windows after end: \(NSApp.windows.count)")
        }
        after(12.5) {
            print("windows after fade: \(NSApp.windows.count) showing=\(LookBuddy.shared.isShowing)")
            exit(0)
        }
    }
}
