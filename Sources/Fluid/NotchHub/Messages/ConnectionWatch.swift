import Foundation

/// Decides what to do when reads of a connection (the Messages database) keep failing. Pure logic: it is told about each success and failure
/// and answers with the next step, so it can be tested without a database, a clock or a notch.
///
/// The steps, in order, for one unbroken run of failures:
///  1. `recheck`   after a few failures in a row: ask the system again whether access is still granted (this also flips the screen from an
///                 endless spinner to the "needs Full Disk Access" card when it was taken away).
///  2. `alert`     once it has been failing for `alertAfter` seconds: tell the user it broke, whatever the cause.
///  3. `restart`   once it has been failing for `restartAfter` seconds: relaunch the app, which cures a process the system stopped trusting
///                 (a restart cured the 26 October break). At most once per `restartCooldown`, and never while dictating.
///  4. `stillBroken` after a restart that did not help: say so plainly and stop restarting; the user has to act.
/// When a read works again after an alert, `recovered` says so.
struct ConnectionWatch {
    enum Step: Equatable {
        case none
        case recheck
        case alert
        case restart
        case stillBroken
        case recovered
    }

    var recheckAfterFailures = 3
    var alertAfter: TimeInterval = 60
    var restartAfter: TimeInterval = 150
    var restartCooldown: TimeInterval = 30 * 60

    private var failingSince: Date?
    private var failures = 0
    private var rechecked = false
    private var alerted = false
    private var restarted = false
    private var told = false
    /// When the app last restarted itself for this connection (kept across launches by the caller).
    var lastRestart: Date?

    var isFailing: Bool { self.failingSince != nil }

    mutating func succeeded() -> Step {
        let wasAlerted = self.alerted
        self.failingSince = nil
        self.failures = 0
        self.rechecked = false
        self.alerted = false
        self.restarted = false
        self.told = false
        return wasAlerted ? .recovered : .none
    }

    /// `busy`: the user is dictating or recording, so the app must not relaunch itself now.
    mutating func failed(now: Date, busy: Bool = false) -> Step {
        if self.failingSince == nil { self.failingSince = now }
        self.failures += 1
        let elapsed = now.timeIntervalSince(self.failingSince ?? now)
        let recentlyRestarted = self.lastRestart.map { now.timeIntervalSince($0) < self.restartCooldown } ?? false
        // A restart a moment ago that did not cure it: say so once, and do not try again until the cooldown is over.
        if recentlyRestarted, elapsed >= self.alertAfter, !self.told {
            self.told = true
            self.alerted = true
            return .stillBroken
        }
        if elapsed >= self.restartAfter, !self.restarted, !recentlyRestarted, !busy {
            self.restarted = true
            return .restart
        }
        if elapsed >= self.alertAfter, !self.alerted {
            self.alerted = true
            return .alert
        }
        if self.failures >= self.recheckAfterFailures, !self.rechecked {
            self.rechecked = true
            return .recheck
        }
        return .none
    }
}
