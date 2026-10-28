import AppKit
import Foundation

/// Sends a reply through the Messages app with AppleScript. macOS asks you to allow LaVoix to control Messages
/// the first time. LaVoix only sends text you typed into the notch's reply box.
enum MessagesSender {
    enum SendError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case let .failed(message): return message
            }
        }
    }

    private static let queue = DispatchQueue(label: "lavoix.messages.send")

    static func script(chatGUID: String, text: String) -> String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let body = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { "\"\(escaped($0))\"" }
            .joined(separator: " & linefeed & ")
        return "tell application \"Messages\"\n    send (\(body)) to chat id \"\(escaped(chatGUID))\"\nend tell"
    }

    /// A file sent into an existing chat (the same `chat id` the text script uses, so it works for groups too).
    static func fileScript(chatGUID: String, path: String) -> String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        return "tell application \"Messages\"\n    send (POSIX file \"\(escaped(path))\") to chat id \"\(escaped(chatGUID))\"\nend tell"
    }

    /// Where a file waits to be handed to Messages. The daemon that takes the file (imagent) runs in a sandbox that may read only a few places:
    /// ~/Pictures, ~/Library/Messages and this user's temporary folder (see /System/Library/Sandbox/Profiles/com.apple.imagent.sb). A folder under
    /// Application Support was refused ("deny file-read-data"), which made Messages show the file as Not Delivered. The temporary folder is allowed
    /// and macOS tidies it by itself.
    private static var outgoingFolder: URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("LaVoixOutgoing", isDirectory: true)
    }

    /// A private copy of the file to hand to Messages (a clone on the same disk, so it costs no space or time). Old copies are tidied away first.
    static func stageCopy(of url: URL) throws -> URL {
        let fileManager = FileManager.default
        let root = self.outgoingFolder
        // The folder an earlier version used (Messages was not allowed to read it): gone.
        if let old = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("LaVoix/outgoing") {
            try? fileManager.removeItem(at: old)
        }
        if let old = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) {
            for item in old {
                let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                if let created, Date().timeIntervalSince(created) > 3600 { try? fileManager.removeItem(at: item) }
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try fileManager.copyItem(at: url, to: copy)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw SendError.failed("Couldn't read \(url.lastPathComponent) to send it.")
        }
        return copy
    }

    /// Sends a file into a chat. AppleScript returns as soon as Messages has taken the file, so the caller still has to see the message arrive.
    static func sendFile(_ url: URL, toChat chatGUID: String) async throws {
        let copy = try self.stageCopy(of: url)
        let source = self.fileScript(chatGUID: chatGUID, path: copy.path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                var error: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "Messages couldn't send that file."
                    let number = error[NSAppleScript.errorNumber] as? Int
                    continuation.resume(throwing: SendError.failed(number == -1743
                        ? "Allow LaVoix to control Messages in System Settings > Privacy & Security > Automation."
                        : message))
                } else {
                    continuation.resume()
                }
            }
        }
        // Messages has its own copy by now; the staged one goes later, in case it is still being read.
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    }

    /// A text to someone you have no chat with yet: Messages starts the conversation (iMessage only).
    static func newScript(handle: String, text: String) -> String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let body = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { "\"\(escaped($0))\"" }
            .joined(separator: " & linefeed & ")
        return "tell application \"Messages\"\n    set theService to 1st service whose service type = iMessage\n    set theBuddy to buddy \"\(escaped(handle))\" of theService\n    send (\(body)) to theBuddy\nend tell"
    }

    static func sendNew(_ text: String, toHandle handle: String) async throws {
        let source = self.newScript(handle: handle, text: text)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                var error: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int
                    continuation.resume(throwing: SendError.failed(number == -1743
                        ? "Allow LaVoix to control Messages in System Settings > Privacy & Security > Automation."
                        : "Messages couldn't start that conversation. Check the number or email, and that they use iMessage."))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// The address that opens a one-to-one conversation in Messages (a phone number keeps its +, an email its @), or nil for a group chat,
    /// which has no such address.
    nonisolated static func conversationURL(handles: [String], isGroup: Bool) -> URL? {
        guard !isGroup, handles.count == 1, let handle = handles.first?.trimmingCharacters(in: .whitespaces), !handle.isEmpty else { return nil }
        var allowed = CharacterSet.urlHostAllowed
        allowed.insert(charactersIn: "+@")
        guard let encoded = handle.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "imessage://" + encoded)
    }

    static func compiles(_ source: String) -> Bool {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
    }

    static func send(_ text: String, toChat chatGUID: String) async throws {
        let source = self.script(chatGUID: chatGUID, text: text)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                var error: NSDictionary?
                _ = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    let message = (error[NSAppleScript.errorMessage] as? String) ?? "Messages couldn't send that."
                    let number = error[NSAppleScript.errorNumber] as? Int
                    // -1743: the user hasn't allowed LaVoix to control Messages.
                    continuation.resume(throwing: SendError.failed(number == -1743
                        ? "Allow LaVoix to control Messages in System Settings > Privacy & Security > Automation."
                        : message))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
