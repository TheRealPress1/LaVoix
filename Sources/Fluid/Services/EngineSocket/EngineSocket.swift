import AVFoundation
import Contacts
import Darwin
import Foundation

/// Lets myOS use LaVoix's engine. A Unix socket in the owner-only folder `~/Library/Application Support/myOS/private/`
/// (the same place as the message store), NOT a TCP port: any process on the Mac can reach a port, only this user can reach
/// this file. One request per connection, one JSON line in; the reply is one JSON line, or for streaming operations a
/// sequence of lines ending with a `done` or `error` event. The prompts can contain message text, so nothing logs them.
///
///   {"op":"status"}                                       -> {"ok":true,"model":"...","downloaded":true,"loaded":false}
///   {"op":"warm"}                                         -> {"ok":true}   (starts loading the model; returns at once)
///   {"op":"generate","system","user","max_tokens"}        -> {"ok":true,"text":"...","ms":1234}
///   {"op":"generate_stream","system","user","max_tokens"} -> {"event":"token","text":"..."} ... {"event":"done","ms":1234}
///   {"op":"meetings.list"}                                -> {"ok":true,"meetings":[...]}
///   {"op":"meetings.get","id"}                            -> {"ok":true,"meeting":{...}}
///   {"op":"meetings.live"}                                -> {"ok":true,"live":{"active":true,"id","title","started_at","elapsed_seconds","rows":[{"speaker":"you|them","text","partial"}]}}
///   {"op":"meetings.start","title","online"}             -> {"ok":true,"meeting":{"id","title"}}   (online: the call in the app you are using; otherwise a conversation in the room)
///   {"op":"meetings.stop"}                                -> {"ok":true}
///   {"op":"meetings.rename","id","title"}  /  {"op":"meetings.rename_speaker","id","speaker","name"}  /  {"op":"meetings.delete","id"}  -> {"ok":true}
///   {"op":"meetings.notes_feedback","id","kind","rating":"good|bad|edited","text"?}  -> {"ok":true}   (your verdict on the notes; "edited" carries your corrected version)
///   {"op":"training.status"} -> {"ok":true,"training":{good,bad,edited,usable,unrated_inputs,folder}}  /  {"op":"training.export"} -> {"ok":true,"export":{train,valid,folder}}  /  {"op":"training.clear"}
///   {"op":"training.rate_ask","system","user","output","rating":"good|bad|edited","corrected"?}  -> {"ok":true}   (an answer from Ask, with the exact input it was given)
///   {"op":"meetings.notes_save","id","text"}              -> {"ok":true}
///   {"op":"meetings.notes_generate","id","kind","auto"}   -> {"event":"progress","message"} ... {"event":"done","text"}
///   {"op":"writing.list","search","limit"}               -> {"ok":true,"entries":[{id,bundle_id,app_name,window_title,first_at,last_at,latest,peak,version_count}]}
///   {"op":"writing.versions","entry"}                     -> {"ok":true,"versions":[{id,at,text}]}
///   {"op":"writing.delete","entry"} / {"op":"writing.delete_all","bundle_id"?}  -> {"ok":true}
///   {"op":"writing.settings"}                             -> {"ok":true,"settings":{enabled,days,excluded,accessibility,count}}
///   {"op":"writing.settings_set","enabled"?,"days"?,"excluded"?}  -> {"ok":true,"settings":{...}}
///   {"op":"history.list","search","starred","limit"}      -> {"ok":true,"history":{entries:[...],matched,total,today_words,today_transcriptions,loading,error}}
///   {"op":"history.star","id"} / history.delete / {"op":"history.clear"}  -> {"ok":true}
///   {"op":"settings.list"}                                -> {"ok":true,"settings":[{key,group,title,detail,kind,value,options?,min?,max?}]}
///   {"op":"settings.set","key","value"}                   -> {"ok":true,"setting":{...}}   (only listed settings; wrong values are refused)
///   {"op":"dictionary.list"}                              -> {"ok":true,"entries":[{id,triggers:[...],replacement}]}
///   {"op":"dictionary.save","id"?,"triggers":[...],"replacement"} -> {"ok":true,"entry":{...}}   (no id adds; a clash or empty field is refused)
///   {"op":"dictionary.delete","id"}                       -> {"ok":true}
///   {"op":"stats.get"}                                    -> {"ok":true,"stats":{total_words,total_transcriptions,current_streak,best_streak,time_saved,top_apps,hourly,activity,milestones,...}}   (numbers only)
///   {"op":"prompts.list"}                                 -> {"ok":true,"prompts":{profiles:[{id,name,mode,prompt,include_context}],dictate:{selected,default_prompt,default_is_custom},edit:{...}}}
///   {"op":"prompts.save","id"?,"name","prompt","mode":"dictate|edit","include_context"} -> {"ok":true,"profile":{...}}
///   {"op":"prompts.delete","id"} / {"op":"prompts.select","mode","selection":"default|off|profile:<id>"} / {"op":"prompts.set_default","mode","text"}  -> {"ok":true}
///   {"op":"speech.list"}                                  -> {"ok":true,"speech":{models:[{id,name,brand,language,size,installed,active,update_available,accuracy,speed,description}],blocked,downloading?:{id,progress,cancelling},error?}}
///   {"op":"speech.activate","id"} / speech.download / speech.delete / {"op":"speech.cancel"}  -> {"ok":true}   (start the work and return; ask speech.list for progress)
///   {"op":"activity"}                                     -> {"ok":true,"activity":{recording,meeting_processing,dictating,busy}}   (so background work can wait its turn)
///   {"op":"contacts.lookup","emails":[...],"phones":[...]} -> {"ok":true,"contact":{found,full_name,nickname,organization,job_title,emails,phones,photo?,birthday?{month,day},dates?[{label,month,day}],addresses?[{label,city,state,country}],relations?[{label,name}],urls?[...]}}   (found by those addresses only; no birth year, no street)
///   {"op":"permissions.status"}                          -> {"ok":true,"permissions":{microphone,accessibility,input_monitoring,contacts,full_disk_access}}   (each "granted" | "denied" | "not_asked"; read-only)
///   {"op":"permissions.request","name"}                   -> {"ok":true}   (shows macOS's own question where there is one; Full Disk Access is refused, the user switches it on in System Settings)
///   {"op":"shortcuts.get"}                                -> {"ok":true,"shortcuts":{dictation:[...],edit,command,cancel,paste_last}}   (labels such as "Fn"; read-only)
///   {"op":"audio.inputs"}                                 -> {"ok":true,"audio":{inputs:[{uid,name,preferred,default}]}}   (read-only)
///   {"op":"words.list"} / {"op":"words.add","text","aliases"?} / {"op":"words.delete","text"}  -> {"ok":true,"words":[{text,aliases}]} / {"ok":true,"word":{...}} / {"ok":true}   (boost words)
///   {"op":"dictionary.export"}                            -> {"ok":true,"file":"<json>"}   (replacements and boost words, as LaVoix's own export file)
///   {"op":"dictionary.import","file","replace"?}          -> {"ok":true,"replacements":n,"words":n}   (merges unless replace is true)
/// Failures come back as {"ok":false,"error":"..."} (streams: {"event":"error","error":"..."}).
nonisolated enum EngineSocket {
    static let maxRequestBytes = 1_000_000
    private static let enabledKey = "LaVoixEngineSocketEnabled"

    /// On by default: it only serves the signed-in user and only runs the local model.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: self.enabledKey) }
    }

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/myOS/private/engine.sock")
    }

    /// What the engine can do; injected so the autotest never needs a model or real meetings.
    typealias Generator = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> String
    typealias StreamGenerator = @Sendable (_ system: String, _ user: String, _ maxTokens: Int) async throws -> AsyncThrowingStream<String, Error>
    typealias StatusProvider = @Sendable () async -> (model: String, downloaded: Bool, loaded: Bool)
    typealias Warmer = @Sendable () -> Void

    struct Services: @unchecked Sendable {
        var generator: Generator
        var streamGenerator: StreamGenerator?
        var status: StatusProvider
        var warm: Warmer = {}
        var meetings: (any EngineMeetingsProviding)?
        var writing: (any EngineWritingProviding)?
        var history: (any EngineHistoryProviding)?
        var settings: (any EngineSettingsProviding)?
        var dictionary: (any EngineDictionaryProviding)?
        var stats: (any EngineStatsProviding)?
        var prompts: (any EnginePromptsProviding)?
        var speech: (any EngineSpeechProviding)?
        var activity: (any EngineActivityProviding)?
        var contacts: (any EngineContactsProviding)?
        var permissions: (any EnginePermissionsProviding)?
        var shortcuts: (any EngineShortcutsProviding)?
        var words: (any EngineWordsProviding)?
    }

    private static let lock = NSLock()
    /// One listener per socket path (the autotest serves a temp path while the app serves the real one).
    private nonisolated(unsafe) static var listeners: [String: Int32] = [:]

    static func startIfEnabled() {
        guard self.isEnabled, ProcessInfo.processInfo.environment["LAVOIX_ENGINE_SOCKET_AUTOTEST"] != "1" else { return }
        _ = self.start(at: self.defaultURL, services: self.liveServices)
    }

    static let liveGenerator: Generator = { system, user, maxTokens in
        let modelID = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: modelID) else { throw EngineError.modelMissing }
        return try await LocalCleanupEngine.shared.generate(
            system: system, user: user, modelID: modelID, maxTokens: maxTokens, temperature: 0, cachesPrefix: false
        )
    }

    static let liveStreamGenerator: StreamGenerator = { system, user, maxTokens in
        let modelID = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: modelID) else { throw EngineError.modelMissing }
        return try await LocalCleanupEngine.shared.generateStream(system: system, user: user, modelID: modelID, maxTokens: maxTokens)
    }

    static let liveStatus: StatusProvider = {
        let id = LocalCleanupSettings.modelID
        return (id, LocalCleanupProvider.isDownloaded(modelID: id), await LocalCleanupEngine.shared.isLoaded)
    }

    static let liveWarmer: Warmer = {
        let id = LocalCleanupSettings.modelID
        guard LocalCleanupProvider.isDownloaded(modelID: id) else { return }
        Task.detached(priority: .utility) { try? await LocalCleanupEngine.shared.prepare(modelID: id) }
    }

    static var liveServices: Services {
        Services(generator: self.liveGenerator, streamGenerator: self.liveStreamGenerator, status: self.liveStatus, warm: self.liveWarmer, meetings: LiveEngineMeetings(), writing: LiveEngineWriting(), history: LiveEngineHistory(), settings: LiveEngineSettings(), dictionary: LiveEngineDictionary(), stats: LiveEngineStats(), prompts: LiveEnginePrompts(), speech: LiveEngineSpeech(), activity: LiveEngineActivity(), contacts: LiveEngineContacts(), permissions: LiveEnginePermissions(), shortcuts: LiveEngineShortcuts(), words: LiveEngineWords())
    }

    enum EngineError: LocalizedError {
        case modelMissing
        var errorDescription: String? { "The on-device model is not downloaded yet. Open myOS, then AI Providers, to download it." }
    }

    /// Binds the socket and serves it on background queues. Returns false if it could not (path too long, folder not writable).
    @discardableResult
    static func start(at url: URL, services: Services) -> Bool {
        self.lock.lock(); defer { self.lock.unlock() }
        if self.listeners[url.path] != nil { return true }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        unlink(url.path) // a stale socket from a crashed run

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return false }
        chmod(url.path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); unlink(url.path); return false }
        self.listeners[url.path] = fd

        DispatchQueue.global(qos: .utility).async {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break } // closed by stop()
                self.serve(client: client, services: services)
            }
        }
        return true
    }

    static func stop(removing url: URL = EngineSocket.defaultURL) {
        self.lock.lock(); defer { self.lock.unlock() }
        if let fd = self.listeners.removeValue(forKey: url.path) { close(fd) }
        unlink(url.path)
    }

    private static func serve(client: Int32, services: Services) {
        var one: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0) // a client that goes quiet cannot hold a thread
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); return }

        DispatchQueue.global(qos: .utility).async {
            let request = self.readLine(client)
            Task.detached {
                // Each line is written as it is produced; false tells a long-running operation that nobody is listening.
                let emit: @Sendable ([String: Any]) -> Bool = { object in
                    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(#"{"ok":false,"error":"encode"}"#.utf8)
                    return self.writeAll(client, data + Data("\n".utf8))
                }
                await self.handle(line: request, services: services, emit: emit)
                close(client)
            }
        }
    }

    /// Pure request -> lines, so the protocol can be tested without sockets or a model.
    static func handle(line: Data?, services: Services, emit: @escaping @Sendable ([String: Any]) -> Bool) async {
        func fail(_ message: String) { _ = emit(["ok": false, "error": message]) }
        guard let line, !line.isEmpty else { return fail("empty request") }
        guard line.count <= self.maxRequestBytes else { return fail("request too large") }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let op = object["op"] as? String else {
            return fail("not a JSON object with an op")
        }
        func uuid() -> UUID? { (object["id"] as? String).flatMap(UUID.init(uuidString:)) }
        func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? "failed" }
        let maxTokens = min(max((object["max_tokens"] as? Int) ?? 400, 16), 800)

        switch op {
        case "status":
            let s = await services.status()
            _ = emit(["ok": true, "model": s.model, "downloaded": s.downloaded, "loaded": s.loaded])
        case "warm":
            services.warm()
            _ = emit(["ok": true])
        case "generate":
            guard let user = object["user"] as? String, !user.isEmpty else { return fail("missing user") }
            let start = Date()
            do {
                let text = try await services.generator(object["system"] as? String ?? "", user, maxTokens)
                _ = emit(["ok": true, "text": text, "ms": Int(Date().timeIntervalSince(start) * 1000)])
            } catch { fail(message(error)) }
        case "generate_stream":
            guard let user = object["user"] as? String, !user.isEmpty else { return _ = emit(["event": "error", "error": "missing user"]) }
            guard let stream = services.streamGenerator else { return _ = emit(["event": "error", "error": "streaming is not available"]) }
            let start = Date()
            do {
                for try await piece in try await stream(object["system"] as? String ?? "", user, maxTokens) {
                    if !emit(["event": "token", "text": piece]) { return } // the listener left: stop generating
                }
                _ = emit(["event": "done", "ms": Int(Date().timeIntervalSince(start) * 1000)])
            } catch { _ = emit(["event": "error", "error": message(error)]) }
        case "meetings.list", "meetings.get", "meetings.notes_save", "meetings.notes_generate", "meetings.live", "meetings.start", "meetings.stop", "meetings.rename", "meetings.rename_speaker", "meetings.delete", "meetings.notes_feedback":
            guard let meetings = services.meetings else { return fail("meetings are not available") }
            do {
                switch op {
                case "meetings.live":
                    _ = emit(["ok": true, "live": await meetings.live()])
                case "meetings.start":
                    _ = emit(["ok": true, "meeting": try await meetings.start(title: object["title"] as? String ?? "", online: object["online"] as? Bool ?? false)])
                case "meetings.stop":
                    try await meetings.stop()
                    _ = emit(["ok": true])
                case "meetings.rename":
                    guard let id = uuid(), let title = object["title"] as? String else { return fail("missing id or title") }
                    try await meetings.rename(id: id, title: title)
                    _ = emit(["ok": true])
                case "meetings.rename_speaker":
                    guard let id = uuid(), let speaker = (object["speaker"] as? String).flatMap(UUID.init(uuidString:)), let name = object["name"] as? String else { return fail("missing id, speaker or name") }
                    try await meetings.renameSpeaker(id: id, speakerID: speaker, name: name)
                    _ = emit(["ok": true])
                case "meetings.notes_feedback":
                    guard let id = uuid(), let kind = object["kind"] as? String, let rating = object["rating"] as? String else { return fail("missing id, kind or rating") }
                    try await meetings.rateNotes(id: id, kind: kind, rating: rating, text: object["text"] as? String)
                    _ = emit(["ok": true])
                case "meetings.delete":
                    guard let id = uuid() else { return fail("missing or bad id") }
                    try await meetings.delete(id: id)
                    _ = emit(["ok": true])
                case "meetings.list":
                    _ = emit(["ok": true, "meetings": try await meetings.list()])
                case "meetings.get":
                    guard let id = uuid() else { return fail("missing or bad id") }
                    guard let meeting = try await meetings.get(id: id) else { return fail(EngineMeetingsError.notFound.errorDescription ?? "not found") }
                    _ = emit(["ok": true, "meeting": meeting])
                case "meetings.notes_save":
                    guard let id = uuid(), let text = object["text"] as? String else { return fail("missing id or text") }
                    try await meetings.saveNotes(id: id, text: text)
                    _ = emit(["ok": true])
                default:
                    guard let id = uuid() else { return _ = emit(["event": "error", "error": "missing or bad id"]) }
                    try await meetings.generateNotes(id: id, kind: object["kind"] as? String ?? "executive", auto: object["auto"] as? Bool ?? false, emit: emit)
                }
            } catch {
                _ = op == "meetings.notes_generate" ? emit(["event": "error", "error": message(error)]) : emit(["ok": false, "error": message(error)])
            }
        case "writing.list", "writing.versions", "writing.delete", "writing.delete_all", "writing.settings", "writing.settings_set":
            guard let writing = services.writing else { return fail("recent writing is not available") }
            let entry = (object["entry"] as? NSNumber)?.int64Value
            switch op {
            case "writing.list":
                _ = emit(["ok": true, "entries": await writing.list(search: object["search"] as? String ?? "", limit: object["limit"] as? Int ?? 200)])
            case "writing.versions":
                guard let entry else { return fail("missing entry") }
                _ = emit(["ok": true, "versions": await writing.versions(entryID: entry)])
            case "writing.delete":
                guard let entry else { return fail("missing entry") }
                await writing.delete(entryID: entry)
                _ = emit(["ok": true])
            case "writing.delete_all":
                await writing.deleteAll(bundleID: object["bundle_id"] as? String)
                _ = emit(["ok": true])
            case "writing.settings":
                _ = emit(["ok": true, "settings": await writing.settings()])
            default:
                await writing.updateSettings(object)
                _ = emit(["ok": true, "settings": await writing.settings()])
            }
        case "history.list", "history.star", "history.delete", "history.clear":
            guard let history = services.history else { return fail("history is not available") }
            switch op {
            case "history.list":
                _ = emit(["ok": true, "history": await history.list(search: object["search"] as? String ?? "", starredOnly: object["starred"] as? Bool ?? false, limit: object["limit"] as? Int ?? 200)])
            case "history.clear":
                await history.clearAll()
                _ = emit(["ok": true])
            default:
                guard let id = uuid() else { return fail("missing or bad id") }
                if op == "history.star" { await history.toggleStar(id: id) } else { await history.delete(id: id) }
                _ = emit(["ok": true])
            }
        case "contacts.lookup":
            guard let contacts = services.contacts else { return fail("contacts are not available") }
            let emails = (object["emails"] as? [String] ?? []).filter { $0.count <= 200 }
            let phones = (object["phones"] as? [String] ?? []).filter { $0.count <= 40 }
            guard !emails.isEmpty || !phones.isEmpty else { return fail("give at least one email or phone number") }
            _ = emit(["ok": true, "contact": await contacts.lookup(emails: emails, phones: phones)])
        case "shortcuts.get", "audio.inputs":
            guard let shortcuts = services.shortcuts else { return fail("shortcuts are not available") }
            if op == "shortcuts.get" { _ = emit(["ok": true, "shortcuts": await shortcuts.shortcuts()]) } else { _ = emit(["ok": true, "audio": await shortcuts.inputs()]) }
        case "permissions.status":
            guard let permissions = services.permissions else { return fail("permissions are not available") }
            _ = emit(["ok": true, "permissions": await permissions.status()])
        case "permissions.request":
            guard let permissions = services.permissions else { return fail("permissions are not available") }
            guard let name = object["name"] as? String, EnginePermissionNames.all.contains(name) else { return fail("name must be one of: \(EnginePermissionNames.all.joined(separator: ", "))") }
            do { try await permissions.request(name); _ = emit(["ok": true]) } catch EnginePermissionsError.notPromptable { fail("macOS can't ask for this one: switch it on in System Settings") } catch { fail(message(error)) }
        case "activity":
            guard let activity = services.activity else { return fail("activity is not available") }
            _ = emit(["ok": true, "activity": await activity.snapshot()])
        case "training.rate_ask":
            guard let system = object["system"] as? String, let user = object["user"] as? String, let output = object["output"] as? String,
                  let rating = (object["rating"] as? String).flatMap(TrainingData.Rating.init(rawValue:)) else { return fail("missing system, user, output or a valid rating") }
            do { _ = try TrainingData.rate(task: "ask", system: system, user: user, output: output, rating: rating, corrected: object["corrected"] as? String); _ = emit(["ok": true]) } catch { fail(message(error)) }
        case "training.status":
            _ = emit(["ok": true, "training": TrainingData.status()])
        case "training.export":
            do { _ = emit(["ok": true, "export": try TrainingData.export()]) } catch { fail("could not write the training files") }
        case "training.clear":
            TrainingData.clear()
            _ = emit(["ok": true])
        case "settings.list", "settings.set":
            guard let settings = services.settings else { return fail("settings are not available") }
            if op == "settings.list" {
                _ = emit(["ok": true, "settings": await settings.list()])
            } else {
                guard let key = object["key"] as? String, let value = object["value"], !(value is NSNull) else { return fail("missing key or value") }
                do { _ = emit(["ok": true, "setting": try await settings.set(key: key, value: value)]) } catch { fail(message(error)) }
            }
        case "dictionary.list", "dictionary.save", "dictionary.delete":
            guard let dictionary = services.dictionary else { return fail("the dictionary is not available") }
            switch op {
            case "dictionary.list":
                _ = emit(["ok": true, "entries": await dictionary.list()])
            case "dictionary.save":
                guard let triggers = object["triggers"] as? [String], let replacement = object["replacement"] as? String else { return fail("missing triggers or replacement") }
                if object["id"] != nil, uuid() == nil { return fail("bad id") }
                do { _ = emit(["ok": true, "entry": try await dictionary.save(id: uuid(), triggers: triggers, replacement: replacement)]) } catch { fail(message(error)) }
            default:
                guard let id = uuid() else { return fail("missing or bad id") }
                do { try await dictionary.delete(id: id); _ = emit(["ok": true]) } catch { fail(message(error)) }
            }
        case "words.list", "words.add", "words.delete", "dictionary.export", "dictionary.import":
            guard let words = services.words else { return fail("the dictionary is not available") }
            do {
                switch op {
                case "words.list": _ = emit(["ok": true, "words": await words.list()])
                case "words.add":
                    guard let text = object["text"] as? String else { return fail("missing text") }
                    _ = emit(["ok": true, "word": try await words.add(text: text, aliases: object["aliases"] as? [String] ?? [])])
                case "words.delete":
                    guard let text = object["text"] as? String else { return fail("missing text") }
                    try await words.delete(text: text); _ = emit(["ok": true])
                case "dictionary.export": _ = emit(["ok": true, "file": try await words.export()])
                default:
                    guard let file = object["file"] as? String else { return fail("missing file") }
                    var out = try await words.importFile(file, replace: object["replace"] as? Bool ?? false)
                    out["ok"] = true
                    _ = emit(out)
                }
            } catch { fail(message(error)) }
        case "stats.get":
            guard let stats = services.stats else { return fail("stats are not available") }
            do { _ = emit(["ok": true, "stats": try await stats.snapshot()]) } catch { fail("could not work out the stats") }
        case "prompts.list", "prompts.save", "prompts.delete", "prompts.select", "prompts.set_default":
            guard let prompts = services.prompts else { return fail("styles are not available") }
            do {
                switch op {
                case "prompts.list":
                    _ = emit(["ok": true, "prompts": await prompts.list()])
                case "prompts.save":
                    guard let name = object["name"] as? String, let prompt = object["prompt"] as? String, let mode = object["mode"] as? String else { return fail("missing name, prompt or mode") }
                    _ = emit(["ok": true, "profile": try await prompts.save(id: object["id"] as? String, name: name, prompt: prompt, mode: mode, includeContext: object["include_context"] as? Bool ?? false)])
                case "prompts.delete":
                    guard let id = object["id"] as? String else { return fail("missing id") }
                    try await prompts.delete(id: id)
                    _ = emit(["ok": true])
                case "prompts.select":
                    guard let mode = object["mode"] as? String, let selection = object["selection"] as? String else { return fail("missing mode or selection") }
                    try await prompts.select(mode: mode, selection: selection)
                    _ = emit(["ok": true])
                default:
                    guard let mode = object["mode"] as? String, let text = object["text"] as? String else { return fail("missing mode or text") }
                    try await prompts.setDefault(mode: mode, text: text)
                    _ = emit(["ok": true])
                }
            } catch { fail(message(error)) }
        case "speech.list", "speech.activate", "speech.download", "speech.delete", "speech.cancel":
            guard let speech = services.speech else { return fail("speech models are not available") }
            do {
                switch op {
                case "speech.list": _ = emit(["ok": true, "speech": await speech.list()])
                case "speech.cancel": try await speech.cancelDownload(); _ = emit(["ok": true])
                default:
                    guard let id = object["id"] as? String, !id.isEmpty, id.count <= 80 else { return fail("missing model id") }
                    switch op {
                    case "speech.activate": try await speech.activate(id: id)
                    case "speech.download": try await speech.download(id: id)
                    default: try await speech.delete(id: id)
                    }
                    _ = emit(["ok": true])
                }
            } catch { fail(message(error)) }
        default:
            fail("unknown op")
        }
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while data.count <= self.maxRequestBytes + 1 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if let newline = data.firstIndex(of: 0x0A) { return data.prefix(upTo: newline) }
        }
        return data.isEmpty ? nil : data
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}

