import Darwin
import Foundation

// One shell on a pseudo-terminal, for the notch terminal (docs/21-notch-terminal.md). It is started so that it does NOT inherit the engine's access:
//  - the engine gives up its "responsibility" for the child (responsibility_spawnattrs_setdisclaim), so the shell has no Full Disk Access, Accessibility
//    or Screen Recording of its own (spike 1: a disclaimed shell was denied Apple's protected folders, a normal one was not). If that is not available the
//    terminal refuses to start; there is no fallback to a normal spawn.
//  - nothing else is inherited either: POSIX_SPAWN_CLOEXEC_DEFAULT closes every descriptor (so the engine socket cannot leak in), and the environment is the
//    short list `TerminalGuard.environment` builds.
// macOS's posix_spawn gives a SETSID child no controlling terminal, so the shell is started through Apple's own perl (already used by the engine for Now Playing),
// which takes the terminal as its controlling terminal and then becomes the shell. Nothing new is shipped or signed.
// Never logged: commands, output, directories. Only that a session started or ended, and its exit status.

nonisolated final class TerminalSession: @unchecked Sendable {
    struct Config {
        var shell: String
        var arguments: [String] = ["-i"]
        var directory: String
        var environment: [String]
        var columns = 100
        var rows = 14
        var launcher = "/usr/bin/perl"
    }

    enum StartError: Error, LocalizedError {
        case disclaimUnavailable
        case launcherMissing
        case terminalUnavailable
        case spawnFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .disclaimUnavailable: "This macOS does not offer the way to start the shell without the engine's permissions, so the terminal will not start."
            case .launcherMissing: "The system perl that starts the shell is missing."
            case .terminalUnavailable: "A pseudo-terminal could not be opened."
            case let .spawnFailed(code): "The shell could not be started (error \(code))."
            }
        }
    }

    let pid: pid_t
    private let queue = DispatchQueue(label: "com.myos.terminal.io")
    private var master: Int32
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var busyTimer: DispatchSourceTimer?
    private var closed = false
    /// Set once the shell has been waited for: its process id may be reused after that, so nothing is ever signalled again.
    private var reaped = false
    private var lastBusy = false
    private let onOutput: @Sendable (Data) -> Void
    private let onBusyChanged: @Sendable (Bool) -> Void
    private let onExit: @Sendable (Int32) -> Void

    /// Takes the terminal as its controlling terminal (0x20007461 is TIOCSCTTY), moves to the folder, then becomes the login shell ("-zsh").
    private static let launcherScript = #"""
    use POSIX ();
    POSIX::setsid();
    open(my $t, '+<', $ARGV[0]) or exit 65;
    ioctl($t, 0x20007461, 0);
    chdir($ARGV[1]) or chdir($ENV{HOME});
    my $fd = fileno($t);
    POSIX::dup2($fd, 0); POSIX::dup2($fd, 1); POSIX::dup2($fd, 2);
    close($t) if $fd > 2;
    my ($sh, @a) = @ARGV[2..$#ARGV];
    (my $b = $sh) =~ s{.*/}{};
    exec { $sh } ('-' . $b, @a);
    exit 67;
    """#

    private typealias DisclaimFunction = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static func disclaimFunction() -> DisclaimFunction? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: DisclaimFunction.self)
    }

    /// True when this macOS can start a shell without the engine's permissions.
    static var canStartSafely: Bool { self.disclaimFunction() != nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/perl") }

    static func start(
        _ config: Config,
        onOutput: @escaping @Sendable (Data) -> Void,
        onBusyChanged: @escaping @Sendable (Bool) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> TerminalSession {
        guard let disclaim = self.disclaimFunction() else { throw StartError.disclaimUnavailable }
        guard FileManager.default.isExecutableFile(atPath: config.launcher) else { throw StartError.launcherMissing }

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            if master >= 0 { close(master) }
            throw StartError.terminalUnavailable
        }
        let slavePath = String(cString: name)
        var size = winsize(ws_row: UInt16(config.rows), ws_col: UInt16(config.columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(master, TIOCSWINSZ, $0) }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)       // no other process the engine starts may inherit the master side
        _ = fcntl(master, F_SETFL, O_NONBLOCK)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(0x4000))      // POSIX_SPAWN_CLOEXEC_DEFAULT: close every descriptor in the child
        guard disclaim(&attributes, 1) == 0 else { close(master); throw StartError.disclaimUnavailable }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        let arguments = ["perl", "-e", Self.launcherScript, slavePath, config.directory, config.shell] + config.arguments
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = config.environment.map { strdup($0) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, config.launcher, &actions, &attributes, argv, envp)
        guard result == 0 else { close(master); throw StartError.spawnFailed(result) }

        let session = TerminalSession(pid: pid, master: master, onOutput: onOutput, onBusyChanged: onBusyChanged, onExit: onExit)
        session.beginWatching()
        return session
    }

    private init(pid: pid_t, master: Int32, onOutput: @escaping @Sendable (Data) -> Void, onBusyChanged: @escaping @Sendable (Bool) -> Void, onExit: @escaping @Sendable (Int32) -> Void) {
        self.pid = pid
        self.master = master
        self.onOutput = onOutput
        self.onBusyChanged = onBusyChanged
        self.onExit = onExit
    }

    // MARK: - watching

    private func beginWatching() {
        let fd = self.master
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { close(fd) }
        self.readSource = reader
        reader.resume()

        let exit = DispatchSource.makeProcessSource(identifier: self.pid, eventMask: .exit, queue: self.queue)
        exit.setEventHandler { [weak self] in self?.reap() }
        self.exitSource = exit
        exit.resume()

        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.checkBusy() }
        self.busyTimer = timer
        timer.resume()
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !self.closed {
            let count = read(self.master, &buffer, buffer.count)
            if count > 0 { self.onOutput(Data(buffer[0 ..< count])) } else { break }
        }
    }

    private func reap() {
        var status: Int32 = 0
        waitpid(self.pid, &status, 0)
        self.reaped = true
        let code: Int32 = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        self.drain()
        self.finish()
        self.exitSource?.cancel()
        self.exitSource = nil
        self.onExit(code)
    }

    /// The foreground process group of the shell's terminal differs from the shell's own while a command runs (read the way `ps -o tpgid` does).
    static func groups(of pid: pid_t) -> (shell: pid_t, foreground: pid_t)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &length, nil, 0) == 0, length > 0 else { return nil }
        return (info.kp_eproc.e_pgid, info.kp_eproc.e_tpgid)
    }

    private func checkBusy() {
        guard !self.closed, let groups = Self.groups(of: self.pid) else { return }
        let busy = groups.foreground != 0 && groups.foreground != groups.shell
        if busy != self.lastBusy {
            self.lastBusy = busy
            self.onBusyChanged(busy)
        }
    }

    private func finish() {
        guard !self.closed else { return }
        self.closed = true
        self.busyTimer?.cancel()
        self.busyTimer = nil
        self.readSource?.cancel()          // its cancel handler closes the master, which hangs the terminal up
        self.readSource = nil
        if self.lastBusy { self.lastBusy = false; self.onBusyChanged(false) }
    }

    // MARK: - what the person can do

    /// Sends text to the shell, as if typed.
    func send(_ text: String) {
        let bytes = Array(text.utf8)
        self.queue.async { [weak self] in
            guard let self, !self.closed else { return }
            var offset = 0
            var stalls = 0
            while offset < bytes.count && stalls < 400 {
                let written = bytes.withUnsafeBytes { write(self.master, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if written > 0 { offset += written; stalls = 0 } else if written < 0, errno == EAGAIN || errno == EINTR { stalls += 1; usleep(5000) } else { break }
            }
        }
    }

    /// Ctrl-C: the terminal sends the interrupt to whatever runs in the foreground.
    func interrupt() { self.send("\u{03}") }

    /// For a command that ignores Ctrl-C: kills the foreground group (never the shell itself).
    func forceStopForeground() {
        self.queue.async { [weak self] in
            guard let self, !self.closed, !self.reaped, let groups = Self.groups(of: self.pid), groups.foreground > 0, groups.foreground != groups.shell else { return }
            killpg(groups.foreground, SIGKILL)
        }
    }

    func resize(columns: Int, rows: Int) {
        self.queue.async { [weak self] in
            guard let self, !self.closed else { return }
            var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(20, columns)), ws_xpixel: 0, ws_ypixel: 0)
            _ = withUnsafeMutablePointer(to: &size) { ioctl(self.master, TIOCSWINSZ, $0) }
        }
    }

    /// Ends the session: closing the terminal hangs the shell up; whatever is still alive a moment later is killed.
    func terminate() {
        self.queue.async { [weak self] in
            guard let self else { return }
            let foreground = Self.groups(of: self.pid)?.foreground ?? 0
            self.finish()
            let pid = self.pid
            self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.reaped else { return }
                if foreground > 1 { killpg(foreground, SIGKILL) }
                killpg(pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }
    }
}
