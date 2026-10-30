import Foundation

/// Detection tier for a registry app. Tier 1 (native) is default-on; Tier 2 (browser) is an
/// opt-in sub-toggle because it reads the frontmost tab's URL.
nonisolated enum MeetingDetectionTier: Sendable, Equatable {
    case nativeTier1
    case browserTier2
}

/// Static, data-driven table of the apps the auto-detector watches. Every ambiguity resolves to
/// "not in the registry" — Slack, Discord and generic browsers-without-a-known-meeting-URL are
/// deliberately absent (see Phase A plan: dropped from v1). FaceTime was added later, once a probe of a
/// real call showed how its audio is attributed (see `faceTimeAudioHelperPath`).
nonisolated enum MeetingAppRegistry {
    /// Bundle identifiers for native meeting apps (Tier 1). Includes legacy Teams alongside the
    /// current "new Teams" bundle since both ship in the wild.
    static let nativeBundleIdentifiers: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.cisco.webexmeetingsapp",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]

    static let faceTimeBundleIdentifier = "com.apple.FaceTime"
    /// FaceTime does not hold the microphone itself. In a probe of a real call (2026-10-29) the FaceTime app had only audio OUTPUT running, while
    /// the system helper `avconferenced` had both input and output running. While FaceTime is running, that helper's audio is FaceTime's.
    static let faceTimeAudioHelperPath = "/usr/libexec/avconferenced"

    /// That same helper plays the other person's voice, so the FaceTime app's own audio is silent (measured 2026-10-29: digital silence for a whole
    /// call), and ScreenCaptureKit's whole-Mac sound does not carry the voice either. A Core Audio tap on the helper does (measured on a live call).
    /// The microphone is then held in voice-processing mode by the helper, so ours has to join it. The call window only marks when the call ends.
    static func callAudioComesFromSystemHelper(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        if bundleIdentifier == self.faceTimeBundleIdentifier { return true }
        // FaceTime quits itself when there is no call to show, so a test cannot record it. A diagnostic run may name a stand-in app.
        let environment = ProcessInfo.processInfo.environment
        return environment["LAVOIX_FACETIME_CAPTURE_AUTOTEST"] != nil && environment["LAVOIX_FACETIME_STANDIN_BUNDLE"] == bundleIdentifier
    }

    /// Bundle identifiers for browsers eligible for Tier 2 URL reading. Google Meet's "app" is a
    /// Chrome/Edge PWA, not a separate bundle — it is matched via `pwaBundlePrefixes` instead.
    static let browserBundleIdentifiers: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "com.brave.Browser",
    ]

    /// PWA windows report a per-app bundle ID with one of these prefixes. Firefox has no PWA
    /// mechanism comparable to this and is excluded from the registry entirely (its AX tree must
    /// be force-enabled by the user, so it fails closed anyway).
    static let pwaBundlePrefixes: [String] = [
        "com.google.Chrome.app.",
        "com.microsoft.edgemac.app.",
    ]

    static func tier(forBundleIdentifier bundleIdentifier: String) -> MeetingDetectionTier? {
        if self.nativeBundleIdentifiers.contains(bundleIdentifier) {
            return .nativeTier1
        }
        if self.browserBundleIdentifiers.contains(bundleIdentifier) {
            return .browserTier2
        }
        if self.pwaBundlePrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
            return .browserTier2
        }
        return nil
    }

    static func isNativeMeetingApp(bundleIdentifier: String) -> Bool {
        self.tier(forBundleIdentifier: bundleIdentifier) == .nativeTier1
    }

    static func isBrowserApp(bundleIdentifier: String) -> Bool {
        self.tier(forBundleIdentifier: bundleIdentifier) == .browserTier2
    }

    private static let zoomMeetingTitles: Set<String> = [
        // en
        "Zoom", "Zoom Meeting", "Zoom Webinar",
        // es
        "Reunión de Zoom", "Seminario web de Zoom",
        // fr
        "Réunion Zoom", "Webinaire Zoom",
        // de
        "Zoom-Meeting", "Zoom-Webinar",
        // pt
        "Reunião do Zoom", "Webinar do Zoom",
        // ja
        "Zoom ミーティング", "Zoom ウェビナー",
    ]

    private static let zoomNonMeetingWindowTitles: Set<String> = [
        "", "Zoom Workplace", "Zoom Client Healthcheck",
    ]

    static func isZoomMeetingWindowTitle(_ title: String) -> Bool {
        guard !self.zoomNonMeetingWindowTitles.contains(title) else { return false }
        return self.zoomMeetingTitles.contains(title)
    }
}

/// Pure hostname+path matching for Tier 2 in-call URLs. Homepage/landing/post-call URLs never
/// match — a parked meeting tab must not, by itself, ever produce a prompt.
nonisolated enum MeetingInCallURLMatcher {
    static func isInCallURL(host: String, path: String) -> Bool {
        let host = host.lowercased()
        switch true {
        case host == "meet.google.com":
            return self.matchesGoogleMeetPath(path)
        case host.hasSuffix(".zoom.us") || host == "zoom.us":
            return self.matchesZoomPath(path)
        case host == "teams.microsoft.com" || host == "teams.live.com":
            return self.matchesTeamsPath(path)
        case host == "whereby.com" || host == "www.whereby.com":
            return self.matchesRoomPath(path, excluding: Self.wherebyReservedPaths)
        case host == "meet.jit.si":
            return self.matchesRoomPath(path, excluding: Self.jitsiReservedPaths)
        default:
            return false
        }
    }

    /// `/xxx-yyyy-zzz` — a lowercase-letter room code, three groups separated by hyphens.
    private static func matchesGoogleMeetPath(_ path: String) -> Bool {
        let segment = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = segment.split(separator: "-")
        guard parts.count == 3 else { return false }
        let lengths = parts.map(\.count)
        guard lengths == [3, 4, 3] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isLowercaseASCIILetter) }
    }

    private static func matchesZoomPath(_ path: String) -> Bool {
        path.hasPrefix("/j/") || path.hasPrefix("/wc/")
    }

    private static func matchesTeamsPath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.contains("meetup-join") || lowered.contains("prejoin") || lowered.contains("pre-join")
    }

    private static let wherebyReservedPaths: Set<String> = ["", "login", "signup", "pricing", "help", "download", "about"]
    private static let jitsiReservedPaths: Set<String> = ["", "login", "signup", "pricing", "help", "static"]

    private static func matchesRoomPath(_ path: String, excluding reserved: Set<String>) -> Bool {
        let segment = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !segment.isEmpty, !segment.contains("/") else { return false }
        return !reserved.contains(segment)
    }
}

private extension Character {
    var isLowercaseASCIILetter: Bool {
        ("a"..."z").contains(self)
    }
}
