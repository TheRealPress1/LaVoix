import AppKit
import Foundation
import LocalAuthentication

// The rules that keep the notch terminal in his hands only (docs/21-notch-terminal.md, "Human-only"). Everything here is pure or injectable, so each rule has a test.
// Nothing in this folder may be reached from the engine socket, myOS, Look, a model or any assistant; the autotest scans the sources to make sure of it.

nonisolated enum TerminalGuard {
    /// A key counts only if it came from the keyboard hardware. Measured on this macOS (spike 2): real input carries source process id 0, and every event
    /// another program posts carries that program's own id, whatever source it claims. Fail closed: an event with no CGEvent behind it is refused.
    static func isHardware(sourceProcessID: Int64) -> Bool { sourceProcessID == 0 }

    static func isHardware(_ event: NSEvent) -> Bool {
        guard let cg = event.cgEvent else { return false }
        return self.isHardware(sourceProcessID: cg.getIntegerValueField(.eventSourceUnixProcessID))
    }

    /// How long the notch may stay closed before the terminal locks again. It also locks at once on screen lock and sleep.
    static let autoLockSeconds: TimeInterval = 120

    static func shouldAutoLock(closedFor seconds: TimeInterval) -> Bool { seconds >= self.autoLockSeconds }

    /// What may be sent to the shell. Escape and the other control characters are removed (an escape in pasted text could end a bracketed paste early and
    /// run what follows); line breaks and tabs stay; every kind of line break becomes "\n".
    static func sanitized(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(unified.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F && !($0.value >= 0x80 && $0.value < 0xA0)) }))
    }

    /// sudo and su ask for a password, and there is no safe place to type one here. Guidance, not a security boundary (the Mac's own rules still apply).
    static func refusesPasswordCommand(_ text: String) -> Bool {
        text.range(of: #"(?m)(^|[;&|(`])\s*(sudo|su)(\s|$)"#, options: .regularExpression) != nil
    }

    /// What the shell is told on the wire for a line he typed: a single line plus Enter, or several lines as ONE bracketed paste plus Enter (so a pasted block
    /// is taken as a whole and is not run line by line).
    static func wire(for line: String) -> String {
        let clean = self.sanitized(line)
        if clean.contains("\n") { return "\u{1B}[200~" + clean + "\u{1B}[201~\n" }
        return clean + "\n"
    }

    /// The shell's whole environment: a short list, never the engine's own, so no token or setting of the engine travels into it.
    static func environment(shell: String, home: String, user: String, parent: [String: String]) -> [String] {
        var env: [String: String] = [
            "HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin",
            "TERM": "xterm-256color",
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
        ]
        // The login keeps working for ssh and git, and temporary files go where the system put them: neither is a secret.
        for key in ["TMPDIR", "SSH_AUTH_SOCK"] { if let value = parent[key], !value.isEmpty { env[key] = value } }
        return env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// The account's login shell, if it is a listed, executable shell; else /bin/zsh.
    static func loginShell() -> String {
        var candidate = "/bin/zsh"
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { candidate = String(cString: shell) }
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return listed.contains(candidate) && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
    }
}

// MARK: - Touch ID

nonisolated enum TerminalAuthResult: Equatable {
    case success
    case cancelled
    case failed(String)
    case unavailable(String)
}

nonisolated protocol TerminalAuthenticating: Sendable {
    func authenticate(reason: String) async -> TerminalAuthResult
}

/// Touch ID only: no password fallback is offered, so nothing but his fingerprint opens the terminal. A script or an agent can click the tab; it cannot touch the sensor.
nonisolated struct TouchIDAuthenticator: TerminalAuthenticating {
    func authenticate(reason: String) async -> TerminalAuthResult {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .unavailable(error?.localizedDescription ?? "Touch ID is not available on this Mac right now.")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
            return ok ? .success : .failed("Touch ID did not accept the fingerprint.")
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel: return .cancelled
            default: return .failed(laError.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
