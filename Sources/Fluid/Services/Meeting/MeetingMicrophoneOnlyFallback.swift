import Foundation

/// Never discard the only speech source.
///
/// The transcript backend refuses a microphone it cannot prove is free of the call's own echo (an `unprotected` or unclassified capture era
/// in an online call) because, with the call audio recorded on its own track, the microphone would otherwise repeat the other side. That rule
/// is right while the call audio track carries sound. When it does NOT, the microphone is all there is: a 76 minute Safari call recorded on
/// 2026-11-06 had a call-audio track of digital silence (Safari plays through a separate WebKit process that ScreenCaptureKit does not
/// attribute to the app) and a microphone that stayed `unprotected` (the echo canceller had no reference to learn from), so every second of
/// real speech was excluded and the transcript came out with 0 words.
///
/// In that case the microphone is transcribed as room audio: the same treatment an in-room meeting gets, with no echo-suppression against a
/// call track that has nothing in it. The saved session is not rewritten; only the processing run sees the room-audio mode, the result
/// manifest records it, and the session gets an event that says why.
nonisolated enum MeetingMicrophoneOnlyFallback {
    /// A call-audio track counts as silent when it has been below the silence threshold for at least this share of its recorded length.
    static let silentShare = 0.9
    /// Below this length a silent call track says nothing (a recording that was only just started).
    static let minimumSilentSeconds: TimeInterval = 30

    /// The wording shown in the session's events and in the empty-transcript explanation.
    static let eventDetail = "The call audio was silent for this recording, so the transcript comes from the microphone only (treated as room audio). "
        + "Both voices are in one track and speaker labels are automatic."

    /// Recorded length of one track, from its chunk presentation times.
    static func recordedSeconds(of track: MeetingAudioTrack) -> TimeInterval {
        let finalized = track.chunks.filter { $0.byteCount > 0 }
        guard let first = finalized.map(\.presentationStart.seconds).min(),
              let last = finalized.map(\.presentationEnd.seconds).max(),
              last > first
        else { return 0 }
        return last - first
    }

    /// True when the call's own sound was not recorded: there is no call-audio track, or it was below the silence threshold for nearly all of
    /// its length. Unknown health is NOT silence (the fallback never fires on a guess).
    static func callAudioWasSilent(in session: MeetingSession) -> Bool {
        guard let application = session.audioTracks.first(where: { $0.kind == .applicationAudio }) else { return true }
        let recorded = self.recordedSeconds(of: application)
        guard recorded >= self.minimumSilentSeconds else { return false }
        guard let silentFor = application.health.silentForSeconds else { return false }
        return silentFor >= recorded * self.silentShare
    }

    /// True when the transcript backend would exclude some of the microphone under the online-call rule.
    static func microphoneWouldBeExcluded(in session: MeetingSession) -> Bool {
        guard let microphone = session.audioTracks.first(where: { $0.kind == .microphone }),
              microphone.chunks.contains(where: { $0.byteCount > 0 })
        else { return false }
        let eras = microphone.captureEras ?? []
        if eras.isEmpty {
            return MeetingCanonicalAdmission.rationale(captureMode: .onlineCall, trackKind: .microphone, echoProtection: nil).decision == .inadmissible
        }
        return eras.contains {
            MeetingCanonicalAdmission.rationale(captureMode: .onlineCall, trackKind: .microphone, echoProtection: $0.echoProtection).decision == .inadmissible
        }
    }

    /// The fallback applies to an online call whose call audio was silent and whose microphone would otherwise be refused.
    static func applies(to session: MeetingSession) -> Bool {
        session.mode == .onlineCall
            && self.microphoneWouldBeExcluded(in: session)
            && self.callAudioWasSilent(in: session)
    }

    /// The session the processing run should use, and the reason when it differs from the saved one.
    static func effectiveSession(for session: MeetingSession) -> (session: MeetingSession, reason: String?) {
        guard self.applies(to: session) else { return (session, nil) }
        var adjusted = session
        adjusted.mode = .inRoom
        return (adjusted, self.eventDetail)
    }

    /// Why a finished transcript has no text, in words for the person: what the session recorded, never its content. Nil when nothing explains it.
    static func emptyTranscriptReason(for session: MeetingSession) -> String? {
        if session.events.contains(where: { $0.kind == .microphoneOnlyTranscript }) {
            return "The call audio was silent, so only the microphone was transcribed (as room audio) and it held no recognizable speech."
        }
        if let incomplete = session.events.last(where: { $0.kind == .transcriptCoverageIncomplete }), let detail = incomplete.detail, !detail.isEmpty {
            let silent = self.callAudioWasSilent(in: session)
                ? " The call audio track was also silent, so nothing from the other side was recorded."
                : ""
            return detail + silent
        }
        if self.callAudioWasSilent(in: session) {
            return "The call audio track was silent, so nothing from the other side was recorded."
        }
        return nil
    }
}