// MARK: - Autotest

private final class AutotestFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { self.lock.lock(); self.flag = true; self.lock.unlock() }
    var value: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.flag }
}

/// Meetings with made-up content, so the protocol can be exercised end to end without the real store.
private struct FakeMeetings: EngineMeetingsProviding {
    let notesSaved: AutotestFlag
    let knownID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    func list() async throws -> [[String: Any]] { [["id": self.knownID.uuidString, "title": "Design sync", "words": 120]] }
    func get(id: UUID) async throws -> [String: Any]? {
        id == self.knownID ? ["id": id.uuidString, "title": "Design sync", "segments": [["start": 0.0, "speaker": "Me", "text": "hello"]]] : nil
    }
    func live() async -> [String: Any] {
        ["active": true, "id": self.knownID.uuidString, "title": "Design sync", "elapsed_seconds": 95, "rows": [["speaker": "you", "text": "hello", "partial": false], ["speaker": "them", "text": "hi the", "partial": true]]]
    }
    func saveNotes(id: UUID, text: String) async throws {
        guard id == self.knownID else { throw EngineMeetingsError.notFound }
        if text == "my notes" { self.notesSaved.set() }
    }
    func start(title: String, online: Bool) async throws -> [String: Any] {
        if title == "busy" { throw EngineMeetingsError.recordingBusy }
        return ["id": self.knownID.uuidString, "title": title + (online ? " (online)" : " (room)")]
    }
    func stop() async throws { throw EngineMeetingsError.notRecording }
    func renameSpeaker(id: UUID, speakerID: UUID, name: String) async throws {
        guard id == self.knownID else { throw EngineMeetingsError.notFound }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { throw EngineMeetingsError.badName }
    }
    func rename(id: UUID, title: String) async throws { guard id == self.knownID else { throw EngineMeetingsError.notFound } }
    func delete(id: UUID) async throws { guard id == self.knownID else { throw EngineMeetingsError.notFound } }
    func rateNotes(id: UUID, kind: String, rating: String, text: String?) async throws {
        guard id == self.knownID else { throw EngineMeetingsError.notFound }
        guard TrainingData.Rating(rawValue: rating) != nil else { throw TrainingData.Failure.badRating }
    }
    func generateNotes(id: UUID, kind: String, auto: Bool, emit: @escaping @Sendable ([String: Any]) -> Bool) async throws {
        guard id == self.knownID else { throw EngineMeetingsError.notFound }
        if auto { _ = emit(["event": "skipped", "reason": "not needed"]); return }
        _ = emit(["event": "progress", "message": "Reading part 1 of 2…"])
        _ = emit(["event": "progress", "message": "Reading part 2 of 2…"])
        _ = emit(["event": "done", "text": "notes for \(kind)"])
    }
}

