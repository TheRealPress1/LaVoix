import Foundation

nonisolated enum MeetingNotesCommandError: LocalizedError {
    case launchFailed(String)
    case failed(Int32, String)
    case timedOut(Int)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message): return "Couldn't run the notes command: \(message)"
        case let .failed(code, stderr):
            let tail = stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)
            return "The notes command exited with code \(code)." + (tail.isEmpty ? "" : " \(tail)")
        case let .timedOut(seconds): return "The notes command took longer than \(seconds) seconds."
        case .emptyOutput: return "The notes command printed nothing."
        }
    }
}

/// Runs the user's own command (for example `claude -p`) to write notes instead of the on-device model. The prompt
/// goes in on stdin, the notes come back on stdout.
nonisolated enum MeetingNotesCommand {
    /// `command:claude` for `claude -p`; shown nowhere but stored with the notes so it is clear who wrote them.
    static func modelID(for command: String) -> String {
        let first = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "custom"
        return "command:" + (first as NSString).lastPathComponent
    }

    static func run(command: String, input: String, timeout: TimeInterval = 180) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try Self.runBlocking(command: command, input: input, timeout: timeout)
        }.value
    }

    private static func runBlocking(command: String, input: String, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A login shell, so the user's PATH (Homebrew, npm globals) is the one their terminal has.
        process.arguments = ["-lc", command]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { throw MeetingNotesCommandError.launchFailed(error.localizedDescription) }

        let box = OutputBox()
        let group = DispatchGroup()
        for (pipe, keyPath) in [(stdout, \OutputBox.out), (stderr, \OutputBox.err)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.set(keyPath, pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled { process.terminate(); throw CancellationError() }
            if Date() > deadline { process.terminate(); throw MeetingNotesCommandError.timedOut(Int(timeout)) }
            Thread.sleep(forTimeInterval: 0.1)
        }
        group.wait()
        let out = String(decoding: box.out, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw MeetingNotesCommandError.failed(process.terminationStatus, String(decoding: box.err, as: UTF8.self))
        }
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingNotesCommandError.emptyOutput }
        return text
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _out = Data(), _err = Data()
        var out: Data { self.lock.withLock { self._out } }
        var err: Data { self.lock.withLock { self._err } }
        func set(_ keyPath: KeyPath<OutputBox, Data>, _ data: Data) {
            self.lock.withLock { if keyPath == \OutputBox.out { self._out = data } else { self._err = data } }
        }
    }
}

/// Which writer is in charge of the notes: the user's command when one is set, otherwise the on-device model.
struct MeetingNotesBackend: Sendable {
    let modelID: String
    let command: String?

    @MainActor static var current: MeetingNotesBackend {
        let command = SettingsStore.shared.meetingNotesCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.isEmpty { return MeetingNotesBackend(modelID: LocalCleanupSettings.modelID, command: nil) }
        return MeetingNotesBackend(modelID: MeetingNotesCommand.modelID(for: command), command: command)
    }

    var isReady: Bool { self.command != nil || LocalCleanupProvider.isDownloaded(modelID: self.modelID) }
}
