import AppKit
import Combine
import CryptoKit
import Foundation

enum NotchDownloaderSettings {
    private static let enabledKey = "LaVoixNotchDownloaderEnabled"
    private static let folderKey = "LaVoixNotchDownloaderFolder"

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    /// Where finished MP3s are saved. Defaults to Music > LaVoix.
    static var folder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: self.folderKey), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/LaVoix", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: self.folderKey) }
    }
}

/// One line of output from a running tool, or its exit.
enum DownloaderProcessEvent: Sendable, Equatable {
    case line(String)
    case exit(Int32)
}

/// Turns a YouTube link into an MP3 on this Mac by running two free command-line tools: yt-dlp (finds and downloads the
/// audio) and ffmpeg (converts it to MP3). LaVoix itself does not contain either; yt-dlp is fetched from its official
/// release page (checked against the published checksum) and ffmpeg is the one already installed.
///
/// YouTube's terms don't allow downloading, and what you download is still someone's work. Use it for audio you have
/// the right to keep: your own uploads, Creative Commons videos, podcasts and the like.
@MainActor
final class YouTubeDownloader: ObservableObject {
    static let shared = YouTubeDownloader()

    struct Job: Identifiable, Equatable {
        enum State: Equatable {
            case fetching
            case downloading
            case converting
            case done
            case failed(String)
            case cancelled
        }

        let id: UUID
        var url: URL
        var title: String
        var channel: String?
        var duration: TimeInterval?
        var viewCount: Int64?
        var isCreativeCommons = false
        var thumbnail: NSImage?
        var state: State = .fetching
        /// 0...1 while downloading.
        var progress: Double = 0
        var file: URL?
        var date = Date()

        var isRunning: Bool {
            switch self.state {
            case .fetching, .downloading, .converting: return true
            default: return false
            }
        }