/// Recent Writing with made-up content. Records what was asked so the autotest can check it.
private final class FakeWriting: EngineWritingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var deleted: [Int64] = []
    private var clearedBundle: String??
    private var enabled = true
    private var days = 14
    private var excluded: [String] = []
    var deletedIDs: [Int64] { self.lock.lock(); defer { self.lock.unlock() }; return self.deleted }
    var didClearAll: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.clearedBundle != nil }
    func list(search: String, limit: Int) async -> [[String: Any]] {
        search == "nothing" ? [] : [["id": 7, "app_name": "Notes", "latest": "draft text", "peak": "draft text longer", "version_count": 2, "limit": limit]]
    }
    func versions(entryID: Int64) async -> [[String: Any]] { [["id": 1, "at": 1.0, "text": "v1"]] }
    func delete(entryID: Int64) async { self.lock.lock(); self.deleted.append(entryID); self.lock.unlock() }
    func deleteAll(bundleID: String?) async { self.lock.lock(); self.clearedBundle = .some(bundleID); self.lock.unlock() }
    func settings() async -> [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        return ["enabled": self.enabled, "days": self.days, "excluded": self.excluded, "accessibility": true, "count": 1]
    }
    func updateSettings(_ changes: [String: Any]) async {
        self.lock.lock(); defer { self.lock.unlock() }
        if let e = changes["enabled"] as? Bool { self.enabled = e }
        if let d = changes["days"] as? Int, [7, 14, 30].contains(d) { self.days = d }
        if let x = changes["excluded"] as? [String] { self.excluded = x }
    }
}

