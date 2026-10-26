import Foundation

@main
enum ConnectionWatchTests {
    static func check(_ ok: Bool, _ what: String) {
        if !ok { print("FAIL: \(what)"); exit(1) }
        print("PASS: \(what)")
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

        var w = ConnectionWatch()
        check(w.succeeded() == .none, "a working connection says nothing")
        check(w.failed(now: at(0)) == .none && w.failed(now: at(5)) == .none, "one or two failures are ignored")
        check(w.failed(now: at(10)) == .recheck, "the third failure in a row asks the system again")
        check(w.failed(now: at(15)) == .none, "the recheck is made once")
        check(w.failed(now: at(61)) == .alert, "a minute of failures alerts the user")
        check(w.failed(now: at(80)) == .none, "the alert is made once")
        check(w.failed(now: at(151)) == .restart, "two and a half minutes restarts the app")
        check(w.failed(now: at(160)) == .none, "the restart is asked once")
        check(w.succeeded() == .recovered, "working again after an alert says so")
        check(w.succeeded() == .none, "and only once")

        // dictating: no restart, but the alert still goes out
        var busy = ConnectionWatch()
        _ = busy.failed(now: at(0), busy: true)
        check(busy.failed(now: at(70), busy: true) == .alert, "alert while dictating")
        check(busy.failed(now: at(200), busy: true) != .restart, "no restart while dictating")
        check(busy.failed(now: at(210), busy: false) == .restart, "restart once dictation is over")

        // a restart that did not help is reported, not repeated
        var again = ConnectionWatch()
        again.lastRestart = at(-100)
        _ = again.failed(now: at(0))
        check(again.failed(now: at(61)) == .stillBroken, "after a restart that did not help, say it is still broken")
        check(again.failed(now: at(400)) != .restart, "and never restart again inside the cooldown")
        var later = ConnectionWatch()
        later.lastRestart = at(-(31 * 60))
        _ = later.failed(now: at(0))
        check(later.failed(now: at(151)) == .restart, "after the cooldown a restart is allowed again")

        // a blip that heals never alerts
        var blip = ConnectionWatch()
        _ = blip.failed(now: at(0)); _ = blip.failed(now: at(1)); _ = blip.failed(now: at(2))
        check(blip.succeeded() == .none, "a blip that heals before the alert says nothing")
        print("ALL PASS")
    }
}