        static func == (lhs: Job, rhs: Job) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.state == rhs.state && lhs.progress == rhs.progress
                && lhs.file == rhs.file && lhs.channel == rhs.channel && (lhs.thumbnail == nil) == (rhs.thumbnail == nil)
                && lhs.viewCount == rhs.viewCount && lhs.duration == rhs.duration
        }
    }

    enum InstallState: Equatable {
        case idle
        case installing
        case failed(String)
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var ytDlp: URL?
    @Published private(set) var ffmpeg: URL?
    @Published private(set) var installState: InstallState = .idle
    @Published private(set) var updateMessage: String?

    /// Runs a tool and streams its output. Replaced in tests.
    var runner: @Sendable (URL, [String]) -> AsyncStream<DownloaderProcessEvent> = YouTubeDownloader.defaultRunner
    /// Folder the MP3s go to. Replaced in tests.
    var outputFolder: () -> URL = { NotchDownloaderSettings.folder }
    /// Fetches a video's thumbnail. Replaced in tests.
    var thumbnailFetcher: (String) async -> NSImage? = { await NowPlayingArtwork.fetchThumbnail(videoID: $0) }

    private let supportDirectory: URL
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var isSample = false

    var isReady: Bool { self.ytDlp != nil && self.ffmpeg != nil }

    init(supportDirectory: URL? = nil) {
        self.supportDirectory = supportDirectory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaVoix", isDirectory: true)
        self.locateTools()
        self.loadHistory()
    }

    // MARK: - Tools

    /// Test hook: pretend these tools were found.
    func debugSetTools(ytDlp: URL?, ffmpeg: URL?) {
        self.ytDlp = ytDlp
        self.ffmpeg = ffmpeg
    }

    private var binDirectory: URL { self.supportDirectory.appendingPathComponent("bin", isDirectory: true) }

    /// Looks for yt-dlp and ffmpeg in the usual places (LaVoix's own copy first, then Homebrew).
    func locateTools() {
        self.ytDlp = Self.firstExecutable([
            ProcessInfo.processInfo.environment["LAVOIX_YTDLP_PATH"].map { URL(fileURLWithPath: $0) },
            self.binDirectory.appendingPathComponent("yt-dlp"),
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
        ])
        self.ffmpeg = Self.firstExecutable([
            self.binDirectory.appendingPathComponent("ffmpeg"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg"),
        ])
    }

    nonisolated static func firstExecutable(_ candidates: [URL?]) -> URL? {
        candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Fetches yt-dlp from its official GitHub release, checks it against the published SHA-256, and keeps it in LaVoix's
    /// own folder. Nothing is installed anywhere else.
    func installYtDlp() {
        guard self.installState != .installing, !self.isSample else { return }
        self.installState = .installing
        let target = self.binDirectory.appendingPathComponent("yt-dlp")
        Task {
            do {
                let base = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
                async let binary = URLSession.shared.data(from: URL(string: base + "yt-dlp_macos")!)
                async let sums = URLSession.shared.data(from: URL(string: base + "SHA2-256SUMS")!)
                let (binaryData, _) = try await binary
                let (sumsData, _) = try await sums
                guard Self.verify(data: binaryData, sums: String(decoding: sumsData, as: UTF8.self), name: "yt-dlp_macos") else {
                    throw DownloaderError.checksumMismatch
                }
                try FileManager.default.createDirectory(at: self.binDirectory, withIntermediateDirectories: true)
                try binaryData.write(to: target, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
                self.locateTools()
                self.installState = .idle
            } catch {
                self.installState = .failed(error.localizedDescription)
            }
        }
    }

    /// Asks yt-dlp to update itself (it breaks now and then when YouTube changes). Only LaVoix's own copy can do this.
    func updateYtDlp() {
        guard let ytDlp, ytDlp.path.hasPrefix(self.binDirectory.path), !self.isSample else {
            self.updateMessage = "Update it with Homebrew: brew upgrade yt-dlp"
            return
        }
        self.updateMessage = "Updating…"
        Task {
            var last = ""
            for await event in self.runner(ytDlp, ["-U"]) {
                if case let .line(line) = event, !line.isEmpty { last = line }
            }
            self.updateMessage = last.isEmpty ? "Done" : last
        }
    }

    enum DownloaderError: LocalizedError {
        case checksumMismatch
        var errorDescription: String? { "The download didn't match its published checksum, so it was thrown away." }
    }

    /// True when `data`'s SHA-256 equals the entry for `name` in a `SHA2-256SUMS` file.
    nonisolated static func verify(data: Data, sums: String, name: String) -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name { return parts[0].lowercased() == digest }
        }
        return false
    }

    // MARK: - Links

    /// A clean watch link from anything that points at one YouTube video (watch, short link, Shorts, YouTube Music);
    /// playlists and tracking parameters are dropped. nil when the text isn't a YouTube video link.
    nonisolated static func youTubeURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed.hasPrefix("http") ? trimmed : "https://" + trimmed),
              let host = components.host,
              let id = NowPlayingArtwork.youTubeVideoID(host: host, path: components.path, query: components.query ?? "") else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    // MARK: - Arguments and parsing

    nonisolated static func infoArguments(url: URL) -> [String] {
        ["--no-playlist", "--no-warnings", "--skip-download", "--dump-single-json", url.absoluteString]
    }

    nonisolated static func downloadArguments(url: URL, ffmpeg: URL, folder: URL) -> [String] {
        [
            "--no-playlist", "--no-warnings", "--no-colors", "--newline", "--progress", "--no-simulate",
            "-x", "--audio-format", "mp3", "--audio-quality", "0",
            "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg",
            "--ffmpeg-location", ffmpeg.deletingLastPathComponent().path,
            "--progress-template", "download:LVP %(progress._percent_str)s",
            "--print", "after_move:LVFILE %(filepath)s",
            "-o", folder.appendingPathComponent("%(title).150B.%(ext)s").path,
            url.absoluteString,
        ]
    }

    struct Info: Equatable {
        var title: String
        var channel: String?
        var duration: TimeInterval?
        var viewCount: Int64?
        var videoID: String?
        var isCreativeCommons: Bool
    }

    nonisolated static func parseInfo(_ line: String) -> Info? {
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = object["title"] as? String else { return nil }
        return Info(
            title: title,
            channel: (object["channel"] as? String) ?? (object["uploader"] as? String),
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            viewCount: (object["view_count"] as? NSNumber)?.int64Value,
            videoID: object["id"] as? String,
            isCreativeCommons: ((object["license"] as? String) ?? "").localizedCaseInsensitiveContains("creative commons")
        )
    }

    /// 0...1 from a `LVP  45.3%` progress line.
    nonisolated static func progress(from line: String) -> Double? {
        guard line.hasPrefix("LVP") else { return nil }
        let digits = line.dropFirst(3).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." }
        return Double(digits).map { min(max($0 / 100, 0), 1) }
    }

    /// A short, readable reason from yt-dlp's `ERROR:` line.
    nonisolated static func friendlyError(_ line: String?) -> String {
        guard var message = line else { return "The download didn't finish." }
        if message.hasPrefix("ERROR:") { message.removeFirst(6) }
        message = message.trimmingCharacters(in: .whitespaces)
        // "[youtube] abc123: Video unavailable" -> "Video unavailable"
        if message.hasPrefix("["), let colon = message.range(of: ": ") { message = String(message[colon.upperBound...]) }
        if message.localizedCaseInsensitiveContains("sign in") {
            return "YouTube wants a sign-in for this one. Try updating the downloader, or another video."
        }
        if message.localizedCaseInsensitiveContains("ffmpeg") { return "ffmpeg isn't working. Reinstall it with: brew reinstall ffmpeg" }
        return String(message.prefix(140))
    }

    // MARK: - Jobs

    /// Starts a download from pasted text. Returns false when it isn't a YouTube video link or the tools aren't ready.
    @discardableResult
    func add(_ text: String) -> Bool {
        guard let url = Self.youTubeURL(from: text), self.isReady || self.isSample else { return false }
        let id = UUID()
        self.jobs.insert(Job(id: id, url: url, title: url.absoluteString), at: 0)
        self.tasks[id] = Task { [weak self] in await self?.run(id) }
        return true
    }

    func cancel(_ id: UUID) {
        self.tasks[id]?.cancel()
    }

    func remove(_ id: UUID) {
        self.tasks[id]?.cancel()
        self.tasks[id] = nil
        self.jobs.removeAll { $0.id == id }
        self.saveHistory()
    }

    func clearFinished() {
        self.jobs.removeAll { !$0.isRunning }
        self.saveHistory()
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let index = self.jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = self.jobs[index]
        change(&job)
        if job != self.jobs[index] { self.jobs[index] = job }
    }

    private func run(_ id: UUID) async {
        guard let ytDlp, let ffmpeg, let job = self.jobs.first(where: { $0.id == id }) else { return }
        defer { self.tasks[id] = nil }

        // 1. Look the video up (title, channel, length, views) so the list shows something real straight away.
        var infoLine: String?
        var infoError: String?
        var infoExit: Int32 = -1
        for await event in self.runner(ytDlp, Self.infoArguments(url: job.url)) {
            switch event {
            case let .line(line):
                if line.hasPrefix("{") { infoLine = line } else if line.hasPrefix("ERROR") { infoError = line }
            case let .exit(code): infoExit = code
            }
        }
        if Task.isCancelled { self.update(id) { $0.state = .cancelled }; return }
        guard infoExit == 0, let infoLine, let info = Self.parseInfo(infoLine) else {
            self.update(id) { $0.state = .failed(Self.friendlyError(infoError)) }
            return
        }
        self.update(id) {
            $0.title = info.title
            $0.channel = info.channel
            $0.duration = info.duration
            $0.viewCount = info.viewCount
            $0.isCreativeCommons = info.isCreativeCommons
            $0.state = .downloading
        }
        if let videoID = info.videoID {
            Task { [weak self] in
                guard let self, let image = await self.thumbnailFetcher(videoID) else { return }
                self.update(id) { $0.thumbnail = image }
            }
        }

        // 2. Download the audio and convert it to MP3.
        let folder = self.outputFolder()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var file: URL?
        var errorLine: String?
        var exitCode: Int32 = -1
        for await event in self.runner(ytDlp, Self.downloadArguments(url: job.url, ffmpeg: ffmpeg, folder: folder)) {
            switch event {
            case let .line(line):
                if let progress = Self.progress(from: line) {
                    self.update(id) { $0.progress = progress }
                } else if line.hasPrefix("LVFILE ") {
                    file = URL(fileURLWithPath: String(line.dropFirst(7)))
                } else if line.hasPrefix("[ExtractAudio]") || line.hasPrefix("[Metadata]") || line.hasPrefix("[EmbedThumbnail]") {
                    self.update(id) { $0.state = .converting; $0.progress = 1 }
                } else if line.hasPrefix("ERROR") {
                    errorLine = line
                }
            case let .exit(code): exitCode = code
            }
        }
        if Task.isCancelled { self.update(id) { $0.state = .cancelled }; return }
        if exitCode == 0, let file {
            self.update(id) { $0.state = .done; $0.file = file; $0.progress = 1; $0.date = Date() }
            self.saveHistory()
        } else {
            self.update(id) { $0.state = .failed(Self.friendlyError(errorLine)) }
        }
    }

    // MARK: - Process plumbing

    /// Collects bytes and hands back whole lines, holding any partial line until its end arrives.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func append(_ data: Data) -> [String] {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.pending.append(data)
            var lines: [String] = []
            while let newline = self.pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: self.pending[self.pending.startIndex..<newline], as: UTF8.self))
                self.pending.removeSubrange(self.pending.startIndex...newline)
            }
            return lines
        }

        func flush() -> String? {
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.pending.isEmpty else { return nil }
            defer { self.pending = Data() }
            return String(decoding: self.pending, as: UTF8.self)
        }
    }

    private nonisolated static func defaultRunner(_ executable: URL, _ arguments: [String]) -> AsyncStream<DownloaderProcessEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "en_US.UTF-8"
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in buffer.append(data) { continuation.yield(.line(line)) }
            }
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                for line in buffer.append(pipe.fileHandleForReading.readDataToEndOfFile()) { continuation.yield(.line(line)) }
                if let rest = buffer.flush() { continuation.yield(.line(rest)) }
                continuation.yield(.exit(finished.terminationStatus))
                continuation.finish()
            }
            // Stop the tool if whoever is watching it goes away (a cancelled download).
            continuation.onTermination = { _ in if process.isRunning { process.terminate() } }
            do {
                try process.run()
            } catch {
                continuation.yield(.line("ERROR: couldn't start \(executable.lastPathComponent)"))
                continuation.yield(.exit(127))
                continuation.finish()
            }
        }
    }

    // MARK: - History

    private struct SavedJob: Codable {
        var id: UUID
        var url: URL
        var title: String
        var channel: String?
        var path: String
        var date: Date
    }

    private var historyURL: URL { self.supportDirectory.appendingPathComponent("Downloads.json") }

    private func saveHistory() {
        guard !self.isSample else { return }
        let saved = self.jobs.filter { $0.state == .done && $0.file != nil }.prefix(40).map {
            SavedJob(id: $0.id, url: $0.url, title: $0.title, channel: $0.channel, path: $0.file!.path, date: $0.date)
        }
        try? FileManager.default.createDirectory(at: self.supportDirectory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(saved)) { try? data.write(to: self.historyURL, options: .atomic) }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: self.historyURL), let saved = try? JSONDecoder().decode([SavedJob].self, from: data) else { return }
        self.jobs = saved.filter { FileManager.default.fileExists(atPath: $0.path) }.map {
            var job = Job(id: $0.id, url: $0.url, title: $0.title, channel: $0.channel)
            job.state = .done
            job.progress = 1
            job.file = URL(fileURLWithPath: $0.path)
            job.date = $0.date
            return job
        }
    }

    // MARK: - Preview data

    static func sample(ready: Bool = true, empty: Bool = false) -> YouTubeDownloader {
        let store = YouTubeDownloader(supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-dl-sample-\(UUID().uuidString)"))
        store.isSample = true
        store.jobs = []
        if ready {
            store.ytDlp = URL(fileURLWithPath: "/usr/bin/true")
            store.ffmpeg = URL(fileURLWithPath: "/usr/bin/true")
            var running = Job(id: UUID(), url: URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!, title: "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
            running.channel = "Blender"; running.duration = 635; running.viewCount = 23_432_904; running.isCreativeCommons = true
            running.state = .downloading; running.progress = 0.62
            var finished = Job(id: UUID(), url: URL(string: "https://www.youtube.com/watch?v=XuKtJxxxxxx")!, title: "Weekend Update ft. James Austin Johnson and Ashley Padilla")
            finished.channel = "Saturday Night Live"; finished.duration = 245; finished.state = .done; finished.progress = 1
            finished.file = URL(fileURLWithPath: "/Users/me/Music/LaVoix/Weekend Update.mp3")
            var failed = Job(id: UUID(), url: URL(string: "https://www.youtube.com/watch?v=privatexxxx")!, title: "https://www.youtube.com/watch?v=privatexxxx")
            failed.state = .failed("Private video")
            store.jobs = empty ? [] : [running, finished, failed]
        } else {
            store.ytDlp = nil
            store.ffmpeg = nil
        }
        return store
    }
}
