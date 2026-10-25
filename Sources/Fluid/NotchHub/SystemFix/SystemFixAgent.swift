import AppKit
import Combine
import Foundation

/// What the System tab can send an agent to fix.
nonisolated enum SystemResource: String, Sendable {
    case memory, storage, cpu

    var title: String {
        switch self {
        case .memory: return "memory"
        case .storage: return "storage"
        case .cpu: return "CPU"
        }
    }
}

/// One thing the agent proposes. The agent never does it; `SystemFixExecutor` does, after the user approves.
nonisolated struct SystemFixAction: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case quitApp = "quit_app", trashPath = "trash_path" }

    var kind: Kind
    /// An app's name (quit_app) or an absolute path (trash_path).
    var target: String
    var label: String
    var reason: String
    /// Filled in by us after the plan arrives (measured, never the model's claim); nil when unknown.
    var bytes: UInt64?

    var id: String { self.kind.rawValue + ":" + self.target }

    private enum CodingKeys: String, CodingKey { case kind, target, label, reason }
}

nonisolated struct SystemFixPlan: Codable, Equatable, Sendable {
    var summary: String
    var actions: [SystemFixAction]
}

/// Sends a Claude Code session to look into a System tab resource that is close to its limit, then turns its answer into
/// a short list the user approves. The session is read-only (`du`, `ls`, `ps`, `df` and friends); the changes are made by
/// `SystemFixExecutor`, which only touches what `SystemFixSafety` allows.
@MainActor
final class SystemFixAgent: ObservableObject {
    static let shared = SystemFixAgent()

    enum Phase: Equatable {
        case idle
        case investigating(SystemResource)
        case proposal(SystemResource, SystemFixPlan)
        case applying(SystemResource)
        case finished(SystemResource, SystemFixReport)
        case failed(SystemResource, String)
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var process: Process?

