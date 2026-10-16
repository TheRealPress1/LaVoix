import Foundation

/// `LAVOIX_CAPTURE_TARGET_AUTOTEST=1`: which app a recording captures. Regression for a calendar-started Google Meet call
/// in Brave that captured a nameless system process and recorded silence for the whole meeting.
enum MeetingCaptureTargetAutotest {
    @MainActor static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_CAPTURE_TARGET_AUTOTEST"] == "1" else { return }
        var failures = 0
        func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
        func app(_ id: String, _ name: String) -> MeetingApplicationIdentity { MeetingApplicationIdentity(bundleIdentifier: id, displayName: name) }
        func resolve(_ apps: [MeetingApplicationIdentity], _ preferred: String?) -> String? {
            try? MeetingCaptureSourceCatalog.resolveApplication(from: apps, preferredBundleIdentifier: preferred, requirePreferredApplication: false).bundleIdentifier
        }
        let system = app("", "") // the nameless process that used to be picked
        let finder = app("com.apple.finder", "Finder")
        let brave = app("com.brave.Browser", "Brave Browser")
        let chrome = app("com.google.Chrome", "Chrome")
        let zoom = app("us.zoom.xos", "Zoom")

        check("a preferred app wins", resolve([system, finder, brave, zoom], "com.brave.Browser") == "com.brave.Browser")
        check("Brave is found even when it is not preferred and not in the old fallback list", resolve([system, finder, brave], nil) == "com.brave.Browser")
        check("the old fallbacks still work", resolve([finder, chrome], nil) == "com.google.Chrome" && resolve([chrome, zoom], nil) == "us.zoom.xos")
        check("a nameless system process is never chosen", resolve([system], nil) == nil)
        check("with only unrelated apps it fails instead of recording a random one", resolve([system, finder], nil) == nil)
        check("an absent preferred app falls back to another call app", resolve([finder, brave], "us.zoom.xos") == "com.brave.Browser")
        check("Safari counts as a browser", resolve([finder, app("com.apple.Safari", "Safari")], nil) == "com.apple.Safari")
        check("Zoom and Teams links map to their apps", NotchMeetingCardController.likelyCallApp(for: URL(string: "https://us02web.zoom.us/j/123")) == "us.zoom.xos"
            && NotchMeetingCardController.likelyCallApp(for: URL(string: "https://teams.microsoft.com/l/meetup-join/x")) == "com.microsoft.teams2")
        check("an online call with a remote voice still requires echo protection", MeetingProcessingPipeline.microphoneNeedsEchoProtection(mode: .onlineCall, remoteSpeechHeard: true))
        check("an online call where no remote voice was ever heard admits the microphone", !MeetingProcessingPipeline.microphoneNeedsEchoProtection(mode: .onlineCall, remoteSpeechHeard: false))
        check("an in-room meeting never needed it", !MeetingProcessingPipeline.microphoneNeedsEchoProtection(mode: .inRoom, remoteSpeechHeard: true))
        let html = #"<ul><li><p>10:00 AM - Culture Interview </p><ul><li><p>Jane Testperson (GTM Recruiter, <a target="_blank" href="https://www.linkedin.com/in/janetest" rel="noopener ">LinkedIn</a>)</p></li></ul></li></ul>"#
        let found = MeetingAttendees.peopleFromDescription(html)
        check("a person listed in an event description is found with role and LinkedIn", found.count == 1 && found[0].name == "Jane Testperson" && found[0].role == "GTM Recruiter" && found[0].linkedin == "https://www.linkedin.com/in/janetest")
        check("plain text with a LinkedIn address works too", MeetingAttendees.peopleFromDescription("Bob Example (Engineer, https://www.linkedin.com/in/bobex)").first?.linkedin == "https://www.linkedin.com/in/bobex")
        check("ordinary description text is not mistaken for a person", MeetingAttendees.peopleFromDescription("Join the call (see the link). Meeting ID: 123 (desktop) Passcode (dial-in)").isEmpty)
        print(failures == 0 ? "CAPTURE TARGET AUTOTEST ALL PASSED" : "CAPTURE TARGET AUTOTEST \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
