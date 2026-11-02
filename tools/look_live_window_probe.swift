// Shows a window of its own with known text at known places, for checking the LIVE engine's look.capture "find" on a real window at the
// display's real scale, without ever reading anything of the user's. The engine reads only this window (it is asked for it by name).
//
//   swiftc -swift-version 5 -default-isolation MainActor -parse-as-library tools/look_live_window_probe.swift -o /tmp/locateprobe
//   /tmp/locateprobe 25     (shows the window for 25 seconds, prints the expected boxes as JSON on its first line, then waits)
//
// The process name is "locateprobe", so the engine is asked with {"op":"look.capture","app":"locateprobe","find":[...]}.
import AppKit

@main
@MainActor
enum LookLiveWindowProbe {
    static func main() {
        let seconds = Double(CommandLine.arguments.dropFirst().first ?? "25") ?? 25
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: 380, y: 420, width: 760, height: 300)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "locateprobe"
        // Normal level on purpose: the engine only reads ordinary windows (layer 0).
        window.backgroundColor = .white
        let font = NSFont.systemFont(ofSize: 28)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // (whole text, origin in the content view with the origin bottom-left, phrase to find inside it)
        let labels: [(String, CGPoint, String)] = [
            ("Contact: Anthony Ha, weekend editor", CGPoint(x: 30, y: 200), "Anthony Ha"),
            ("Email: anthony.ha@techcrunch.com", CGPoint(x: 30, y: 120), "anthony.ha@techcrunch.com"),
            ("Follow us on social media", CGPoint(x: 330, y: 40), "social media"),
        ]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        var expected: [[String: Any]] = []
        let contentRect = window.contentRect(forFrameRect: window.frame)
        let titlebar = window.frame.height - contentRect.height
        for (text, origin, phrase) in labels {
            let field = NSTextField(labelWithString: text)
            field.font = font
            field.sizeToFit()
            field.frame.origin = origin
            content.addSubview(field)
            let prefix = String(text[..<text.range(of: phrase)!.lowerBound])
            let x = origin.x + (prefix as NSString).size(withAttributes: attributes).width
            let width = (phrase as NSString).size(withAttributes: attributes).width
            // Content view (bottom-left) to window (the title bar sits on top) to AppKit global to Quartz global (top-left origin).
            let appKitY = window.frame.minY + origin.y
            let quartzTop = primaryHeight - (appKitY + field.frame.height)
            _ = titlebar
            expected.append(["phrase": phrase, "x": window.frame.minX + x, "y": quartzTop, "w": width, "h": field.frame.height])
        }
        window.contentView = content
        window.setFrameOrigin(frame.origin)
        window.orderFrontRegardless()
        // Where the window really is (Quartz, as the engine reports it) may differ from the request by the title bar, so print it as it is.
        let real = window.frame
        print(String(data: try! JSONSerialization.data(withJSONObject: ["frame": ["x": real.minX, "y": primaryHeight - real.maxY, "w": real.width, "h": real.height], "expected": expected]), encoding: .utf8)!)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
        app.run()
    }
}