/// Dictation history with made-up entries.
private final class FakeHistory: EngineHistoryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var starred = 0, deleted: [UUID] = [], cleared = false
    var starCount: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.starred }
    var deletedIDs: [UUID] { self.lock.lock(); defer { self.lock.unlock() }; return self.deleted }
    var wasCleared: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self.cleared }
    func list(search: String, starredOnly: Bool, limit: Int) async -> [String: Any] {
        ["entries": [["id": "A", "raw_text": "hello", "starred": starredOnly]], "matched": 1, "total": 5, "today_words": 12, "today_transcriptions": 2, "loading": false, "error": search]
    }
    func toggleStar(id: UUID) async { self.lock.lock(); self.starred += 1; self.lock.unlock() }
    func delete(id: UUID) async { self.lock.lock(); self.deleted.append(id); self.lock.unlock() }
    func clearAll() async { self.lock.lock(); self.cleared = true; self.lock.unlock() }
}

/// Settings backed by a dictionary, using the real validation, so the protocol and the refusals can be exercised.
private final class FakeSettings: EngineSettingsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = ["a.flag": true, "a.count": 5, "a.mode": "one"]
    private let kinds: [String: SettingKind] = ["a.flag": .bool, "a.count": .int(min: 1, max: 10), "a.mode": .choice([("one", "One"), ("two", "Two")])]
    func list() async -> [[String: Any]] { self.lock.lock(); defer { self.lock.unlock() }; return self.kinds.keys.sorted().map { ["key": $0, "kind": self.kinds[$0]!.name, "value": self.values[$0]!] } }
    func set(key: String, value: Any) async throws -> [String: Any] {
        guard let kind = self.kinds[key] else { throw EngineSettingsError.unknownKey }
        let clean = try kind.coerce(value)
        self.lock.lock(); self.values[key] = clean; self.lock.unlock()
        return ["key": key, "value": clean]
    }
}

/// A dictionary kept in memory, using the real rules.
private final class FakeDictionary: EngineDictionaryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(id: UUID, triggers: [String], replacement: String)] = []
    func list() async -> [[String: Any]] { self.lock.lock(); defer { self.lock.unlock() }; return self.entries.map { ["id": $0.id.uuidString, "triggers": $0.triggers, "replacement": $0.replacement] } }
    func save(id: UUID?, triggers: [String], replacement: String) async throws -> [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        let valid = try DictionaryRules.validate(triggers: triggers, replacement: replacement, others: self.entries.filter { $0.id != id }.map { ($0.id, $0.triggers) })
        if let id {
            guard let i = self.entries.firstIndex(where: { $0.id == id }) else { throw EngineDictionaryError.notFound }
            self.entries[i] = (id, valid.triggers, valid.replacement)
            return ["id": id.uuidString, "triggers": valid.triggers, "replacement": valid.replacement]
        }
        let new = (id: UUID(), triggers: valid.triggers, replacement: valid.replacement)
        self.entries.insert(new, at: 0)
        return ["id": new.id.uuidString, "triggers": new.triggers, "replacement": new.replacement]
    }
    func delete(id: UUID) async throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.entries.contains(where: { $0.id == id }) else { throw EngineDictionaryError.notFound }
        self.entries.removeAll { $0.id == id }
    }
}

private struct FakeStats: EngineStatsProviding {
    func snapshot() async throws -> [String: Any] {
        // Real code on made-up history: two dictations today, one two days ago.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        func entry(_ text: String, daysAgo: Int, app: String) -> TranscriptionHistoryEntry {
            TranscriptionHistoryEntry(timestamp: calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now, rawText: text, processedText: text, appName: app, windowTitle: "", wasAIProcessed: false)
        }
        let built = try StatsSnapshot.build(entries: [entry("one two three", daysAgo: 0, app: "Notes"), entry("four five", daysAgo: 0, app: "Notes"), entry("six", daysAgo: 2, app: "Mail")], now: now, calendar: calendar)
        return LiveEngineStats.describe(built, typingWPM: 40, weekdays: false, calendar: calendar)
    }
}

/// Styles in memory, using the real checks.
private final class FakePrompts: EnginePromptsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [[String: Any]] = []
    private var selected: [String: String] = ["dictate": "default", "edit": "default"]
    func list() async -> [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return ["profiles": self.profiles, "dictate": ["selected": self.selected["dictate"]!], "edit": ["selected": self.selected["edit"]!]] }
    func save(id: String?, name: String, prompt: String, mode: String, includeContext: Bool) async throws -> [String: Any] {
        let n = try PromptRules.cleanName(name), p = try PromptRules.cleanPrompt(prompt)
        _ = try PromptRules.mode(mode)
        self.lock.lock(); defer { self.lock.unlock() }
        if let id {
            guard let i = self.profiles.firstIndex(where: { $0["id"] as? String == id }) else { throw EnginePromptsError.notFound }
            self.profiles[i] = ["id": id, "name": n, "prompt": p, "mode": mode, "include_context": includeContext]
            return self.profiles[i]
        }
        let new: [String: Any] = ["id": "P\(self.profiles.count + 1)", "name": n, "prompt": p, "mode": mode, "include_context": includeContext]
        self.profiles.append(new)
        return new
    }
    func delete(id: String) async throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let doomed = self.profiles.first(where: { $0["id"] as? String == id }) else { throw EnginePromptsError.notFound }
        self.profiles.removeAll { $0["id"] as? String == id }
        if let mode = doomed["mode"] as? String, self.selected[mode] == "profile:\(id)" { self.selected[mode] = "default" }
    }
    func select(mode: String, selection: String) async throws {
        _ = try PromptRules.mode(mode)
        let (kind, id) = try PromptRules.parse(selection: selection)
        self.lock.lock(); defer { self.lock.unlock() }
        if kind == "profile", !self.profiles.contains(where: { $0["id"] as? String == id && $0["mode"] as? String == mode }) { throw EnginePromptsError.badSelection }
        self.selected[mode] = selection
    }
    func setDefault(mode: String, text: String) async throws { _ = try PromptRules.mode(mode); _ = try PromptRules.cleanPrompt(text) }
}

private struct FakeContacts: EngineContactsProviding {
    func lookup(emails: [String], phones: [String]) async -> [String: Any] { ["found": emails.first == "a@x.com", "full_name": "Ada Example", "emails": emails, "phones": phones] }
}

private final class FakeWords: EngineWordsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var words: [(text: String, aliases: [String])] = []
    func list() async -> [[String: Any]] { self.lock.lock(); defer { self.lock.unlock() }; return self.words.map { ["text": $0.text, "aliases": $0.aliases] } }
    func add(text: String, aliases: [String]) async throws -> [String: Any] {
        let c = try WordRules.clean(text: text, aliases: aliases)
        self.lock.lock(); defer { self.lock.unlock() }
        self.words.removeAll { $0.text.lowercased() == c.text.lowercased() }
        self.words.insert((c.text, c.aliases), at: 0)
        return ["text": c.text, "aliases": c.aliases]
    }
    func delete(text: String) async throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.words.contains(where: { $0.text == text }) else { throw EngineWordsError.notFound }
        self.words.removeAll { $0.text == text }
    }
    func export() async throws -> String { "{\"replacements\":[]}" }
    func importFile(_ json: String, replace: Bool) async throws -> [String: Any] {
        guard json.contains("replacements") else { throw EngineWordsError.unreadable }
        return ["replacements": 0, "words": self.words.count]
    }
}