    func investigate(_ resource: SystemResource, snapshot: SystemStatsSampler.Snapshot) {
        guard case .idle = self.phase else { return }
        self.phase = .investigating(resource)
        let brief = Self.brief(resource, snapshot)
        self.task = Task { [weak self] in
            do {
                let raw = try await Self.runClaude(brief: brief, resource: resource) { process in
                    Task { @MainActor in self?.process = process }
                }
                let plan = try await Task.detached(priority: .utility) { try SystemFixSafety.sanitize(raw, for: resource) }.value
                guard let self, !Task.isCancelled else { return }
                self.phase = .proposal(resource, plan)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed(resource, (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
            self?.process = nil
        }
    }

    func apply(_ plan: SystemFixPlan, selected: Set<String>, resource: SystemResource) {
        guard case .proposal = self.phase else { return }
        self.phase = .applying(resource)
        let chosen = plan.actions.filter { selected.contains($0.id) }
        self.task = Task { [weak self] in
            let report = await SystemFixExecutor.run(chosen)
            self?.phase = .finished(resource, report)
        }
    }

    func emptyTrash(resource: SystemResource, report: SystemFixReport) {
        var next = report
        next.trashEmptied = SystemFixExecutor.emptyTrash()
        self.phase = .finished(resource, next)
    }

    /// Back to the tiles; also stops a running investigation.
    func dismiss() {
        self.task?.cancel()
        self.task = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        self.phase = .idle
    }

    // MARK: - The brief

    private static func brief(_ resource: SystemResource, _ s: SystemStatsSampler.Snapshot) -> String {
        func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        let home = NSHomeDirectory()
        var lines = [
            "The user's home folder is \(home). This Mac is running low on \(resource.title). Find what can safely be freed and propose actions.",
            "Readings now: memory \(gb(s.memoryUsed)) of \(gb(s.memoryTotal)) used, swap \(gb(s.swapUsed)) of \(gb(s.swapTotal)), "
                + "CPU \(Int((s.cpu * 100).rounded()))%, storage \(gb(s.diskFree)) free of \(gb(s.diskTotal)).",
        ]
        if !s.topApps.isEmpty {
            lines.append("Biggest memory users: " + s.topApps.map { "\($0.name) \(gb($0.bytes))" }.joined(separator: ", ") + ".")
        }
        switch resource {
        case .memory:
            lines.append("Look at `ps -Ao pid,rss,pcpu,comm -m | head -40` for what holds memory and propose quitting apps that are likely idle or heavy. Name the app as it appears in the Dock (for example Dia, not its helper processes).")
        case .cpu:
            lines.append("Look at `ps -Ao pid,pcpu,rss,comm -r | head -30` for what is using CPU and propose quitting apps that are running away or idle-but-busy. Name the app as it appears in the Dock.")
        case .storage:
            lines.append("Measure with `du -sk` and `ls` the usual regenerable space: \(home)/Library/Caches/*, \(home)/Library/Logs, \(home)/Library/Developer/Xcode/DerivedData/*, \(home)/.npm/_cacache, \(home)/.cache, \(home)/Library/pnpm, package-manager and build caches, build folders named DerivedData, and big old files in \(home)/Downloads. Propose trashing items with absolute paths, biggest first.")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static let systemPrompt = """
    You are a careful Mac cleanup assistant inside a notch widget. You may only investigate with read-only commands \
    (du, ls, ps, df, vm_stat, top -l 1, memory_pressure, uname, head, sort, wc); never open file contents. Run ONE plain command per tool call with absolute paths: no cd, no ~, no ;, &&, || or redirects like 2>/dev/null (a pipe into sort or head is fine; a command that fails is fine, just move on). You do NOT delete or quit \
    anything: you return a proposal and the user approves each item. Propose at most 8 actions, best first, only things \
    that are safe: caches and logs that regenerate, build leftovers, files in Downloads that look like old installers or \
    archives, and apps that are heavy or idle. Never propose system apps, the Finder, anything in Documents, Desktop, \
    Pictures, Music, Movies, source code folders, app data (Application Support), Messages, Mail, Keychains or dotfiles \
    holding keys. For memory or CPU use only quit_app (clearing files does not free memory); for storage use only trash_path. Use kind quit_app (target = app name) or trash_path (target = absolute path, no ~). label is a short \
    human name (under 40 characters); reason is one short sentence on why it is safe and what the user loses (for \
    example 'rebuilds on next build' or 'may have unsaved work'). summary is one sentence on what you found. If nothing \
    safe is worth doing, return an empty actions list and say so in the summary.
    """

    private nonisolated static let schema = """
    {"type":"object","properties":{"summary":{"type":"string"},"actions":{"type":"array","items":{"type":"object",\
    "properties":{"kind":{"type":"string","enum":["quit_app","trash_path"]},"target":{"type":"string"},\
    "label":{"type":"string"},"reason":{"type":"string"}},"required":["kind","target","label","reason"]}}},\
    "required":["summary","actions"]}
    """

    // MARK: - Running Claude Code

    enum AgentError: LocalizedError {
        case notInstalled, timedOut, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Claude Code isn't installed on this Mac."
            case .timedOut: return "The agent took too long (3 min) and was stopped."
            case let .failed(why): return why
            }
        }
    }

    private nonisolated static func claudeExecutable() -> URL? {
        let home = NSHomeDirectory()
        for path in ["\(home)/.local/bin/claude", "/usr/local/bin/claude", "/opt/homebrew/bin/claude", "\(home)/.claude/local/claude"]
            where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Runs one headless session: no plugins, MCP servers, skills or settings (a default session loaded hundreds of
    /// thousands of tokens of them and cost dollars; this one costs fractions of a cent), a throwaway working folder,
    /// only read-only shell commands allowed, a spending cap, and everything else denied.
    private nonisolated static func runClaude(brief: String, resource: SystemResource, started: @escaping @Sendable (Process) -> Void) async throws -> SystemFixPlan {
        guard let executable = Self.claudeExecutable() else { throw AgentError.notInstalled }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("myos-system-fix", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let readOnly = ["du", "ls", "ps", "df", "vm_stat", "top -l 1", "memory_pressure", "uname", "head", "sort", "wc"].map { "Bash(\($0):*)" }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = workDir
        process.arguments = [
            "-p", brief,
            "--output-format", "json",
            "--json-schema", Self.schema,
            "--append-system-prompt", Self.systemPrompt,
            "--tools", "Bash",
            "--allowedTools", readOnly.joined(separator: " "),
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--setting-sources", "",
            "--disable-slash-commands",
            "--model", "sonnet",
            "--max-budget-usd", "0.50",
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:\(NSHomeDirectory())/.local/bin"
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { try process.run() } catch {
                    continuation.resume(throwing: AgentError.failed("Couldn't start Claude Code: \(error.localizedDescription)"))
                    return
                }
                started(process)
                var timedOut = false
                let killer = DispatchWorkItem { if process.isRunning { timedOut = true; process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                if timedOut { continuation.resume(throwing: AgentError.timedOut); return }
                continuation.resume(with: Result { try Self.parse(data) })
            }
        }
    }

    nonisolated static func parse(_ data: Data) throws -> SystemFixPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.failed("The agent gave no answer (it may have been stopped or you may need to sign in to Claude Code).")
        }
        if (root["is_error"] as? Bool) == true {
            let why = (root["errors"] as? [String])?.first ?? (root["result"] as? String) ?? "unknown error"
            throw AgentError.failed("The agent stopped: \(why)")
        }
        guard let structured = root["structured_output"],
              let plain = try? JSONSerialization.data(withJSONObject: structured),
              let plan = try? JSONDecoder().decode(SystemFixPlan.self, from: plain)
        else { throw AgentError.failed("The agent's answer wasn't in the expected shape.") }
        return plan
    }
}
