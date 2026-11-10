import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// myOS's "Transcribe a file": the engine's own file transcriber (the on-device model, with speaker labels, any audio or video format macOS can open) driven over the
/// socket, so a one-hour video can be dropped on myOS instead of paid for elsewhere. Each finished transcript is also saved as two files in myOS's private folder
/// (`Transcripts/<id>.json` and `<id>.txt`), so myOS can list, open and delete them without asking the engine, and so one is never lost if myOS is closed meanwhile.
///
///   {"op":"meetings.transcribe_file","path":"/abs/file","title"?}
///     -> {"event":"progress","fraction":0.4,"status":"..."} (many), then {"event":"done","transcript":{...}} or {"event":"error","error":"..."}
///     -> or at once {"ok":false,"error":"..."} (not a file, or a meeting is being recorded or processed).
/// The model is shared with dictation and meetings, and an exclusive-activity lease keeps this from running while a meeting records.
enum EngineFileTranscription {
    nonisolated static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("myOS/private/Transcripts", isDirectory: true)
    }

    struct Segment: Equatable, Sendable {
        var speaker: String
        var start: Double
        var end: Double
        var text: String
    }

    /// The name shown for a transcript: the one given, else the file's name without its extension.
    nonisolated static func title(given: String?, fileName: String) -> String {
        let trimmed = given?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return String(trimmed.prefix(200)) }
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? fileName : base
    }

    /// "[m:ss] Speaker: text" lines (or the plain text when nothing carries a speaker and a time).
    nonisolated static func readableText(title: String, text: String, segments: [Segment]) -> String {
        guard !segments.isEmpty else { return title + "\n\n" + text + "\n" }
        func stamp(_ seconds: Double) -> String {
            let total = Int(max(0, seconds).rounded(.down))
            let h = total / 3600, m = (total % 3600) / 60, s = total % 60
            return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        }
        return title + "\n\n" + segments.map { "[\(stamp($0.start))] \($0.speaker): \($0.text)" }.joined(separator: "\n") + "\n"
    }

    /// The JSON myOS reads. Plain values only, so it can be written and sent as it is.
    nonisolated static func payload(
        id: UUID, title: String, fileName: String, sourcePath: String, createdAt: Date,
        duration: Double, processing: Double, text: String, segments: [Segment], notice: String?
    ) -> [String: Any] {
        [
            "id": id.uuidString,
            "title": title,
            "file_name": fileName,
            "source_path": sourcePath,
            "created_at": ISO8601DateFormatter().string(from: createdAt),
            "duration_seconds": duration,
            "processing_seconds": processing,
            "text": text,
            "segments": segments.map { ["speaker": $0.speaker, "start": $0.start, "end": $0.end, "text": $0.text] },
            "notice": notice as Any? ?? NSNull(),
        ]
    }

    /// An existing regular file, or why not.
    nonisolated static func validatedFile(path: String) throws -> URL {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw EngineMeetingsError.unavailable("That is not a file on this Mac.")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw EngineMeetingsError.unavailable("myOS cannot read that file.")
        }
        return URL(fileURLWithPath: path)
    }

    nonisolated static func save(_ record: [String: Any], readable: String, id: UUID, into directory: URL = EngineFileTranscription.folder) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let json = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        try Data(readable.utf8).write(to: directory.appendingPathComponent("\(id.uuidString).txt"), options: .atomic)
    }

    /// True for a video container (the engine's speaker-labelled path skips those, so their sound is taken out first).
    nonisolated static func isVideoFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased()).map { $0.conforms(to: .movie) } ?? false
    }

    /// The sound of a video as a temporary .m4a, which the speaker-labelled path can take.
    nonisolated static func extractAudio(from video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw EngineMeetingsError.unavailable("That video has no sound to transcribe.")
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw EngineMeetingsError.unavailable("macOS could not take the sound out of that video.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("myos-audio-\(UUID().uuidString).m4a")
        try await export.export(to: temporary, as: .m4a)
        return temporary
    }

    @MainActor
    static func run(path: String, title: String?, emit: @escaping @Sendable ([String: Any]) -> Bool) async {
        let url: URL
        do { url = try self.validatedFile(path: path) } catch {
            _ = emit(["ok": false, "error": error.localizedDescription]); return
        }
        if let busy = AppServices.shared.asr.activeExclusiveActivity {
            let why = busy == .meeting ? "A meeting is being recorded or processed, so a file cannot be transcribed right now." : "Wait for the active \(busy.displayName) to finish."
            _ = emit(["ok": false, "error": why]); return
        }
        let service = AppServices.shared.fileTranscriptionService
        guard !service.isTranscribing else { _ = emit(["ok": false, "error": "A file is already being transcribed."]); return }
        // Progress is read from the service about every 0.7 s; a listener that has gone away (myOS closed) only stops the updates, the transcript is still saved.
        let poller = Task { @MainActor in
            var last = -1.0
            var listening = true
            while !Task.isCancelled, listening {
                let fraction = service.progress
                if fraction != last { last = fraction; listening = emit(["event": "progress", "fraction": fraction, "status": service.currentStatus]) }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        defer { poller.cancel() }
        // Speaker labels (and so times) are wanted for every file here; the engine's own setting (off by default) is put back afterwards.
        let settings = SettingsStore.shared
        let labelsBefore = settings.fileTranscriptionSpeakerLabelsEnabled
        settings.fileTranscriptionSpeakerLabelsEnabled = true
        var temporaryAudio: URL?
        defer {
            settings.fileTranscriptionSpeakerLabelsEnabled = labelsBefore
            if let temporaryAudio { try? FileManager.default.removeItem(at: temporaryAudio) }
        }
        do {
            var source = url
            if self.isVideoFile(url) {
                _ = emit(["event": "progress", "fraction": 0.02, "status": "Taking the sound out of the video..."])
                source = try await self.extractAudio(from: url)
                temporaryAudio = source
            }
            let result = try await service.transcribeFile(source)
            let segments = result.speakerSegments.map { Segment(speaker: $0.speaker, start: $0.startSeconds, end: $0.endSeconds, text: $0.text) }
            // The person's file, not the temporary one the sound was taken to.
            let fileName = url.lastPathComponent
            let name = self.title(given: title, fileName: fileName)
            let record = self.payload(
                id: result.id, title: name, fileName: fileName, sourcePath: url.path, createdAt: result.timestamp,
                duration: result.duration, processing: result.processingTime, text: result.text, segments: segments, notice: result.speakerLabelingNotice
            )
            try self.save(record, readable: self.readableText(title: name, text: result.text, segments: segments), id: result.id)
            DebugLogger.shared.info("File transcribed: \(Int(result.duration)) s of audio in \(Int(result.processingTime)) s, \(segments.count) segments", source: "EngineFileTranscription")
            _ = emit(["event": "done", "transcript": record])
        } catch {
            DebugLogger.shared.warning("File transcription failed: \(error.localizedDescription)", source: "EngineFileTranscription")
            _ = emit(["event": "error", "error": error.localizedDescription])
        }
    }
}
