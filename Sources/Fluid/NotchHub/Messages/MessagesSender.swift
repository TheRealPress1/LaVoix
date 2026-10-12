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