private struct FakeShortcuts: EngineShortcutsProviding {
    func shortcuts() async -> [String: Any] { ["dictation": ["Fn"], "edit": "Right Option", "command": "", "cancel": "Esc", "paste_last": ""] }
    func inputs() async -> [String: Any] { ["inputs": [["uid": "mic1", "name": "Test Mic", "preferred": true, "default": true]]] }
}

private struct FakePermissions: EnginePermissionsProviding {
    func status() async -> [String: String] { Dictionary(uniqueKeysWithValues: EnginePermissionNames.all.map { ($0, $0 == "contacts" ? "denied" : "granted") }) }
    func request(_ name: String) async throws { if name == "full_disk_access" { throw EnginePermissionsError.notPromptable } }
}

private struct FakeActivity: EngineActivityProviding {
    func snapshot() async -> [String: Any] { ["recording": false, "meeting_processing": false, "dictating": true, "busy": true] }
}

private final class FakeSpeech: EngineSpeechProviding, @unchecked Sendable {
    private let lock = NSLock()
    var calls: [String] = []
    func list() async -> [String: Any] { ["models": [["id": "m1", "name": "Model One", "installed": true, "active": true]], "blocked": false] }
    private func note(_ s: String) { self.lock.lock(); self.calls.append(s); self.lock.unlock() }
    func activate(id: String) async throws { if id == "missing" { throw EngineSpeechError.unknownModel }; if id == "notyet" { throw EngineSpeechError.notInstalled }; self.note("activate:\(id)") }
    func download(id: String) async throws { if id == "busy" { throw EngineSpeechError.busy }; self.note("download:\(id)") }
    func cancelDownload() async throws { throw EngineSpeechError.nothingToCancel }
    func delete(id: String) async throws { if id == "m1" { throw EngineSpeechError.activeModel }; self.note("delete:\(id)") }
}

