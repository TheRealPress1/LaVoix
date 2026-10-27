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
