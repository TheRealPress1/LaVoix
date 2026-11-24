import Accelerate
import AVFoundation
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

    /// One-second windows of the call audio whose loudness (RMS) reaches this count as "sound". Measured 2026-11-23: the call track of a call that
    /// worked carried sound in about half of its seconds, the track of a call whose capture failed in about a tenth.
    static let soundWindowRMSdBFS: Float = -50
    /// A call-audio track that carried sound for less than this share of its seconds is treated as missing (see `callAudioWasMostlyAbsent`).
    static let minimumSoundShare = 0.25

    /// The wording for the second trigger: the call audio existed but most of it was never recorded.
    static let mostlyAbsentEventDetail = "Most of the call audio was missing from this recording, so the transcript comes from the microphone only (treated as room audio). "
        + "Both voices are in one track, speaker labels are automatic, and the other side may appear twice where the call audio was recorded."

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
        // A Core Audio tap writes no chunks at all while nothing plays: a call track with no audio, beside a microphone recorded for long enough, is silent.
        if !application.chunks.contains(where: { $0.byteCount > 0 }) {
            let microphone = session.audioTracks.first(where: { $0.kind == .microphone })
            return (microphone.map { self.recordedSeconds(of: $0) } ?? 0) >= self.minimumSilentSeconds
        }
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

    /// Share of one-second windows of a track's saved audio that carried sound (RMS at or above `soundWindowRMSdBFS` on any channel). Nil when any
    /// chunk file cannot be read: unknown is NOT absence, so the fallback never fires on a guess. Reads the files, so call it off the main actor.
    nonisolated static func soundShare(of track: MeetingAudioTrack, in directory: URL) -> Double? {
        var total = 0
        var loud = 0
        for chunk in track.chunks where chunk.finalizationState != .failed && chunk.byteCount > 0 {
            let relative = chunk.captureAnalysisAsset?.relativeFilePath ?? chunk.relativeFilePath
            guard let counted = self.soundWindows(in: directory.appendingPathComponent(relative)) else { return nil }
            total += counted.total
            loud += counted.loud
        }
        guard total > 0 else { return nil }
        return Double(loud) / Double(total)
    }

    private nonisolated static func soundWindows(in url: URL) -> (total: Int, loud: Int)? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let framesPerWindow = Int(format.sampleRate)
        guard framesPerWindow > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(framesPerWindow))
        else { return nil }
        let threshold = powf(10, self.soundWindowRMSdBFS / 20)
        var total = 0
        var loud = 0
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(framesPerWindow)) } catch { return nil }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            var loudest: Float = 0
            for channel in 0..<Int(format.channelCount) {
                var rms: Float = 0
                vDSP_rmsqv(channels[channel], 1, &rms, vDSP_Length(buffer.frameLength))
                loudest = max(loudest, rms)
            }
            total += 1
            if loudest >= threshold { loud += 1 }
        }
        return (total, loud)
    }

    /// True when the call audio was recorded for too little of the recording to rely on: it carried sound for less than `minimumSoundShare` of its
    /// seconds, measured from the saved audio. The "silent for 90% of its length" test above reads the track's last run of silence, which a few
    /// faint clicks reset and which a capture that dies halfway never reaches; this reads the audio itself. Nil-safe: an unreadable file is not absence.
    nonisolated static func callAudioWasMostlyAbsent(in session: MeetingSession, directory: URL) -> Bool {
        guard let application = session.audioTracks.first(where: { $0.kind == .applicationAudio }),
              self.recordedSeconds(of: application) >= self.minimumSilentSeconds,
              let share = self.soundShare(of: application, in: directory)
        else { return false }
        return share < self.minimumSoundShare
    }

    /// Like `effectiveSession(for:)`, and also catches a call track that is mostly empty without being silent at the end. Reads the call-audio files
    /// (only when the microphone would be refused anyway), so it must not run on the main actor: use the async `effectiveSession(for:directory:)`.
    nonisolated static func effectiveSessionMeasuring(for session: MeetingSession, directory: URL) -> (session: MeetingSession, reason: String?) {
        let direct = self.effectiveSession(for: session)
        if direct.reason != nil { return direct }
        guard session.mode == .onlineCall, self.microphoneWouldBeExcluded(in: session) else { return (session, nil) }
        if self.callAudioWasMostlyAbsent(in: session, directory: directory) {
            var adjusted = session
            adjusted.mode = .inRoom
            return (adjusted, self.mostlyAbsentEventDetail)
        }
        // The call audio is there, but the microphone was recorded raw (the speakers' sound may be in it). Refusing it whole dropped the person's own voice
        // from every such recording (2026-11-24: a 36 minute call whose transcript held only the other person). Keep it, and let the transcript backend remove
        // the microphone units that merely repeat the call audio's text.
        return (self.keepingUnprotectedMicrophoneForTextCheck(session), nil)
    }

    /// The session with every `unprotected` microphone era marked `textEchoChecked`; unchanged when there is none. Only this processing run sees it.
    nonisolated static func keepingUnprotectedMicrophoneForTextCheck(_ session: MeetingSession) -> MeetingSession {
        var adjusted = session
        adjusted.audioTracks = session.audioTracks.map { track in
            guard track.kind == .microphone, let eras = track.captureEras, eras.contains(where: { $0.echoProtection == .unprotected }) else { return track }
            var track = track
            track.captureEras = eras.map { era in
                var era = era
                if era.echoProtection == .unprotected { era.echoProtection = .textEchoChecked }
                return era
            }
            return track
        }
        return adjusted
    }

    /// True when `effective` keeps a microphone era that `saved` recorded as unprotected, for the log line.
    nonisolated static func keptUnprotectedMicrophone(saved: MeetingSession, effective: MeetingSession) -> Bool {
        let before = saved.audioTracks.flatMap { $0.captureEras ?? [] }.filter { $0.echoProtection == .unprotected }.count
        let after = effective.audioTracks.flatMap { $0.captureEras ?? [] }.filter { $0.echoProtection == .unprotected }.count
        return before > after
    }

    /// The same, off the main actor (the processing pipeline is main-actor isolated and the call track can be an hour of audio).
    static func effectiveSession(for session: MeetingSession, directory: URL) async -> (session: MeetingSession, reason: String?) {
        await Task.detached(priority: .utility) {
            self.effectiveSessionMeasuring(for: session, directory: directory)
        }.value
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