/// `LAVOIX_ENGINE_SOCKET_AUTOTEST=1` serves fakes on a temp socket and talks to it as a client.
nonisolated enum EngineSocketAutotest {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["LAVOIX_ENGINE_SOCKET_AUTOTEST"] == "1" else { return }
        Task.detached {
            var failures = 0
            func check(_ name: String, _ ok: Bool) { print((ok ? "PASS " : "FAIL ") + name); if !ok { failures += 1 } }
            // Unix socket paths top out at 104 bytes, so the system temp folder (very long on macOS) is too deep.
            let base = URL(fileURLWithPath: "/tmp/lve-\(UUID().uuidString.prefix(8))")
            let url = base.appendingPathComponent("private/engine.sock")
            let secret = "SECRET-PLANTED-TEXT"
            let warmed = AutotestFlag()
            let notesSaved = AutotestFlag()
            let fakeWriting = FakeWriting()
            let fakeHistory = FakeHistory()
            let fakeSpeech = FakeSpeech()
            let services = EngineSocket.Services(
                generator: { system, user, maxTokens in
                    if user.contains("explode") { throw NSError(domain: "t", code: 1) }
                    return "echo(\(system.count),\(user.count),\(maxTokens)):" + user.uppercased()
                },
                streamGenerator: { _, user, _ in
                    AsyncThrowingStream { continuation in
                        Task {
                            if user.contains("explode") { continuation.finish(throwing: NSError(domain: "t", code: 2)); return }
                            for word in user.split(separator: " ") { continuation.yield(String(word) + " "); try? await Task.sleep(nanoseconds: 2_000_000) }
                            continuation.finish()
                        }
                    }
                },
                status: { ("test-model", true, false) },
                warm: { warmed.set() },
                meetings: FakeMeetings(notesSaved: notesSaved),
                writing: fakeWriting,
                history: fakeHistory,
                settings: FakeSettings(),
                dictionary: FakeDictionary(),
                stats: FakeStats(),
                prompts: FakePrompts(),
                speech: fakeSpeech,
                activity: FakeActivity(),
                contacts: FakeContacts(),
                permissions: FakePermissions(),
                shortcuts: FakeShortcuts(),
                words: FakeWords()
            )
            check("server starts", EngineSocket.start(at: url, services: services))
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let dirAttrs = try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            check("socket is owner-only (0600)", (attrs?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            check("folder is owner-only (0700)", (dirAttrs?[.posixPermissions] as? NSNumber)?.intValue == 0o700)

            func lines(_ payload: String) -> [[String: Any]] {
                Self.roundTrip(url: url, payload: payload).compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            }
            func ask(_ payload: String) -> [String: Any]? { lines(payload).first }

            let status = ask(#"{"op":"status"}"#)
            check("status reports the model", status?["ok"] as? Bool == true && status?["model"] as? String == "test-model" && status?["downloaded"] as? Bool == true)
            let gen = ask(#"{"op":"generate","system":"sys","user":"hello \#(secret)","max_tokens":50}"#)
            check("generate returns the text", (gen?["text"] as? String) == "echo(3,\(6 + secret.count),50):HELLO \(secret)")
            check("max_tokens is clamped to 800", (ask(#"{"op":"generate","user":"x","max_tokens":999999}"#)?["text"] as? String)?.hasPrefix("echo(0,1,800)") == true)
            check("generator failure is reported, not a crash", ask(#"{"op":"generate","user":"explode"}"#)?["ok"] as? Bool == false)
            check("warm returns at once and triggers the warmer", ask(#"{"op":"warm"}"#)?["ok"] as? Bool == true && warmed.value)

            // streaming
            let stream = lines(#"{"op":"generate_stream","user":"one two three"}"#)
            let tokens = stream.filter { $0["event"] as? String == "token" }.compactMap { $0["text"] as? String }
            check("a stream sends each piece as its own line", tokens == ["one ", "two ", "three "])
            check("a stream ends with done and a duration", stream.last?["event"] as? String == "done" && stream.last?["ms"] is Int)
            let broken = lines(#"{"op":"generate_stream","user":"explode"}"#)
            check("a stream that fails ends with an error event", broken.last?["event"] as? String == "error")
            check("a stream needs a prompt", ask(#"{"op":"generate_stream"}"#)?["event"] as? String == "error")

            // meetings
            let id = "11111111-2222-3333-4444-555555555555"
            let list = ask(#"{"op":"meetings.list"}"#)
            check("meetings.list returns the meetings", (list?["meetings"] as? [[String: Any]])?.first?["title"] as? String == "Design sync")
            let live = (ask(#"{"op":"meetings.live"}"#)?["live"] as? [String: Any])
            check("meetings.live reports the recording with its latest captions", live?["active"] as? Bool == true && (live?["rows"] as? [[String: Any]])?.count == 2 && (live?["rows"] as? [[String: Any]])?.last?["partial"] as? Bool == true)
            let got = ask(#"{"op":"meetings.get","id":"\#(id)"}"#)
            check("meetings.get returns one meeting with its segments", ((got?["meeting"] as? [String: Any])?["segments"] as? [Any])?.count == 1)
            check("meetings.get on an unknown id says so", ask(#"{"op":"meetings.get","id":"\#(UUID().uuidString)"}"#)?["ok"] as? Bool == false)
            check("meetings.get rejects a bad id", ask(#"{"op":"meetings.get","id":"not-a-uuid"}"#)?["ok"] as? Bool == false)
            check("meetings.notes_save saves", ask(#"{"op":"meetings.notes_save","id":"\#(id)","text":"my notes"}"#)?["ok"] as? Bool == true && notesSaved.value)
            let gennotes = lines(#"{"op":"meetings.notes_generate","id":"\#(id)","kind":"executive"}"#)
            check("notes generation reports progress then the result", gennotes.filter { $0["event"] as? String == "progress" }.count == 2 && gennotes.last?["event"] as? String == "done" && gennotes.last?["text"] as? String == "notes for executive")
            check("auto notes can say they were not needed", lines(#"{"op":"meetings.notes_generate","id":"\#(id)","auto":true}"#).last?["event"] as? String == "skipped")
            check("notes generation for a missing meeting ends with an error event", lines(#"{"op":"meetings.notes_generate","id":"\#(UUID().uuidString)"}"#).last?["event"] as? String == "error")

            // training data (real code, in a temp folder)
            let trainingRoot = base.appendingPathComponent("training")
            TrainingData.rootOverride = trainingRoot
            let meetingA = UUID(), meetingB = UUID(), meetingC = UUID()
            TrainingData.recordPrompt(system: "SYS", user: "USER A", model: "m", output: "Notes A")
            TrainingData.recordPrompt(system: "SYS", user: "USER B", model: "m", output: "Notes B")
            TrainingData.recordPrompt(system: "SYS", user: "USER C", model: "m", output: "Notes C")
            check("training: a set of notes can be rated once its input was recorded", TrainingData.canRate(meeting: meetingA, kind: "executive", notes: "Notes A") && !TrainingData.canRate(meeting: meetingA, kind: "executive", notes: "Other notes"))
            check("training: rating notes with no recorded input is refused", (try? TrainingData.rate(meeting: meetingA, kind: "executive", rating: .good, notes: "Other notes", corrected: nil)) == nil)
            check("training: a good rating is saved", (try? TrainingData.rate(meeting: meetingA, kind: "executive", rating: .good, notes: "Notes A", corrected: nil)) != nil && TrainingData.rating(meeting: meetingA, kind: "executive") == "good")
            check("training: an edit needs corrected text", (try? TrainingData.rate(meeting: meetingB, kind: "executive", rating: .edited, notes: "Notes B", corrected: "  ")) == nil)
            check("training: an edit keeps the corrected text", (try? TrainingData.rate(meeting: meetingB, kind: "executive", rating: .edited, notes: "Notes B", corrected: "Fixed B")) != nil && TrainingData.rating(meeting: meetingB, kind: "executive") == "edited")
            check("training: a rating can be changed later, even after the notes were replaced by the corrected text", (try? TrainingData.rate(meeting: meetingB, kind: "executive", rating: .good, notes: "Fixed B", corrected: nil)) != nil && TrainingData.rating(meeting: meetingB, kind: "executive") == "good")
            _ = try? TrainingData.rate(meeting: meetingB, kind: "executive", rating: .edited, notes: "Fixed B", corrected: "Fixed B")
            check("training: bad notes are rated but kept out of the export", (try? TrainingData.rate(meeting: meetingC, kind: "executive", rating: .bad, notes: "Notes C", corrected: nil)) != nil)
            let tstat = (ask(#"{"op":"training.status"}"#)?["training"] as? [String: Any])
            check("training.status counts by rating and carries no text", tstat?["good"] as? Int == 1 && tstat?["bad"] as? Int == 1 && tstat?["edited"] as? Int == 1 && tstat?["usable"] as? Int == 2 && !(String(data: (try? JSONSerialization.data(withJSONObject: tstat ?? [:])) ?? Data(), encoding: .utf8) ?? "").contains("Notes"))
            let exp = (ask(#"{"op":"training.export"}"#)?["export"] as? [String: Any])
            check("training.export writes the usable examples and leaves bad ones out", (exp?["train"] as? Int ?? 0) + (exp?["valid"] as? Int ?? 0) == 2)
            let trainText = (try? String(contentsOf: TrainingData.exportDir.appendingPathComponent("train.jsonl"), encoding: .utf8)) ?? ""
            let validText = (try? String(contentsOf: TrainingData.exportDir.appendingPathComponent("valid.jsonl"), encoding: .utf8)) ?? ""
            let exported = (trainText + validText).split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            check("training.export is chat-format JSON lines (system, user, assistant)", exported.count == 2 && exported.allSatisfy { ($0["messages"] as? [[String: String]])?.map { $0["role"] ?? "" } == ["system", "user", "assistant"] })
            check("training.export teaches your correction for edited notes and the model's own words for good ones", (trainText + validText).contains("Fixed B") && (trainText + validText).contains("Notes A") && !(trainText + validText).contains("Notes C"))
            check("training.export keeps a validation set when there are two or more examples", (exp?["valid"] as? Int ?? 0) >= 1)
            let perms = (try? FileManager.default.attributesOfItem(atPath: TrainingData.exportDir.appendingPathComponent("train.jsonl").path))?[.posixPermissions] as? NSNumber
            let rootPerms = (try? FileManager.default.attributesOfItem(atPath: trainingRoot.path))?[.posixPermissions] as? NSNumber
            check("training files are owner-only", perms?.intValue == 0o600 && rootPerms?.intValue == 0o700)
            check("meetings.notes_feedback refuses a bad rating", ask(#"{"op":"meetings.notes_feedback","id":"\#(id)","kind":"executive","rating":"meh"}"#)?["ok"] as? Bool == false)
            check("meetings.notes_feedback works for a known meeting", ask(#"{"op":"meetings.notes_feedback","id":"\#(id)","kind":"executive","rating":"good"}"#)?["ok"] as? Bool == true)
            check("training.rate_ask keeps an answer once however often it is rated, and a correction is needed for edited", ask(#"{"op":"training.rate_ask","system":"S","user":"U question","output":"A answer","rating":"good"}"#)?["ok"] as? Bool == true && ask(#"{"op":"training.rate_ask","system":"S","user":"U question","output":"A answer","rating":"edited","corrected":"A better answer"}"#)?["ok"] as? Bool == true && ask(#"{"op":"training.rate_ask","system":"S","user":"U question","output":"A answer","rating":"edited"}"#)?["ok"] as? Bool == false && ((ask(#"{"op":"training.status"}"#)?["training"] as? [String: Any])?["usable"] as? Int) == 3)
            check("training.clear removes everything", ask(#"{"op":"training.clear"}"#)?["ok"] as? Bool == true && !FileManager.default.fileExists(atPath: trainingRoot.path) && (ask(#"{"op":"training.status"}"#)?["training"] as? [String: Any])?["usable"] as? Int == 0)
            TrainingData.rootOverride = nil

            // meeting controls
            let started = ask(#"{"op":"meetings.start","title":"Sync","online":true}"#)?["meeting"] as? [String: Any]
            check("meetings.start returns the new meeting", started?["id"] as? String == id && started?["title"] as? String == "Sync (online)")
            check("meetings.start for the room", (ask(#"{"op":"meetings.start","title":"Chat"}"#)?["meeting"] as? [String: Any])?["title"] as? String == "Chat (room)")
            check("meetings.start while busy is refused with a reason", ask(#"{"op":"meetings.start","title":"busy"}"#)?["error"] as? String == EngineMeetingsError.recordingBusy.errorDescription)
            check("meetings.stop with nothing recording is refused", ask(#"{"op":"meetings.stop"}"#)?["ok"] as? Bool == false)
            check("meetings.rename works for a known meeting", ask(#"{"op":"meetings.rename","id":"\#(id)","title":"New"}"#)?["ok"] as? Bool == true)
            check("meetings.rename for an unknown meeting is refused", ask(#"{"op":"meetings.rename","id":"\#(UUID().uuidString)","title":"New"}"#)?["ok"] as? Bool == false)
            let sp = UUID().uuidString
            check("meetings.rename_speaker works", ask(#"{"op":"meetings.rename_speaker","id":"\#(id)","speaker":"\#(sp)","name":"Dana"}"#)?["ok"] as? Bool == true)
            check("meetings.rename_speaker refuses an empty name", ask(#"{"op":"meetings.rename_speaker","id":"\#(id)","speaker":"\#(sp)","name":"  "}"#)?["ok"] as? Bool == false)
            check("meetings.rename_speaker refuses a bad speaker id", ask(#"{"op":"meetings.rename_speaker","id":"\#(id)","speaker":"x","name":"Dana"}"#)?["ok"] as? Bool == false)
            check("meetings.delete works for a known meeting", ask(#"{"op":"meetings.delete","id":"\#(id)"}"#)?["ok"] as? Bool == true)
            check("meetings.delete rejects a bad id", ask(#"{"op":"meetings.delete","id":"nope"}"#)?["ok"] as? Bool == false)

            // recent writing
            let wl = ask(#"{"op":"writing.list","search":"x","limit":5}"#)
            check("writing.list returns entries", (wl?["entries"] as? [[String: Any]])?.first?["app_name"] as? String == "Notes" && (wl?["entries"] as? [[String: Any]])?.first?["limit"] as? Int == 5)
            check("writing.list with no match is empty", (ask(#"{"op":"writing.list","search":"nothing"}"#)?["entries"] as? [Any])?.isEmpty == true)
            check("writing.versions returns versions", (ask(#"{"op":"writing.versions","entry":7}"#)?["versions"] as? [[String: Any]])?.first?["text"] as? String == "v1")
            check("writing.versions needs an entry", ask(#"{"op":"writing.versions"}"#)?["ok"] as? Bool == false)
            check("writing.delete deletes that entry", ask(#"{"op":"writing.delete","entry":7}"#)?["ok"] as? Bool == true && fakeWriting.deletedIDs == [7])
            check("writing.delete needs an entry", ask(#"{"op":"writing.delete"}"#)?["ok"] as? Bool == false)
            check("writing.delete_all clears", ask(#"{"op":"writing.delete_all"}"#)?["ok"] as? Bool == true && fakeWriting.didClearAll)
            let ws = ask(#"{"op":"writing.settings_set","enabled":false,"days":30,"excluded":["com.x.y"]}"#)?["settings"] as? [String: Any]
            check("writing.settings_set applies and returns the settings", ws?["enabled"] as? Bool == false && ws?["days"] as? Int == 30 && ws?["excluded"] as? [String] == ["com.x.y"])
            check("writing.settings_set ignores a retention that is not offered", (ask(#"{"op":"writing.settings_set","days":3}"#)?["settings"] as? [String: Any])?["days"] as? Int == 30)
            check("writing.settings reads them back", (ask(#"{"op":"writing.settings"}"#)?["settings"] as? [String: Any])?["enabled"] as? Bool == false)

            // history
            let hl = ask(#"{"op":"history.list","search":"abc","starred":true,"limit":10}"#)?["history"] as? [String: Any]
            check("history.list returns entries and counts", (hl?["entries"] as? [[String: Any]])?.first?["raw_text"] as? String == "hello" && hl?["total"] as? Int == 5 && hl?["today_words"] as? Int == 12)
            check("history.list passes the search and the starred filter", hl?["error"] as? String == "abc" && (hl?["entries"] as? [[String: Any]])?.first?["starred"] as? Bool == true)
            let hid = UUID().uuidString
            check("history.star toggles", ask(#"{"op":"history.star","id":"\#(hid)"}"#)?["ok"] as? Bool == true && fakeHistory.starCount == 1)
            check("history.delete deletes that entry", ask(#"{"op":"history.delete","id":"\#(hid)"}"#)?["ok"] as? Bool == true && fakeHistory.deletedIDs.map(\.uuidString) == [hid])
            check("history.delete rejects a bad id", ask(#"{"op":"history.delete","id":"nope"}"#)?["ok"] as? Bool == false)
            check("history.clear clears", ask(#"{"op":"history.clear"}"#)?["ok"] as? Bool == true && fakeHistory.wasCleared)

            // settings bridge
            check("settings.list lists them", (ask(#"{"op":"settings.list"}"#)?["settings"] as? [[String: Any]])?.count == 3)
            check("settings.set changes a bool", (ask(#"{"op":"settings.set","key":"a.flag","value":false}"#)?["setting"] as? [String: Any])?["value"] as? Bool == false)
            check("settings.set changes an int in range", (ask(#"{"op":"settings.set","key":"a.count","value":7}"#)?["setting"] as? [String: Any])?["value"] as? Int == 7)
            check("settings.set refuses an unknown key", ask(#"{"op":"settings.set","key":"api.key","value":"x"}"#)?["ok"] as? Bool == false)
            check("settings.set refuses a number for a bool", ask(#"{"op":"settings.set","key":"a.flag","value":1}"#)?["ok"] as? Bool == false)
            check("settings.set refuses a bool for an int", ask(#"{"op":"settings.set","key":"a.count","value":true}"#)?["ok"] as? Bool == false)
            check("settings.set refuses an out-of-range int", ask(#"{"op":"settings.set","key":"a.count","value":99}"#)?["ok"] as? Bool == false)
            check("settings.set refuses a fractional int", ask(#"{"op":"settings.set","key":"a.count","value":2.5}"#)?["ok"] as? Bool == false)
            check("settings.set refuses a choice that is not offered", ask(#"{"op":"settings.set","key":"a.mode","value":"three"}"#)?["ok"] as? Bool == false)
            check("settings.set accepts a choice that is offered", (ask(#"{"op":"settings.set","key":"a.mode","value":"two"}"#)?["setting"] as? [String: Any])?["value"] as? String == "two")
            check("a refused value left the setting as it was", (ask(#"{"op":"settings.list"}"#)?["settings"] as? [[String: Any]])?.first(where: { $0["key"] as? String == "a.count" })?["value"] as? Int == 7)
            // the real list: unique keys, every value of the declared kind, every choice's current value is one of its options
            let real = await MainActor.run { SettingsRegistry.all.map { $0.describe() } }
            check("real settings: keys are unique", Set(real.compactMap { $0["key"] as? String }).count == real.count && !real.isEmpty)
            check("real settings: every value matches its kind", real.allSatisfy { d in
                switch d["kind"] as? String {
                case "bool": d["value"] is Bool
                case "int": d["value"] is Int
                case "double": d["value"] is Double
                case "text": d["value"] is String
                case "choice": (d["options"] as? [[String: Any]])?.contains { $0["id"] as? String == d["value"] as? String } == true
                default: false
                }
            })
            check("real settings: nothing secret-looking is exposed", !real.contains { d in ["api", "secret", "token", "password", "credential", "message_text", "keep_message"].contains { (d["key"] as? String ?? "").lowercased().contains($0) } })

            // dictionary
            let d1 = ask(#"{"op":"dictionary.save","triggers":["  Fluid Voice ","fluid boys","FLUID VOICE"],"replacement":"FluidVoice"}"#)?["entry"] as? [String: Any]
            check("dictionary.save adds an entry with cleaned, de-duplicated, lowercase triggers", d1?["triggers"] as? [String] == ["fluid voice", "fluid boys"] && d1?["replacement"] as? String == "FluidVoice")
            let d1id = d1?["id"] as? String ?? ""
            check("dictionary.list returns it", (ask(#"{"op":"dictionary.list"}"#)?["entries"] as? [[String: Any]])?.count == 1)
            check("dictionary.save refuses a trigger another entry already uses", ask(#"{"op":"dictionary.save","triggers":["fluid boys"],"replacement":"X"}"#)?["error"] as? String == EngineDictionaryError.duplicate("fluid boys").errorDescription)
            check("dictionary.save lets an entry keep its own triggers when edited", (ask(#"{"op":"dictionary.save","id":"\#(d1id)","triggers":["fluid voice"],"replacement":"FluidVoice 2"}"#)?["entry"] as? [String: Any])?["replacement"] as? String == "FluidVoice 2")
            check("dictionary.save refuses no triggers", ask(#"{"op":"dictionary.save","triggers":["  "],"replacement":"X"}"#)?["error"] as? String == EngineDictionaryError.noTriggers.errorDescription)
            check("dictionary.save refuses an empty replacement", ask(#"{"op":"dictionary.save","triggers":["a"],"replacement":""}"#)?["error"] as? String == EngineDictionaryError.noReplacement.errorDescription)
            check("dictionary.save refuses a very long phrase", ask(#"{"op":"dictionary.save","triggers":["\#(String(repeating: "a", count: 81))"],"replacement":"X"}"#)?["ok"] as? Bool == false)
            check("dictionary.save refuses an unknown id", ask(#"{"op":"dictionary.save","id":"\#(UUID().uuidString)","triggers":["zzz"],"replacement":"X"}"#)?["ok"] as? Bool == false)
            check("dictionary.save refuses a bad id", ask(#"{"op":"dictionary.save","id":"nope","triggers":["zzz"],"replacement":"X"}"#)?["ok"] as? Bool == false)
            check("dictionary.delete removes it", ask(#"{"op":"dictionary.delete","id":"\#(d1id)"}"#)?["ok"] as? Bool == true && (ask(#"{"op":"dictionary.list"}"#)?["entries"] as? [Any])?.isEmpty == true)
            check("dictionary.delete of a missing entry is refused", ask(#"{"op":"dictionary.delete","id":"\#(d1id)"}"#)?["ok"] as? Bool == false)

            // stats
            let st = ask(#"{"op":"stats.get"}"#)?["stats"] as? [String: Any]
            check("stats.get adds up words and dictations", st?["total_words"] as? Int == 6 && st?["total_transcriptions"] as? Int == 3)
            check("stats.get ranks the apps", (st?["top_apps"] as? [[String: Any]])?.first?["name"] as? String == "Notes" && (st?["top_apps"] as? [[String: Any]])?.first?["sessions"] as? Int == 2)
            check("stats.get has 24 hours and 180 days of activity", (st?["hourly"] as? [Int])?.count == 24 && (st?["activity"] as? [[String: Any]])?.count == 180)
            check("stats.get's streak counts today but not the gap", st?["current_streak"] as? Int == 1 && st?["best_streak"] as? Int == 1)
            check("stats.get carries no dictation text", !(String(data: (try? JSONSerialization.data(withJSONObject: st ?? [:])) ?? Data(), encoding: .utf8) ?? "").contains("three"))

            // cleanup styles
            let pr = ask(#"{"op":"prompts.save","name":"  Formal  ","prompt":"Make it formal.","mode":"dictate","include_context":true}"#)?["profile"] as? [String: Any]
            let prid = pr?["id"] as? String ?? ""
            check("prompts.save adds a style with a trimmed name", pr?["name"] as? String == "Formal" && !prid.isEmpty)
            check("prompts.save refuses an empty name", ask(#"{"op":"prompts.save","name":" ","prompt":"x","mode":"dictate"}"#)?["error"] as? String == EnginePromptsError.badName.errorDescription)
            check("prompts.save refuses a mode that does not exist", ask(#"{"op":"prompts.save","name":"A","prompt":"x","mode":"rewrite"}"#)?["error"] as? String == EnginePromptsError.badMode.errorDescription)
            check("prompts.save refuses a huge prompt", ask(#"{"op":"prompts.save","name":"A","prompt":"\#(String(repeating: "a", count: 8001))","mode":"edit"}"#)?["ok"] as? Bool == false)
            check("prompts.save edits an existing style", (ask(#"{"op":"prompts.save","id":"\#(prid)","name":"Formal 2","prompt":"y","mode":"dictate"}"#)?["profile"] as? [String: Any])?["name"] as? String == "Formal 2")
            check("prompts.save refuses an unknown id", ask(#"{"op":"prompts.save","id":"nope","name":"A","prompt":"x","mode":"dictate"}"#)?["ok"] as? Bool == false)
            check("prompts.select picks a style", ask(#"{"op":"prompts.select","mode":"dictate","selection":"profile:\#(prid)"}"#)?["ok"] as? Bool == true && ((ask(#"{"op":"prompts.list"}"#)?["prompts"] as? [String: Any])?["dictate"] as? [String: Any])?["selected"] as? String == "profile:\(prid)")
            check("prompts.select refuses a style from the other mode", ask(#"{"op":"prompts.select","mode":"edit","selection":"profile:\#(prid)"}"#)?["ok"] as? Bool == false)
            check("prompts.select refuses nonsense", ask(#"{"op":"prompts.select","mode":"dictate","selection":"whatever"}"#)?["ok"] as? Bool == false)
            check("prompts.select off is allowed", ask(#"{"op":"prompts.select","mode":"edit","selection":"off"}"#)?["ok"] as? Bool == true)
            check("prompts.delete resets the selection to default", ask(#"{"op":"prompts.delete","id":"\#(prid)"}"#)?["ok"] as? Bool == true && ((ask(#"{"op":"prompts.list"}"#)?["prompts"] as? [String: Any])?["dictate"] as? [String: Any])?["selected"] as? String == "default")
            check("prompts.delete of a missing style is refused", ask(#"{"op":"prompts.delete","id":"\#(prid)"}"#)?["ok"] as? Bool == false)
            check("prompts.set_default works and refuses a bad mode", ask(#"{"op":"prompts.set_default","mode":"edit","text":"Be brief."}"#)?["ok"] as? Bool == true && ask(#"{"op":"prompts.set_default","mode":"x","text":"a"}"#)?["ok"] as? Bool == false)

            // speech models
            check("speech.list lists the models", ((ask(#"{"op":"speech.list"}"#)?["speech"] as? [String: Any])?["models"] as? [[String: Any]])?.first?["name"] as? String == "Model One")
            check("speech.download starts a download", ask(#"{"op":"speech.download","id":"m2"}"#)?["ok"] as? Bool == true && fakeSpeech.calls.contains("download:m2"))
            check("speech.download while busy says why", ask(#"{"op":"speech.download","id":"busy"}"#)?["error"] as? String == EngineSpeechError.busy.errorDescription)
            check("speech.activate switches", ask(#"{"op":"speech.activate","id":"m2"}"#)?["ok"] as? Bool == true && fakeSpeech.calls.contains("activate:m2"))
            check("speech.activate refuses one that is not installed", ask(#"{"op":"speech.activate","id":"notyet"}"#)?["error"] as? String == EngineSpeechError.notInstalled.errorDescription)
            check("speech.activate refuses an unknown model", ask(#"{"op":"speech.activate","id":"missing"}"#)?["ok"] as? Bool == false)
            check("speech.delete refuses the model in use", ask(#"{"op":"speech.delete","id":"m1"}"#)?["error"] as? String == EngineSpeechError.activeModel.errorDescription)
            check("speech.delete deletes another model", ask(#"{"op":"speech.delete","id":"m3"}"#)?["ok"] as? Bool == true && fakeSpeech.calls.contains("delete:m3"))
            check("speech.cancel with nothing running says so", ask(#"{"op":"speech.cancel"}"#)?["error"] as? String == EngineSpeechError.nothingToCancel.errorDescription)
            check("speech actions need a model id", ask(#"{"op":"speech.download"}"#)?["ok"] as? Bool == false)

            // activity
            let act = ask(#"{"op":"activity"}"#)?["activity"] as? [String: Any]
            check("activity reports what the engine is busy with", act?["dictating"] as? Bool == true && act?["busy"] as? Bool == true && act?["recording"] as? Bool == false)

            // boost words and dictionary files
            do {
                check("words.add keeps a word with its other spellings", ((ask(#"{"op":"words.add","text":"  Qwen ","aliases":["quen","QUEN","  ","qwen"]}"#)?["word"] as? [String: Any])?["aliases"] as? [String]) == ["quen"])
                check("words.list returns it", ((ask(#"{"op":"words.list"}"#)?["words"] as? [[String: Any]])?.first?["text"] as? String) == "Qwen")
                check("words.add refuses an empty word", ask(#"{"op":"words.add","text":"   "}"#)?["ok"] as? Bool == false)
                check("words.delete removes it, and a missing word is refused", ask(#"{"op":"words.delete","text":"Qwen"}"#)?["ok"] as? Bool == true && ask(#"{"op":"words.delete","text":"Qwen"}"#)?["ok"] as? Bool == false)
                check("dictionary.export returns a file", (ask(#"{"op":"dictionary.export"}"#)?["file"] as? String)?.contains("replacements") == true)
                check("dictionary.import reads a file and refuses nonsense", ask(#"{"op":"dictionary.import","file":"{\"replacements\":[]}"}"#)?["ok"] as? Bool == true && ask(#"{"op":"dictionary.import","file":"hello"}"#)?["ok"] as? Bool == false)
            }
            // shortcuts and microphones
            do {
                let sc = ask(#"{"op":"shortcuts.get"}"#)?["shortcuts"] as? [String: Any]
                check("shortcuts.get reports the dictation keys", (sc?["dictation"] as? [String]) == ["Fn"] && sc?["cancel"] as? String == "Esc")
                let inputs = (ask(#"{"op":"audio.inputs"}"#)?["audio"] as? [String: Any])?["inputs"] as? [[String: Any]]
                check("audio.inputs lists the microphones and which is preferred", inputs?.first?["name"] as? String == "Test Mic" && inputs?.first?["preferred"] as? Bool == true)
            }
            // permissions
            do {
                check("macOS authorization states map to granted, denied or not_asked",
                      EnginePermissionState.map(AVAuthorizationStatus.authorized) == "granted" && EnginePermissionState.map(AVAuthorizationStatus.notDetermined) == "not_asked"
                        && EnginePermissionState.map(AVAuthorizationStatus.denied) == "denied" && EnginePermissionState.map(AVAuthorizationStatus.restricted) == "denied"
                        && EnginePermissionState.map(CNAuthorizationStatus.authorized) == "granted" && EnginePermissionState.map(CNAuthorizationStatus.notDetermined) == "not_asked"
                        && EnginePermissionState.map(CNAuthorizationStatus.denied) == "denied" && EnginePermissionState.map(trusted: true) == "granted" && EnginePermissionState.map(trusted: false) == "denied")
                let ps = ask(#"{"op":"permissions.status"}"#)?["permissions"] as? [String: String]
                check("permissions.status reports all five permissions", Set(ps?.keys.map { $0 } ?? []) == Set(EnginePermissionNames.all))
                check("permissions.request works for a promptable permission", ask(#"{"op":"permissions.request","name":"microphone"}"#)?["ok"] as? Bool == true)
                check("permissions.request refuses Full Disk Access and unknown names", ask(#"{"op":"permissions.request","name":"full_disk_access"}"#)?["ok"] as? Bool == false && ask(#"{"op":"permissions.request","name":"nope"}"#)?["ok"] as? Bool == false)
            }
            // contacts
            do {
                let card = CNMutableContact()
                card.birthday = DateComponents(year: 1990, month: 3, day: 4)
                card.dates = [CNLabeledValue(label: CNLabelDateAnniversary, value: DateComponents(month: 6, day: 12) as NSDateComponents)]
                let addr = CNMutablePostalAddress(); addr.street = "1 Secret Street"; addr.city = "Providence"; addr.state = "RI"; addr.postalCode = "02903"; addr.country = "USA"
                card.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: addr)]
                card.contactRelations = [CNLabeledValue(label: CNLabelContactRelationSister, value: CNContactRelation(name: "Priya"))]
                card.urlAddresses = [CNLabeledValue(label: CNLabelWork, value: "https://www.linkedin.com/in/ada" as NSString)]
                card.socialProfiles = [CNLabeledValue(label: nil, value: CNSocialProfile(urlString: "https://instagram.com/ada", username: "ada", userIdentifier: nil, service: "Instagram"))]
                let d = EngineContactDetails.details(of: card)
                let blob = String(describing: d)
                check("contact details carry the birthday as month and day only", (d["birthday"] as? [String: Int]) == ["month": 3, "day": 4] && !blob.contains("1990"))
                check("contact details carry other dates, relatives and links", ((d["dates"] as? [[String: Any]])?.first?["month"] as? Int) == 6 && ((d["relations"] as? [[String: Any]])?.first?["name"] as? String) == "Priya" && ((d["urls"] as? [String])?.count == 2))
                check("contact details keep the city but never the street or postcode", ((d["addresses"] as? [[String: Any]])?.first?["city"] as? String) == "Providence" && !blob.contains("Secret") && !blob.contains("02903"))
                check("a card with nothing extra has no extra keys", EngineContactDetails.details(of: CNMutableContact()).isEmpty)
            }
            let cl = ask(#"{"op":"contacts.lookup","emails":["a@x.com"],"phones":["+14155551234"]}"#)?["contact"] as? [String: Any]
            check("contacts.lookup returns the card for the addresses it was given", cl?["found"] as? Bool == true && cl?["full_name"] as? String == "Ada Example")
            check("contacts.lookup says when nobody matches", ((ask(#"{"op":"contacts.lookup","emails":["nobody@x.com"]}"#)?["contact"] as? [String: Any])?["found"] as? Bool) == false)
            check("contacts.lookup needs an address or number, never a name", ask(#"{"op":"contacts.lookup","name":"Ada"}"#)?["ok"] as? Bool == false)

            // robustness
            check("garbage is rejected", ask("not json")?["ok"] as? Bool == false)
            check("unknown op is rejected", ask(#"{"op":"rm -rf"}"#)?["ok"] as? Bool == false)
            check("missing user is rejected", ask(#"{"op":"generate"}"#)?["ok"] as? Bool == false)
            let big = ask(#"{"op":"generate","user":"\#(String(repeating: "a", count: 1_100_000))"}"#)
            check("oversized request is rejected", big == nil || big?["ok"] as? Bool == false)
            // a listener that leaves mid-stream must not crash or wedge the server
            _ = Self.roundTrip(url: url, payload: #"{"op":"generate_stream","user":"\#(String(repeating: "word ", count: 400))"}"#, stopAfterFirstLine: true)
            check("still serving after a listener left mid-stream and after bad requests", ask(#"{"op":"status"}"#)?["ok"] as? Bool == true)
            EngineSocket.stop(removing: url)
            check("stop removes the socket", !FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: base)
            print(failures == 0 ? "ENGINE SOCKET AUTOTEST ALL PASSED" : "ENGINE SOCKET AUTOTEST \(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    /// Minimal blocking client, the same thing myOS does from Rust. Returns every line the server sent.
    static func roundTrip(url: URL, payload: String, stopAfterFirstLine: Bool = false) -> [Data] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return [] }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return [] }
        let out = Array((payload + "\n").utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: sent), out.count - sent) }
            if n <= 0 { break }
            sent += n
        }
        var pending = Data()
        var result: [Data] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                result.append(pending.prefix(upTo: newline))
                pending = pending.suffix(from: pending.index(after: newline))
                if stopAfterFirstLine { return result }
            }
        }
        if !pending.isEmpty { result.append(pending) }
        return result
    }
}
