import AppKit
import CoreGraphics
import Foundation
import SQLite3

/// Sends a WhatsApp message from the notch without WhatsApp coming to the front. WhatsApp Desktop has no way to be told to send, so this opens the chat with the
/// text typed (`open -g`, which keeps the front app as it is), gives WhatsApp a moment to type it, posts Return to WhatsApp's own process, and then looks in
/// WhatsApp's database for the message. Only that proof counts as sent. Same method as myOS's person page.
enum WhatsAppSender {
    private static let bundleID = "net.whatsapp.WhatsApp"
    private static let container = NSString(string: "~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared").expandingTildeInPath
    private static let queue = DispatchQueue(label: "lavoix.whatsapp.send")

    /// WhatsApp chats are found by phone number: the digits of a handle, or nil for an email or something too short or long to be a number.
    nonisolated static func digits(of handle: String) -> String? {
        guard !handle.contains("@") else { return nil }
        let digits = handle.filter(\.isNumber)
        return (7...15).contains(digits.count) ? digits : nil
    }

    nonisolated static func link(digits: String, text: String) -> URL? {
        let cleaned = text.filter { !$0.isNewline || $0 == "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        guard let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "whatsapp://send?phone=\(digits)&text=\(encoded)")
    }

    /// True when WhatsApp Desktop is installed and has been opened at least once.
    nonisolated static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: self.container + "/ChatStorage.sqlite")
    }

    static func send(_ text: String, toHandle handle: String) async throws {
        guard let digits = self.digits(of: handle), let url = self.link(digits: digits, text: text) else {
            throw MessagesSender.SendError.failed("WhatsApp needs a phone number for this person.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                do {
                    try self.sendBlocking(url: url, text: trimmed)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func whatsApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: self.bundleID).first
    }

    private static func sendBlocking(url: URL, text: String) throws {
        let started = Date().timeIntervalSince1970
        let running = self.whatsApp() != nil
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -g keeps the app you are in at the front. If WhatsApp is not running it has to be started, which does come forward.
        open.arguments = (running ? ["-g"] : []) + [url.absoluteString]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw MessagesSender.SendError.failed("WhatsApp Desktop couldn't be opened.") }
        Thread.sleep(forTimeInterval: running ? 2.0 : 5.0)
        guard let pid = self.whatsApp()?.processIdentifier else { throw MessagesSender.SendError.failed("WhatsApp Desktop isn't running.") }
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.postToPid(pid)
            Thread.sleep(forTimeInterval: 0.06)
        }
        for _ in 0..<8 {
            Thread.sleep(forTimeInterval: 0.9)
            if self.sentSince(started, text: text) { return }
        }
        throw MessagesSender.SendError.failed("WhatsApp opened with your message typed, but it couldn't be confirmed as sent. Check WhatsApp before sending it again.")
    }

    /// True when WhatsApp's own database has a message from you with this text since `since`. Works on a copy of the database, which is deleted after.
    private static func sentSince(_ since: TimeInterval, text: String) -> Bool {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "lavoix-wa-\(ProcessInfo.processInfo.processIdentifier)-\(Int(Date().timeIntervalSince1970 * 1000))"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        for name in ["ChatStorage.sqlite", "ChatStorage.sqlite-wal", "ChatStorage.sqlite-shm"] {
            let source = self.container + "/" + name
            if fm.fileExists(atPath: source) { try? fm.copyItem(atPath: source, toPath: dir + "/" + name) }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dir + "/ChatStorage.sqlite", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return false }
        defer { sqlite3_close(db) }
        let appleEpoch = 978_307_200.0
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM ZWAMESSAGE WHERE ZISFROMME = 1 AND ZMESSAGEDATE >= ?1 AND ZTEXT = ?2"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since - appleEpoch - 1)
        sqlite3_bind_text(statement, 2, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) > 0
    }
}
