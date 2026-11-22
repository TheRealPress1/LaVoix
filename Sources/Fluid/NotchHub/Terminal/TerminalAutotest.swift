import AppKit
import Foundation

extension NotchHubDebug {
    /// `LAVOIX_TERMINAL_AUTOTEST=1`: the notch terminal's rules, with invented input only. The output model (what a shell prints), the guard rules (hardware-only keys,
    /// sanitising, the short environment, the lock and its timing), the input field's closed doors, a real shell on a real pseudo-terminal (a round trip, Ctrl-C, busy
    /// detection, no inherited descriptors, no inherited environment, no inherited access to Apple's protected folders), and a scan of the sources that checks nothing
    /// outside the notch can reach the terminal. No Touch ID prompt is shown (a fake stands in) and nothing from the real machine is read.
    @MainActor static func terminalAutotestIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_TERMINAL_AUTOTEST"] == "1" else { return }
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                if !ok { failures += 1 }
                FileHandle.standardOutput.write(Data("\(ok ? "PASS" : "FAIL") \(name)\n".utf8))
            }
            func note(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
            func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { if condition() { return true }; try? await Task.sleep(nanoseconds: 50_000_000) }
                return condition()
            }
            func plain(_ buffer: TerminalBuffer) -> [String] {
                let s = buffer.snapshot()
                return s.lines.map(\.plain) + [s.inProgress?.plain].compactMap { $0 }
            }
            func lines(of text: String, via screen: TerminalScreen = TerminalScreen()) -> [String] {
                screen.feed(Data(text.utf8))
                return screen.lines.map(\.plain)
            }

            // MARK: output model
            check("plain lines come out as lines", lines(of: "hello\nworld\n") == ["hello", "world"])
            check("a carriage return overwrites the line (progress bars)", lines(of: "abc\rXY\n") == ["XYc"])
            check("backspace steps back and the next character overwrites", lines(of: "abc\u{8}\u{8}Z\n") == ["aZc"])
            check("erase to the end of the line after moving back", lines(of: "hello\u{1B}[3D\u{1B}[Kp\n") == ["hep"])
            check("a tab goes to the next multiple of eight", lines(of: "a\tb\n") == ["a       b"])
            let colours = TerminalScreen()
            colours.feed(Data("\u{1B}[31mred\u{1B}[0m plain\u{1B}[1;38;5;196mX\u{1B}[0;38;2;1;2;3mY\n".utf8))
            let cells = colours.lines.first?.cells ?? []
            check("a colour code styles the text and a reset ends it", cells.first?.style.fg == .indexed(1) && cells.dropFirst(3).first?.style == TermStyle())
            check("256 colours, truecolour and bold are understood", cells.contains { $0.ch == "X" && $0.style.fg == .indexed(196) && $0.style.bold } && cells.contains { $0.ch == "Y" && $0.style.fg == .rgb(1, 2, 3) })
            check("a window-title code is dropped, whichever way it ends", lines(of: "\u{1B}]0;title\u{07}ok\n\u{1B}]2;x\u{1B}\\fine\n") == ["ok", "fine"])
            check("a code it does not draw (cursor hide) is dropped", lines(of: "a\u{1B}[?25lb\n") == ["ab"])
            let split = TerminalScreen()
            let accent = Array("é".utf8)
            split.feed(Data([UInt8(ascii: "a")] + accent.prefix(1)))
            split.feed(Data(accent.dropFirst() + [UInt8(ascii: "\n")]))
            check("a character split between two reads is put back together", split.lines.map(\.plain) == ["aé"])
            let flood = TerminalScreen()
            for i in 0 ..< 2300 { flood.feed(Data("line \(i)\n".utf8)) }
            check("only about 2,000 lines are kept, the newest ones", flood.lines.count >= TerminalScreen.maxLines && flood.lines.count <= TerminalScreen.maxLines + 200 && flood.lines.last?.plain == "line 2299")
            let vim = TerminalScreen()
            vim.feed(Data("before\n\u{1B}[?1049h".utf8))
            let inside = vim.usesAlternateScreen
            vim.feed(Data("SCREEN-TAKEOVER\u{1B}[?1049lafter\n".utf8))
            check("a full-screen program is noticed and its drawing is not kept", inside && !vim.usesAlternateScreen && vim.lines.map(\.plain) == ["before", "after"])
            check("clear-screen empties the scrollback", lines(of: "a\nb\n\u{1B}[2Jc\n") == ["c"])
            let long = TerminalScreen()
            long.feed(Data(String(repeating: "x", count: 10_000).utf8))
            check("a line without end is wrapped, not kept growing", long.lines.count >= 2)

            // MARK: guard rules
            check("only an event with source process 0 is hardware", TerminalGuard.isHardware(sourceProcessID: 0) && !TerminalGuard.isHardware(sourceProcessID: 4242))
            let fake = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)
            check("an event with no CGEvent behind it is refused (fail closed)", fake != nil && !TerminalGuard.isHardware(fake!))
            check("escape and control characters are stripped, line breaks unified", TerminalGuard.sanitized("a\u{1B}[201~b\r\nc\u{07}d\re") == "a[201~b\ncd\ne")
            let wrapped = TerminalGuard.unwrapped("aws s3 cp ./build\n  s3://my-bucket/site --recursive")
            check("a copied command wrapped at a word is joined with one space", wrapped.text == "aws s3 cp ./build s3://my-bucket/site --recursive" && wrapped.joined == 1)
            let url = TerminalGuard.unwrapped("curl https://example.com/api/v1/organizations/pa\nrt/of/the/path?x=1&y=2")
            check("a line that ran to the full width and split a long word is joined with no space", url.text == "curl https://example.com/api/v1/organizations/part/of/the/path?x=1&y=2" && url.joined == 1)
            check("a trailing backslash keeps the break (a real continuation)", TerminalGuard.unwrapped("docker run \\\n  -p 80:80 image").text == "docker run \\\n  -p 80:80 image")
            check("a block with a blank line is kept as written", TerminalGuard.unwrapped("cd project\n\nls").text == "cd project\n\nls" && TerminalGuard.unwrapped("cd project\n\nls").joined == 0)
            check("one line, and stray blank lines around it, come out as the line", TerminalGuard.unwrapped("\n  ls -la  \n\n").text == "  ls -la" && TerminalGuard.unwrapped("ls").joined == 0)
            check("a pasted block cannot end the bracketed paste early", !TerminalGuard.wire(for: "x\u{1B}[201~rm\ny").dropFirst(6).dropLast(7).contains("\u{1B}"))
            check("one line goes as itself plus Enter, several as one bracketed paste", TerminalGuard.wire(for: "ls") == "ls\n" && TerminalGuard.wire(for: "a\nb") == "\u{1B}[200~a\nb\u{1B}[201~\n")
            check("sudo and su are refused in command position only", ["sudo ls", "  sudo ls", "ls && sudo rm", "su", "x\nsudo y"].allSatisfy(TerminalGuard.refusesPasswordCommand) && !["echo sudo", "pseudo ls", "git status", "ls sudoers.txt"].contains(where: TerminalGuard.refusesPasswordCommand))
            let env = TerminalGuard.environment(shell: "/bin/zsh", home: "/Users/x", user: "x", parent: ["AWS_SECRET_ACCESS_KEY": "s", "GOOGLE_TOKEN": "t", "LAVOIX_X": "1", "LANG": "fr_FR.UTF-8", "TMPDIR": "/tmp/t/", "SSH_AUTH_SOCK": "/tmp/agent"])
            let keys = Set(env.compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
            check("the shell's environment is a short list, never the engine's", keys == ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "TERM", "LANG", "TMPDIR", "SSH_AUTH_SOCK"] && !env.contains { $0.contains("SECRET") || $0.contains("TOKEN") })
            check("the login shell is a listed, executable shell", FileManager.default.isExecutableFile(atPath: TerminalGuard.loginShell()))
            check("the terminal locks after two closed minutes, not before", !TerminalGuard.shouldAutoLock(closedFor: 119) && TerminalGuard.shouldAutoLock(closedFor: 120))

            // MARK: lock
            struct FakeAuth: TerminalAuthenticating { let result: TerminalAuthResult; func authenticate(reason _: String) async -> TerminalAuthResult { self.result } }
            let locked = TerminalStore(authenticator: FakeAuth(result: .success), startsSessions: false)
            check("it starts locked, and a run while locked is refused", !locked.isUnlocked && locked.submit("echo hi") == false)
            await locked.unlock()
            check("a fingerprint opens it", locked.isUnlocked)
            locked.lock()
            check("locking closes it and clears what is drawn", !locked.isUnlocked && locked.rendered.isEmpty)
            let refused = TerminalStore(authenticator: FakeAuth(result: .failed("no match")), startsSessions: false)
            await refused.unlock()
            let cancelled = TerminalStore(authenticator: FakeAuth(result: .cancelled), startsSessions: false)
            await cancelled.unlock()
            let missing = TerminalStore(authenticator: FakeAuth(result: .unavailable("no sensor")), startsSessions: false)
            await missing.unlock()
            check("a refused, cancelled or impossible fingerprint leaves it locked", !refused.isUnlocked && !cancelled.isUnlocked && !missing.isUnlocked && refused.notice == "no match" && cancelled.notice == nil && missing.notice == "no sensor")

            // MARK: the input field's closed doors
            let field = TerminalInputTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
            var blocked = 0
            field.onBlocked = { blocked += 1 }
            field.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            check("text pushed in by anything but a hardware key is refused", field.string.isEmpty && blocked == 1)
            field.paste(nil)
            check("a paste outside a hardware key is refused", field.string.isEmpty && blocked == 2)
            field.performAsHardwareKey { field.insertText("hi", replacementRange: NSRange(location: 0, length: 0)) }
            check("text typed inside a hardware key goes in", field.string == "hi")
            field.setText("")
            check("the field's own housekeeping still works", field.string.isEmpty)
            if let fake { field.keyDown(with: fake) }
            check("a key event that is not from the hardware is dropped", field.string.isEmpty && blocked == 3)
            check("the field is not an Accessibility element, has no children, no menu", !field.isAccessibilityElement() && (field.accessibilityChildren() ?? []).isEmpty && field.menu(for: fake ?? NSEvent()) == nil)

            let board = NSPasteboard(name: NSPasteboard.Name("lavoix.terminal.autotest"))
            board.clearContents()
            board.setString("aws s3 ls\n  s3://my-bucket", forType: .string)
            field.pasteboard = board
            var joinedBreaks = 0
            field.onPasteJoined = { joinedBreaks = $0 }
            field.paste(nil)
            check("a paste outside a hardware key is refused even with something to paste", field.string.isEmpty)
            field.performAsHardwareKey { field.paste(nil) }
            check("a paste inside a hardware key lands in the field with the wrapped lines joined, and says so", field.string == "aws s3 ls s3://my-bucket" && joinedBreaks == 1)
            field.setText("")
            field.performAsHardwareKey { field.pasteAsWritten() }
            check("Shift-Command-V pastes the block exactly as copied", field.string == "aws s3 ls\n  s3://my-bucket")
            field.setText("")
            let fakeCommandV = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)
            let blockedBefore = blocked
            let swallowed = fakeCommandV.map { field.performKeyEquivalent(with: $0) } ?? false
            check("a Command-V that did not come from the keyboard hardware is swallowed, counted, and pastes nothing", swallowed && blocked == blockedBefore + 1 && field.string.isEmpty)
            board.releaseGlobally()

            // MARK: a real shell on a real pseudo-terminal
            if !TerminalSession.canStartSafely {
                check("this macOS can start a shell without the engine's permissions", false)
            } else {
                final class Box: @unchecked Sendable {
                    private let lock = NSLock()
                    private var _busy = false, _exit: Int32?
                    var busy: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self._busy }
                    var exit: Int32? { self.lock.lock(); defer { self.lock.unlock() }; return self._exit }
                    func set(busy: Bool) { self.lock.lock(); self._busy = busy; self.lock.unlock() }
                    func set(exit code: Int32) { self.lock.lock(); self._exit = code; self.lock.unlock() }
                }
                let home = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-autotest-\(UUID().uuidString)").path
                try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: home) }
                setenv("TERMINAL_TEST_SECRET", "leaked", 1)
                // A stand-in for the engine's socket: a descriptor left open and NOT close-on-exec, at a number nothing else here uses.
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                let marker = fcntl(probe, F_DUPFD, 57)
                close(probe)
                defer { close(marker) }
                check("the marker descriptor stands open in this process", marker >= 57)
                let box = Box()
                let buffer = TerminalBuffer()
                var config = TerminalSession.Config(shell: "/bin/zsh", arguments: ["-f", "-i"], directory: home, environment: TerminalGuard.environment(shell: "/bin/zsh", home: home, user: NSUserName(), parent: ProcessInfo.processInfo.environment))
                config.columns = 100
                do {
                    let session = try TerminalSession.start(config, onOutput: { buffer.feed($0) }, onBusyChanged: { box.set(busy: $0) }, onExit: { box.set(exit: $0) })
                    check("a shell started and printed its prompt", await waitUntil(8) { !plain(buffer).joined().isEmpty })
                    session.send("echo MARK-$((6*7))\n")
                    check("a command ran and its output came back (computed, not just echoed)", await waitUntil(5) { plain(buffer).contains("MARK-42") })
                    session.send("echo \"SECRET-[${TERMINAL_TEST_SECRET}]-END\"\n")
                    check("the engine's own environment did not travel into the shell", await waitUntil(5) { plain(buffer).contains("SECRET-[]-END") })
                    session.send("echo FDS-$(ls /dev/fd | tr '\\n' ' ')-END\n")
                    _ = await waitUntil(5) { plain(buffer).contains { $0.hasPrefix("FDS-") && $0.hasSuffix("-END") } }
                    let fdLine = plain(buffer).first { $0.hasPrefix("FDS-") && $0.hasSuffix("-END") } ?? ""
                    let fds = Set(fdLine.dropFirst(4).dropLast(4).split(separator: " ").compactMap { Int($0) })
                    note("  descriptors the shell's own commands see: \(fds.sorted())")
                    check("no descriptor leaked into the shell (the marker descriptor left open here is not there)", !fds.isEmpty && !fds.contains(Int(marker)))
                    let protected = NSHomeDirectory() + "/Library/Safari"
                    if (try? FileManager.default.contentsOfDirectory(atPath: protected)) != nil {
                        session.send("ls \(protected) >/dev/null 2>&1; echo PERM-$((100+$?))\n")
                        _ = await waitUntil(5) { plain(buffer).contains { $0.hasPrefix("PERM-") } }
                        check("the shell was denied Apple's protected folders the engine itself can read", plain(buffer).contains("PERM-101"))
                    } else {
                        note("SKIP the protected-folder check: this process cannot read the folder either, so a denial would prove nothing")
                    }
                    session.send("sleep 30\n")
                    check("a running command is noticed (busy)", await waitUntil(4) { box.busy })
                    session.interrupt()
                    check("Ctrl-C stops it and the shell is free again", await waitUntil(4) { !box.busy })
                    session.send("echo AFTER-$((1+1))\n")
                    check("the shell answers the next command after the interrupt", await waitUntil(4) { plain(buffer).contains("AFTER-2") })
                    session.send("exit\n")
                    check("'exit' ends the session with status 0", await waitUntil(4) { box.exit == 0 })
                } catch {
                    check("a shell could be started: \(error.localizedDescription)", false)
                }
                // Ending a session that still runs a command.
                let box2 = Box()
                let buffer2 = TerminalBuffer()
                if let session = try? TerminalSession.start(config, onOutput: { buffer2.feed($0) }, onBusyChanged: { box2.set(busy: $0) }, onExit: { box2.set(exit: $0) }) {
                    _ = await waitUntil(8) { !plain(buffer2).joined().isEmpty }
                    session.send("sleep 100\n")
                    _ = await waitUntil(4) { box2.busy }
                    let pid = session.pid
                    session.terminate()
                    check("ending a session ends its shell and the command it ran", await waitUntil(5) { kill(pid, 0) != 0 && box2.exit != nil })
                }

                // The same through the store: Touch ID (fake), a line run, refused sudo, history, lock, shutdown.
                let store = TerminalStore(authenticator: FakeAuth(result: .success), startsSessions: true)
                store.configAdjuster = { var c = $0; c.shell = "/bin/zsh"; c.arguments = ["-f", "-i"]; c.directory = home; c.environment = config.environment; return c }
                await store.unlock()
                check("through the store: unlocking starts a session", store.isUnlocked && store.sessionState == .running)
                _ = await waitUntil(8) { store.rendered.count > 0 }
                let ran = store.submit("echo VIA-STORE-$((3*3))")
                let drawn = await waitUntil(5) { store.rendered.contains { String($0.text.characters) == "VIA-STORE-9" } }
                check("through the store: a line is run and drawn", ran && drawn)
                check("through the store: sudo is refused with a sentence and the line is kept", store.submit("sudo ls") == false && (store.notice ?? "").contains("password"))
                check("through the store: Up recalls the last line, Down comes back to what was being typed", store.historyPrevious(current: "draft") == "echo VIA-STORE-$((3*3))" && store.historyNext() == "draft")
                let pastedWrap = TerminalGuard.unwrapped("echo AA\n  BB-$((6*7))")
                _ = store.submit(pastedWrap.text)
                check("through the store: a wrapped pasted command runs as ONE command", await waitUntil(5) { store.rendered.contains { String($0.text.characters) == "AA BB-42" } })
                store.lock()
                check("through the store: locking blanks the drawing but not the session", store.rendered.isEmpty && store.sessionState == .running)
                store.shutdown()
                check("through the store: shutting down ends the session and forgets the history", store.sessionState == .none && store.historyPrevious(current: "") == nil)
            }

            // MARK: nothing outside the notch can reach it
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("NotchHub/Terminal").path) {
                let tokens = ["TerminalStore", "TerminalSession", "TerminalGuard", "TerminalScreen", "TerminalInputTextView", "TerminalBuffer", "NotchTerminalSettings"]
                let allowedOutside: Set<String> = ["NotchHub/NotchWidget.swift", "NotchHub/NotchHubController.swift", "NotchHub/NotchHubDebug.swift", "UI/SettingsView.swift", "AppDelegate.swift"]
                let bannedInside = ["LLMClient", "LocalCleanup", "EngineSocket", "ConnectionActions", "URLSession", "Analytics", "NSAppleScript", "NSUserAppleScriptTask", "FrenchRequests", "LookEvents"]
                var strays: [String] = [], leaks: [String] = [], opNames: [String] = [], loggedValues: [String] = []
                if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                    for case let url as URL in walker where url.pathExtension == "swift" {
                        let relative = String(url.path.dropFirst(root.path.count + 1))
                        guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                        if relative.hasPrefix("NotchHub/Terminal/") {
                            for token in bannedInside where text.contains(token) && !(relative.hasSuffix("TerminalAutotest.swift")) { leaks.append("\(relative): \(token)") }
                            if !relative.hasSuffix("TerminalAutotest.swift") {
                                for line in text.split(separator: "\n") where line.contains("DebugLogger") && line.contains("\\(") && !line.contains("(exit \\(code))") { loggedValues.append(relative) }
                            }
                        } else {
                            if tokens.contains(where: { text.contains($0) }) && !allowedOutside.contains(relative) { strays.append(relative) }
                            if relative.hasPrefix("Services/EngineSocket/") && (text.contains("\"terminal") || text.contains("Terminal.run") || text.contains("terminal.")) { opNames.append(relative) }
                        }
                    }
                }
                check("only the notch's own wiring mentions the terminal (no assistant, model, socket, Look)", strays.isEmpty)
                if !strays.isEmpty { note("  strays: \(strays)") }
                check("the engine socket has no operation for the terminal", opNames.isEmpty)
                check("the terminal's own files use no network, model, AppleScript or socket code", leaks.isEmpty)
                if !leaks.isEmpty { note("  leaks: \(leaks)") }
                check("the terminal logs no command, output or folder (only that a session started or ended)", loggedValues.isEmpty)
            } else {
                note("SKIP the source scan: the sources are not at \(root.path)")
            }

            note(failures == 0 ? "TERMINAL AUTOTEST ALL PASSED" : "TERMINAL AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
}
