import Foundation

/// What the card under the notch tells the person while a meeting is being recorded and something is wrong with what is being captured.
/// A 76 minute Safari call recorded on 2026-11-06 had a silent call-audio track and an unprotected microphone from the first minute and
/// nothing said so until the transcript came out empty. Pure rules, no UI, so they can be tested without a recording.
nonisolated struct MeetingCaptureWarning: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case callAudioSilent
        case microphoneUnprotected
        case callAudioSilentAndMicrophoneUnprotected
    }

    var kind: Kind
    var text: String
}

nonisolated enum MeetingCaptureWatch {
    /// The call's sound has been missing this long (continuous digital silence on the call-audio track).
    static let callAudioSilenceSeconds: TimeInterval = 60
    /// The microphone has been without echo protection this long. Short: the echo canceller needs a few seconds to settle after the start.
    static let unprotectedMicrophoneSeconds: TimeInterval = 30

    /// `callAudioSilentFor` is the call-audio track's current run of silence; `microphoneUnprotectedFor` is how long the microphone has been
    /// without echo protection (nil while protected or unknown). Only online calls are judged: an in-room meeting has no call audio.
    static func evaluate(
        mode: MeetingCaptureMode,
        callAudioSilentFor: TimeInterval?,
        microphoneUnprotectedFor: TimeInterval?
    ) -> MeetingCaptureWarning? {
        guard mode == .onlineCall else { return nil }
        let silent = (callAudioSilentFor ?? 0) >= self.callAudioSilenceSeconds
        let unprotected = (microphoneUnprotectedFor ?? 0) >= self.unprotectedMicrophoneSeconds
        switch (silent, unprotected) {
        case (true, true):
            return MeetingCaptureWarning(
                kind: .callAudioSilentAndMicrophoneUnprotected,
                text: "No sound from the call, and the microphone is not echo-protected. The transcript will use the microphone alone."
            )
        case (true, false):
            return MeetingCaptureWarning(
                kind: .callAudioSilent,
                text: "No sound from the call for \(self.spoken(callAudioSilentFor ?? 0)). If you can hear them, myOS is not receiving it."
            )
        case (false, true):
            return MeetingCaptureWarning(
                kind: .microphoneUnprotected,
                text: "The microphone is not echo-protected, so its words may be left out of the transcript."
            )
        case (false, false):
            return nil
        }
    }

    /// "a minute", "3 minutes".
    static func spoken(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.down))
        return minutes <= 1 ? "a minute" : "\(minutes) minutes"
    }
}

/// The small card row under the notch while a meeting records: a sentence, an optional "stop the recording" button, and a dismiss button.
nonisolated struct MeetingNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case captureWarning(MeetingCaptureWarning.Kind)
        case callEnded
        case dictationBlocked
    }

    var kind: Kind
    var text: String
    /// Title of the button that stops the recording; nil when the notice only informs.
    var stopTitle: String?
    var dismissTitle: String

    static func captureWarning(_ warning: MeetingCaptureWarning) -> MeetingNotice {
        MeetingNotice(kind: .captureWarning(warning.kind), text: warning.text, stopTitle: nil, dismissTitle: "OK")
    }

    /// The call's window or its audio went away while the recording kept running.
    static let callEnded = MeetingNotice(
        kind: .callEnded,
        text: "The call looks over, but the recording is still running. Stop recording?",
        stopTitle: "Stop recording",
        dismissTitle: "Keep recording"
    )

    /// A dictation key press was refused because a meeting holds the microphone and the speech model. While it is still being recorded the
    /// person can stop it right here; once it is only being transcribed there is nothing to stop, only to wait for.
    static func dictationBlocked(meetingIsRecording: Bool) -> MeetingNotice {
        meetingIsRecording
            ? MeetingNotice(
                kind: .dictationBlocked,
                text: "Dictation is paused because a meeting is being recorded. Stop the meeting recording?",
                stopTitle: "Stop the recording",
                dismissTitle: "Keep recording"
            )
            : MeetingNotice(
                kind: .dictationBlocked,
                text: "Dictation is paused while the meeting is transcribed. It starts working again when that finishes.",
                stopTitle: nil,
                dismissTitle: "OK"
            )
    }
}

/// How long the microphone has been without echo protection, from a once-a-few-seconds sample of its current protection.
nonisolated struct MeetingUnprotectedMicrophoneClock: Equatable, Sendable {
    private(set) var since: Date?

    /// Feed the latest sample; returns the length of the current unprotected run (nil while protected or unknown).
    mutating func observe(_ protection: MeetingMicrophoneEchoProtection?, at now: Date) -> TimeInterval? {
        guard let protection else {
            self.since = nil
            return nil
        }
        if protection == .unprotected {
            if self.since == nil { self.since = now }
            return now.timeIntervalSince(self.since ?? now)
        }
        self.since = nil
        return nil
    }
}
