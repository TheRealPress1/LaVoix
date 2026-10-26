import AppKit
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
///   {"op":"meetings.merge_speakers","id","source","into"} / {"op":"meetings.reassign","id","segment","speaker"} / {"op":"meetings.undo","id"}  -> {"ok":true}   (fixes to a finished meeting)
///   {"op":"meetings.export","id","format":"text|json"}    -> {"ok":true,"file":"..."}   (the transcript)
///   {"op":"model.status"}                                 -> {"ok":true,"model":{enabled,selected,state,progress?,error?,models:[{id,name,detail,bytes,downloaded}]}}   (the on-device cleanup model)
///   {"op":"model.enable","enabled"} / {"op":"model.select","id"} / {"op":"model.download"}  -> {"ok":true}   (download starts and returns; ask model.status for progress)
///   {"op":"bookshelf.status"}                              -> {"ok":true,"connected":false,"site":"https://bookshelf.music","pending"?:{user_code,verification_url}}
///   {"op":"bookshelf.pair_start","provider":"spotify|apple_music","device_name"} -> {"ok":true,"user_code","verification_url","expires_at"?}   (approve the code in the browser)
///   {"op":"bookshelf.pair_poll"}                            -> {"ok":true,"status":"pending|approved|expired|denied|none"}   (the device token goes to the Keychain and is never sent back)
///   {"op":"bookshelf.unpair"}                               -> {"ok":true}   (forgets the token on this Mac)
///   {"op":"bookshelf.history","limit"?}                     -> {"ok":true,"events":[{id,date,title,artist,album,artwork_url?,score?,note?,played_at,editable}]}
///   {"op":"bookshelf.rate_history","id","score"|null,"note"?} -> {"ok":true,"event":{...}}   (grade 0-10, one decimal)
///   {"op":"bookshelf.now"}                                  -> {"ok":true,"connected","state","provider"?,"title"?,"artist"?,"album"?,"artwork_url"?,"can_rate","score"?,"note"?,"status"}
///   {"op":"bookshelf.rate_now","score"|null,"note"?}        -> {"ok":true,...same as now}   (grades the track playing now)
///   {"op":"bump.status"}                                    -> {"ok":true,"connected":false,"pending"?:true}
///   {"op":"bump.connect_start"}                             -> {"ok":true,"authorize_url"}   (the engine opens it in the browser; approve there)
///   {"op":"bump.connect_poll"}                              -> {"ok":true,"status":"pending|connected|denied|expired|none"}   (tokens go to the Keychain, never sent back)
///   {"op":"bump.disconnect"}                                -> {"ok":true}
///   {"op":"bump.me"}                                        -> {"ok":true,"first_name"?,"home_country"?,"current_city"?,"is_traveling"?,"location_shared"?}
///   {"op":"bump.tools"}                                     -> {"ok":true,"tools":[names]}
///   {"op":"bump.call","name","arguments"?}                  -> {"ok":true,"result":{...}}   (read-only Bump tools only)
///   {"op":"photos.status"} / {"op":"photos.request"}        -> {"ok":true,"authorization":"authorized|limited|denied|restricted|not_determined"}   (request shows macOS's Photos prompt once)
///   {"op":"reminders.status"} / {"op":"reminders.request"}   -> {"ok":true,"authorization":"authorized|write_only|denied|restricted|not_determined"}   (request shows macOS's Reminders prompt once)
///   {"op":"reminders.today"}                                -> {"ok":true,"items":[{id,title,list,due?,due_has_time,priority,completed}]}   (due today or overdue, then completed today)
///   {"op":"messages.thread","handles":["+1555…","a@b.co"],"limit":40}   -> {"ok":true,"chat_guid":...,"items":[{id,text,at,from_me}]}   (the one-to-one chat with that person, oldest first)
///   {"op":"messages.send","handles":[...],"text":...,"confirm":true}      -> {"ok":true}   (sends into that existing one-to-one chat; refused without confirm:true)
///   {"op":"reminders.complete","id":...,"completed":true}   -> {"ok":true}   (ticks one reminder off or back on; the only change this ever makes)
///   {"op":"photos.summary"}                                 -> {"ok":true,"total","located","located_days","first_day"?,"last_day"?,"by_year":{...}}   (counts only: dates and locations are read, never images)
///   {"op":"photos.locations","since"?}                      -> {"ok":true,"clusters":[{t0,t1,lat,lon,n}],"scanned","used","screenshots","shared"}   (camera photos only, grouped by UTC day and ~5 km cell; no single photo's position is returned)
///   {"op":"providers.list"}                              -> {"ok":true,"providers":[{id,name,base_url,has_key,local,built_in,selected,model}]}   (a key is never sent back, only whether one is stored)
///   {"op":"providers.set_key","id","key"}                 -> {"ok":true}   (an empty key removes it; stored in the Keychain)
///   {"op":"providers.add","name","base_url","key"?} / {"op":"providers.remove","id"}  -> {"ok":true,"provider":{...}} / {"ok":true}   (your own OpenAI-compatible server; built-ins can't be removed)
///   {"op":"providers.models","id"}                        -> {"ok":true,"models":[...]}   (asks the provider, using the stored key)
///   {"op":"providers.select","id","model"?}               -> {"ok":true}
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
        var meetingEdits: (any EngineMeetingEditsProviding)?
        var model: (any EngineModelProviding)?
        var providers: (any EngineProvidersProviding)?
        var bookshelf: (any EngineBookshelfProviding)?
        var bump: (any EngineBumpProviding)?
        var photos: (any EnginePhotosProviding)?
        var reminders: (any EngineRemindersProviding)?
        var messages: (any EngineMessagesProviding)?
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
        Services(generator: self.liveGenerator, streamGenerator: self.liveStreamGenerator, status: self.liveStatus, warm: self.liveWarmer, meetings: LiveEngineMeetings(), writing: LiveEngineWriting(), history: LiveEngineHistory(), settings: LiveEngineSettings(), dictionary: LiveEngineDictionary(), stats: LiveEngineStats(), prompts: LiveEnginePrompts(), speech: LiveEngineSpeech(), activity: LiveEngineActivity(), contacts: LiveEngineContacts(), permissions: LiveEnginePermissions(), shortcuts: LiveEngineShortcuts(), words: LiveEngineWords(), meetingEdits: LiveEngineMeetingEdits(), model: LiveEngineModel(), providers: LiveEngineProviders(), bookshelf: LiveEngineBookshelf(), bump: LiveEngineBump(openURL: { url in DispatchQueue.main.async { NSWorkspace.shared.open(url) } }), photos: LiveEnginePhotos(), reminders: LiveEngineReminders(), messages: LiveEngineMessages())
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
            // An answer that can't be given in time is an error, never a guess: callers use this to avoid interrupting a recording.
            if let snapshot = await EngineTimeout.run(seconds: 4, { await activity.snapshot() }) {
                _ = emit(["ok": true, "activity": snapshot])
            } else {
                DebugLogger.shared.warning("Activity check stalled at: \(ActivityProbe.step)", source: "EngineSocket")
                fail("The engine is busy and could not say what it is doing. Try again in a moment.")
            }
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
        case "providers.list", "providers.set_key", "providers.add", "providers.remove", "providers.models", "providers.select":
            guard let providers = services.providers else { return fail("providers are not available") }
            do {
                switch op {
                case "providers.list": _ = emit(["ok": true, "providers": await providers.list()])
                case "providers.add":
                    guard let name = object["name"] as? String, let url = object["base_url"] as? String else { return fail("missing name or base_url") }
                    _ = emit(["ok": true, "provider": try await providers.add(name: name, baseURL: url, key: object["key"] as? String ?? "")])
                default:
                    guard let id = object["id"] as? String, !id.isEmpty else { return fail("missing id") }
                    switch op {
                    case "providers.set_key":
                        guard let key = object["key"] as? String else { return fail("missing key") }
                        try await providers.setKey(id: id, key: key); _ = emit(["ok": true])
                    case "providers.remove": try await providers.remove(id: id); _ = emit(["ok": true])
                    case "providers.models": _ = emit(["ok": true, "models": try await providers.models(id: id)])
                    default: try await providers.select(id: id, model: object["model"] as? String); _ = emit(["ok": true])
                    }
                }
            } catch { fail(message(error)) }
        case "bookshelf.status", "bookshelf.pair_start", "bookshelf.pair_poll", "bookshelf.unpair", "bookshelf.history", "bookshelf.rate_history", "bookshelf.now", "bookshelf.rate_now":
            guard let bookshelf = services.bookshelf else { return fail("bookshelf is not available") }
            do {
                switch op {
                case "bookshelf.status": var s = await bookshelf.status(); s["ok"] = true; _ = emit(s)
                case "bookshelf.pair_start":
                    guard let provider = object["provider"] as? String, let name = object["device_name"] as? String else { return fail("missing provider or device_name") }
                    var r = try await bookshelf.pairStart(provider: provider, deviceName: name); r["ok"] = true; _ = emit(r)
                case "bookshelf.pair_poll": var r = try await bookshelf.pairPoll(); r["ok"] = true; _ = emit(r)
                case "bookshelf.unpair": try await bookshelf.unpair(); _ = emit(["ok": true])
                case "bookshelf.now": var r = await bookshelf.now(); r["ok"] = true; _ = emit(r)
                case "bookshelf.rate_now":
                    let score: Double?
                    if object["score"] is NSNull { score = nil } else if let n = object["score"] as? NSNumber { score = n.doubleValue } else { return fail("missing score") }
                    var r = try await bookshelf.rateNow(score: score, note: object["note"] as? String); r["ok"] = true; _ = emit(r)
                case "bookshelf.history":
                    _ = emit(["ok": true, "events": try await bookshelf.history(limit: (object["limit"] as? Int) ?? 50)])
                default:
                    guard let id = object["id"] as? String, !id.isEmpty else { return fail("missing id") }
                    let score: Double?
                    if let n = object["score"] as? NSNumber, !(object["score"] is NSNull) { score = n.doubleValue } else if object["score"] is NSNull { score = nil } else { return fail("missing score") }
                    _ = emit(["ok": true, "event": try await bookshelf.rateHistory(id: id, score: score, note: object["note"] as? String)])
                }
            } catch { fail(message(error)) }
        case "bump.status", "bump.connect_start", "bump.connect_poll", "bump.disconnect", "bump.me", "bump.tools", "bump.call":
            guard let bump = services.bump else { return fail("bump is not available") }
            do {
                switch op {
                case "bump.status": var r = await bump.status(); r["ok"] = true; _ = emit(r)
                case "bump.connect_start": var r = try await bump.connectStart(); r["ok"] = true; _ = emit(r)
                case "bump.connect_poll": var r = try await bump.connectPoll(); r["ok"] = true; _ = emit(r)
                case "bump.disconnect": try await bump.disconnect(); _ = emit(["ok": true])
                case "bump.me": var r = try await bump.me(); r["ok"] = true; _ = emit(r)
                case "bump.tools": _ = emit(["ok": true, "tools": try await bump.tools()])
                default:
                    guard let name = object["name"] as? String, BumpRules.readOnlyTools.contains(name) else { return fail("that Bump tool can't be called from here") }
                    _ = emit(["ok": true, "result": try await bump.callTool(name: name, arguments: object["arguments"] as? [String: Any] ?? [:])])
                }
            } catch { fail(message(error)) }
        case "notch.alert":
            // A connection that broke (a mailbox signed out, Bump disconnected), told to the user from the notch. Shows a card only.
            guard let title = object["title"] as? String, !title.isEmpty, let text = object["text"] as? String else { return fail("title and text are required") }
            let symbol = (object["symbol"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "exclamationmark.triangle.fill"
            let label = (object["action_label"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(30)) }
            let actionID = (object["action_id"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            await MainActor.run { NotchHubController.shared.showAlert(title: String(title.prefix(80)), text: String(text.prefix(300)), symbol: symbol, actionLabel: label, actionID: actionID) }
            _ = emit(["ok": true])
        case "notch.connections_set":
            // The state of every connector, for the Connections tab (and its badge).
            let items = ConnectorItem.parse(object["items"])
            await MainActor.run { ConnectionsStore.shared.set(items) }
            _ = emit(["ok": true])
        case "notch.action_wait":
            // myOS waits here for a button pressed in the notch; answers with it, or with null when nothing was pressed in time.
            let seconds = min(max((object["timeout"] as? NSNumber)?.doubleValue ?? 25, 1), 30)
            let action = await ConnectionActions.shared.next(timeout: seconds)
            _ = emit(["ok": true, "action": action as Any? ?? NSNull()])
        case "reminders.status", "reminders.request", "reminders.today", "reminders.complete":
            guard let reminders = services.reminders else { return fail("reminders are not available") }
            do {
                switch op {
                case "reminders.status": var r = await reminders.status(); r["ok"] = true; _ = emit(r)
                case "reminders.request": var r = await reminders.request(); r["ok"] = true; _ = emit(r)
                case "reminders.complete":
                    guard let id = object["id"] as? String, !id.isEmpty else { return fail("id is required") }
                    try await reminders.setCompleted(id: id, completed: (object["completed"] as? Bool) ?? true)
                    _ = emit(["ok": true])
                default: var r = try await reminders.today(); r["ok"] = true; _ = emit(r)
                }
            } catch { fail(message(error)) }
        case "messages.thread", "messages.send":
            guard let messages = services.messages else { return fail("messages are not available") }
            let handles = MessagesRules.handles(object["handles"])
            guard !handles.isEmpty else { return fail("handles are required") }
            do {
                if op == "messages.thread" {
                    var r = try await messages.thread(handles: handles, limit: (object["limit"] as? NSNumber)?.intValue ?? 40)
                    r["ok"] = true
                    _ = emit(r)
                } else {
                    // The only thing here that sends a message: it must say so, in so many words.
                    guard (object["confirm"] as? Bool) == true else { return fail("sending needs confirm: true") }
                    guard let text = object["text"] as? String else { return fail("text is required") }
                    try await messages.send(handles: handles, text: text)
                    _ = emit(["ok": true])
                }
            } catch { fail(message(error)) }
        case "nowplaying.sessions":
            // Every stretch of something playing that was still going after `since` (seconds since 1970), the one in progress as of now.
            let since = (object["since"] as? NSNumber)?.doubleValue
            let rows: [[String: Any]] = await MainActor.run {
                NowPlayingStore.shared.watchLog.sessions(since: since).map { s in
                    var d: [String: Any] = ["id": s.id, "key": s.key, "title": s.title, "music": s.music, "start": s.start, "end": s.end]
                    if let a = s.artist { d["artist"] = a }
                    if let a = s.app { d["app"] = a }
                    if let b = s.bundle { d["bundle"] = b }
                    if let w = s.site { d["site"] = w }
                    return d
                }
            }
            _ = emit(["ok": true, "sessions": rows])
        case "photos.status", "photos.request", "photos.summary", "photos.locations":
            guard let photos = services.photos else { return fail("photos are not available") }
            do {
                switch op {
                case "photos.status": var r = await photos.status(); r["ok"] = true; _ = emit(r)
                case "photos.request": var r = await photos.request(); r["ok"] = true; _ = emit(r)
                case "photos.locations": var r = try await photos.locations(since: (object["since"] as? NSNumber)?.doubleValue); r["ok"] = true; _ = emit(r)
                default: var r = try await photos.summary(); r["ok"] = true; _ = emit(r)
                }
            } catch { fail(message(error)) }
        case "model.status", "model.enable", "model.select", "model.download":
            guard let model = services.model else { return fail("the model is not available") }
            switch op {
            case "model.status": _ = emit(["ok": true, "model": await model.status()])
            case "model.enable":
                guard let enabled = object["enabled"] as? Bool else { return fail("missing enabled") }
                await model.setEnabled(enabled); _ = emit(["ok": true])
            case "model.select":
                guard let id = object["id"] as? String else { return fail("missing id") }
                do { try await model.select(id: id); _ = emit(["ok": true]) } catch { fail(message(error)) }
            default:
                await model.download(); _ = emit(["ok": true])
            }
        case "meetings.merge_speakers", "meetings.reassign", "meetings.undo", "meetings.export":
            guard let edits = services.meetingEdits else { return fail("meetings are not available") }
            guard let id = uuid() else { return fail("missing or bad id") }
            func other(_ key: String) -> UUID? { (object[key] as? String).flatMap(UUID.init(uuidString:)) }
            do {
                switch op {
                case "meetings.merge_speakers":
                    guard let source = other("source"), let target = other("into") else { return fail("missing source or into") }
                    try await edits.mergeSpeakers(id: id, source: source, into: target); _ = emit(["ok": true])
                case "meetings.reassign":
                    guard let segment = other("segment"), let speaker = other("speaker") else { return fail("missing segment or speaker") }
                    try await edits.reassign(id: id, segment: segment, to: speaker); _ = emit(["ok": true])
                case "meetings.undo":
                    try await edits.undo(id: id); _ = emit(["ok": true])
                default:
                    _ = emit(["ok": true, "file": try await edits.export(id: id, format: object["format"] as? String ?? "text")])
                }
            } catch { fail(message(error)) }
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

private final class MemoryBookshelfCredentials: BookshelfCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    var token: String? { get { self.lock.lock(); defer { self.lock.unlock() }; return self.value } set { self.lock.lock(); self.value = newValue; self.lock.unlock() } }
    func load() -> String? { self.token }
    func save(_ token: String) throws { self.token = token }
    func delete() { self.token = nil }
}

/// A stand-in for bookshelf.music: answers the pairing and history routes from memory and records what it was sent.
private final class BookshelfAutotestSession: @unchecked Sendable {
    let store = MemoryBookshelfCredentials()
    private let lock = NSLock()
    private var _approved = false, _status = 200
    private var _lastBody: [String: Any] = [:], _lastAuth = "", _lastURL = ""
    private var _np: [String: Any] = [:], _npAuth = "", _rating: [String: Any] = [:]
    var lastNowPlayingBody: [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return self._np }
    var lastNowPlayingAuth: String { self.lock.lock(); defer { self.lock.unlock() }; return self._npAuth }
    var lastRatingBody: [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return self._rating }
    var approved: Bool { get { self.lock.lock(); defer { self.lock.unlock() }; return self._approved } set { self.lock.lock(); self._approved = newValue; self.lock.unlock() } }
    var status: Int { get { self.lock.lock(); defer { self.lock.unlock() }; return self._status } set { self.lock.lock(); self._status = newValue; self.lock.unlock() } }
    var lastBody: [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return self._lastBody }
    var lastAuth: String { self.lock.lock(); defer { self.lock.unlock() }; return self._lastAuth }
    var lastURL: String { self.lock.lock(); defer { self.lock.unlock() }; return self._lastURL }

    fileprivate func record(_ request: URLRequest) {
        self.lock.lock(); defer { self.lock.unlock() }
        self._lastURL = request.url?.absoluteString ?? ""
        self._lastAuth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        if let body = request.bodyData, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let url = self._lastURL
            if url.contains("/now-playing/") { self._np = obj; self._npAuth = self._lastAuth }
            else if url.contains("/listening/rating/") { self._rating = obj }
            else { self._lastBody = obj }
        }
    }

    fileprivate func reply(_ request: URLRequest) -> (Int, [String: Any]) {
        let path = request.url?.absoluteString.components(separatedBy: "?").first ?? ""
        let code = self.status, ok = self.approved
        if path.hasSuffix("/pairing/start/") { return (200, ["pairingId": "P1", "userCode": "ABCD-1234", "verificationUrl": "https://bookshelf.music/connect/ABCD1234/", "pairingSecret": "PAIRSECRET", "expiresAt": "2030-01-01T00:00:00Z"]) }
        if path.hasSuffix("/pairing/status/") { return ok ? (200, ["status": "approved", "deviceToken": "DEVICE-TOKEN-1"]) : (200, ["status": "pending"]) }
        if code != 200 { return (code, ["error": "no"]) }
        if path.hasSuffix("/now-playing/") {
            return (200, ["status": "session", "ratingTargetId": "TARGET-1", "currentTrack": ["title": "Live Song", "score": 6.5]])
        }
        if path.hasSuffix("/listening/rating/") { return (200, ["currentTrack": ["title": "Live Song", "score": 9.1]]) }
        if request.httpMethod == "GET" {
            return (200, ["events": [
                ["id": "e1", "listeningDate": "2026-10-19", "title": "Song A", "artist": "Guest", "albumArtist": "Album Artist", "album": "Album", "artworkUrl": "https://x/a.jpg", "score": 7.5, "lastPlayedAt": "2026-10-19T20:00:00Z", "isEditable": true],
                ["id": "e2", "listeningDate": "2026-10-19", "title": "Song B", "artist": "Artist", "album": "Album", "lastPlayedAt": "2026-10-19T20:05:00Z", "isEditable": true],
            ]])
        }
        return (200, ["event": ["id": "e2", "listeningDate": "2026-10-19", "title": "Song B", "artist": "Artist", "album": "Album", "score": 8.3, "lastPlayedAt": "2026-10-19T20:05:00Z", "isEditable": true]])
    }

    lazy var config: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        BookshelfStubProtocol.handlers[ObjectIdentifier(self)] = self
        config.protocolClasses = [BookshelfStubProtocol.self]
        return config
    }()

    /// A player that says it is playing one song, for the capture loop.
    @MainActor lazy var capture = BookshelfCapture(store: self.store, sessionConfiguration: self.config, providers: [
        .spotify: { .success(PlaybackSnapshot(state: .playing, track: SpotifyTrack(title: "Live Song", artist: "Artist", album: "Album", durationMs: 200_000, positionMs: 30_000, spotifyUrl: "spotify:track:abc"), provider: .spotify, identityEvidence: .provider("spotify:track:abc"))) },
    ])

    func client(capture: BookshelfCapture) -> LiveEngineBookshelf {
        LiveEngineBookshelf(session: URLSession(configuration: self.config), store: self.store, capture: capture)
    }
}

private extension URLRequest {
    /// URLProtocol delivers bodies as streams.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}

private final class BookshelfStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [ObjectIdentifier: BookshelfAutotestSession] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let session = Self.handlers.values.first else { self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        session.record(self.request)
        let (status, body) = session.reply(self.request)
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A stand-in for Bump's OAuth + MCP server, answered from memory.
private final class BumpAutotestServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _registered: [String: Any] = [:], _tokenForm: [String: String] = [:], _refreshForm: [String: String] = [:]
    private var _lastAuth = "", _toolArgs: [String: Any] = [:], _init = false, _inited = false
    private var _expire = false, _revoke = false, _access = "ACCESS-1", _tokens = 0
    var registered: [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return self._registered }
    var tokenForm: [String: String] { self.lock.lock(); defer { self.lock.unlock() }; return self._tokenForm }
    var refreshForm: [String: String] { self.lock.lock(); defer { self.lock.unlock() }; return self._refreshForm }
    var lastAuth: String { self.lock.lock(); defer { self.lock.unlock() }; return self._lastAuth }
    var lastToolArgs: [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return self._toolArgs }
    var sawInitialize: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self._init }
    var sawInitialized: Bool { self.lock.lock(); defer { self.lock.unlock() }; return self._inited }
    var expireAccess: Bool { get { self.lock.lock(); defer { self.lock.unlock() }; return self._expire } set { self.lock.lock(); self._expire = newValue; self.lock.unlock() } }
    var revokeRefresh: Bool { get { self.lock.lock(); defer { self.lock.unlock() }; return self._revoke } set { self.lock.lock(); self._revoke = newValue; self.lock.unlock() } }

    lazy var client: LiveEngineBump = {
        let config = URLSessionConfiguration.ephemeral
        BumpStubProtocol.server = self
        config.protocolClasses = [BumpStubProtocol.self]
        return LiveEngineBump(session: URLSession(configuration: config), store: MemoryBookshelfCredentials())
    }()

    /// (status, content type, body)
    fileprivate func answer(_ request: URLRequest) -> (Int, String, Data) {
        self.lock.lock(); defer { self.lock.unlock() }
        let path = request.url?.path ?? ""
        let body = request.bodyData
        func json(_ o: Any, _ status: Int = 200) -> (Int, String, Data) { (status, "application/json", (try? JSONSerialization.data(withJSONObject: o)) ?? Data()) }
        func form(_ d: Data?) -> [String: String] {
            guard let d, let s = String(data: d, encoding: .utf8) else { return [:] }
            var c = URLComponents(); c.query = s
            return Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
        }
        if path == "/oauth/register" { self._registered = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]; return json(["client_id": "CLIENT-1"]) }
        if path == "/oauth/token" {
            let f = form(body)
            if f["grant_type"] == "refresh_token" {
                self._refreshForm = f
                if self._revoke { return json(["error": "invalid_grant"], 400) }
                self._tokens += 1; self._access = "ACCESS-\(self._tokens + 1)"; self._expire = false
                return json(["access_token": self._access, "expires_in": 3600])
            }
            self._tokenForm = f
            return json(["access_token": "ACCESS-1", "refresh_token": "REFRESH-1", "expires_in": 3600])
        }
        if path == "/mcp" {
            // While "expired", every call is turned away with 401 until a refresh succeeds.
            if self._expire { return (401, "text/plain", Data()) }
            self._lastAuth = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let msg = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let method = msg["method"] as? String ?? ""
            let id = msg["id"] as? Int ?? 0
            func rpc(_ result: Any) -> (Int, String, Data) { json(["jsonrpc": "2.0", "id": id, "result": result]) }
            switch method {
            case "initialize": self._init = true; return rpc(["protocolVersion": "2025-06-18", "capabilities": ["tools": [String: Any]()], "serverInfo": ["name": "stub", "version": "1"]])
            case "notifications/initialized": self._inited = true; return (202, "application/json", Data())
            case "tools/list":
                // Streamed, with an empty priming event first, the way the real server answers.
                let payload = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": ["tools": [["name": "bump_friends_places"], ["name": "bump_watch"]]]])) ?? Data()
                return (200, "text/event-stream", Data("id: 0\ndata:\n\ndata: ".utf8) + payload + Data("\n\n".utf8))
            case "tools/call":
                let params = msg["params"] as? [String: Any] ?? [:]
                self._toolArgs = params["arguments"] as? [String: Any] ?? [:]
                switch params["name"] as? String {
                case "bump_friends_friend_info": return rpc(["structuredContent": ["person": ["first_name": "Ada"], "home_country_name": "Freedonia", "current_city": "Springfield", "is_traveling": false, "location_shared": true]])
                case "bump_friends_places": return rpc(["content": [["type": "text", "text": "{\"total_count\":74,\"places\":[]}"]]])
                default: return rpc(["isError": true, "content": [["type": "text", "text": "nope"]]])
                }
            default: return json(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown"]])
            }
        }
        return (404, "text/plain", Data())
    }
}

private final class BumpStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var server: BumpAutotestServer?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let server = Self.server else { self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let (status, type, data) = server.answer(self.request)
        let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FakePhotos: EnginePhotosProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    func status() async -> [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return ["authorization": self.granted ? "authorized" : "not_determined"] }
    func request() async -> [String: Any] { self.lock.lock(); self.granted = true; self.lock.unlock(); return ["authorization": "authorized"] }
    func summary() async throws -> [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.granted else { throw EnginePhotosError.notAllowed }
        return ["total": 5, "located": 2, "located_days": 2, "first_day": "2025-04-30", "last_day": "2025-05-01", "by_year": ["2025": 2]]
    }
    func locations(since: TimeInterval?) async throws -> [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.granted else { throw EnginePhotosError.notAllowed }
        return ["clusters": PhotoClusters.aggregate([PhotoPoint(time: 1_000, lat: 48.8566, lon: 2.3522), PhotoPoint(time: 2_000, lat: 48.8570, lon: 2.3530), PhotoPoint(time: 90_000, lat: 48.8566, lon: 2.3522), PhotoPoint(time: 3_000, lat: 40.7128, lon: -74.006)]), "scanned": 4, "used": 4, "screenshots": 0, "shared": 0]
    }
}

private final class FakeReminders: EngineRemindersProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    func status() async -> [String: Any] { self.lock.lock(); defer { self.lock.unlock() }; return ["authorization": self.granted ? "authorized" : "not_determined"] }
    func request() async -> [String: Any] { self.lock.lock(); self.granted = true; self.lock.unlock(); return ["authorization": "authorized"] }
    private var done = false
    func today() async throws -> [String: Any] {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.granted else { throw EngineRemindersError.notAllowed }
        return ["items": [["id": "r1", "title": "Pay rent", "list": "Home", "due": "2026-10-25", "due_has_time": false, "priority": 0, "completed": self.done]]]
    }
    func setCompleted(id: String, completed: Bool) async throws {
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.granted else { throw EngineRemindersError.notAllowed }
        guard id == "r1" else { throw EngineRemindersError.notFound }
        self.done = completed
    }
}

private final class FakeMessages: EngineMessagesProviding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [String] = []
    func thread(handles: [String], limit: Int) async throws -> [String: Any] {
        guard handles.contains("+15550100") else { throw EngineMessagesError.noChat }
        return ["chat_guid": "iMessage;-;+15550100", "items": [["id": 1, "text": "hi", "at": "2026-10-25T12:00:00Z", "from_me": false] as [String: Any]]]
    }
    func send(handles: [String], text: String) async throws {
        guard let body = MessagesRules.text(text) else { throw EngineMessagesError.badText }
        guard handles.contains("+15550100") else { throw EngineMessagesError.noChat }
        self.lock.lock(); self.sent.append(body); self.lock.unlock()
    }
    var sentCount: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.sent.count }
}

private final class FakeProviders: EngineProvidersProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    private var custom: [String] = []
    func list() async -> [[String: Any]] {
        self.lock.lock(); defer { self.lock.unlock() }
        return (["openai"] + self.custom).map { ["id": $0, "name": $0, "base_url": "https://x", "has_key": !(self.keys[$0] ?? "").isEmpty, "local": false, "built_in": $0 == "openai", "selected": false, "model": ""] }
    }
    func setKey(id: String, key: String) async throws {
        let k = try ProviderRules.key(key)
        self.lock.lock(); defer { self.lock.unlock() }
        guard id == "openai" || self.custom.contains(id) else { throw EngineProvidersError.unknownProvider }
        if k.isEmpty { self.keys[id] = nil } else { self.keys[id] = k }
    }
    func add(name: String, baseURL: String, key: String) async throws -> [String: Any] {
        let n = try ProviderRules.name(name); _ = try ProviderRules.baseURL(baseURL)
        self.lock.lock(); self.custom.append(n); self.lock.unlock()
        return ["id": n, "name": n]
    }
    func remove(id: String) async throws { if id == "openai" { throw EngineProvidersError.builtIn }; self.lock.lock(); defer { self.lock.unlock() }; guard self.custom.contains(id) else { throw EngineProvidersError.unknownProvider }; self.custom.removeAll { $0 == id } }
    func models(id: String) async throws -> [String] { ["m-a", "m-b"] }
    func select(id: String, model: String?) async throws { if id == "nope" { throw EngineProvidersError.unknownProvider } }
}

private final class FakeModel: EngineModelProviding, @unchecked Sendable {
    private let lock = NSLock()
    var calls: [String] = []
    private func note(_ s: String) { self.lock.lock(); self.calls.append(s); self.lock.unlock() }
    func status() async -> [String: Any] { ["enabled": true, "selected": "m1", "state": "ready", "models": [["id": "m1", "name": "Model One", "detail": "", "bytes": 100, "downloaded": true]]] }
    func setEnabled(_ enabled: Bool) async { self.note("enable:\(enabled)") }
    func select(id: String) async throws { if id == "nope" { throw EngineModelError.unknownModel }; if id == "busy" { throw EngineModelError.busy }; self.note("select:\(id)") }
    func download() async { self.note("download") }
}

private final class FakeMeetingEdits: EngineMeetingEditsProviding, @unchecked Sendable {
    private let lock = NSLock()
    var calls: [String] = []
    private func note(_ s: String) { self.lock.lock(); self.calls.append(s); self.lock.unlock() }
    func mergeSpeakers(id: UUID, source: UUID, into target: UUID) async throws { if source == target { throw EngineMeetingsError.unavailable("Pick a different speaker to merge into.") }; self.note("merge") }
    func reassign(id: UUID, segment: UUID, to speaker: UUID) async throws { self.note("reassign") }
    func undo(id: UUID) async throws { self.note("undo") }
    func export(id: UUID, format: String) async throws -> String { if format != "text" && format != "json" { throw EngineMeetingsError.unavailable("Format must be text or json.") }; return "[00:00] Dana: hello (\(format))" }
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
            let fakeEdits = FakeMeetingEdits()
            let fakeModel = FakeModel()
            let bookshelfSession = BookshelfAutotestSession()
            let fakeMessages = FakeMessages()
            let bumpStub = BumpAutotestServer()
            let bookshelfCapture = await MainActor.run { bookshelfSession.capture }
            await MainActor.run { bookshelfCapture.start(interval: 3600) }
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
                words: FakeWords(),
                meetingEdits: fakeEdits,
                model: fakeModel,
                providers: FakeProviders(),
                bookshelf: bookshelfSession.client(capture: bookshelfCapture),
                bump: bumpStub.client,
                photos: FakePhotos(),
                reminders: FakeReminders(),
                messages: fakeMessages
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

            // providers and keys
            do {
                check("providers.set_key stores a key and providers.list says so without sending it", ask(#"{"op":"providers.set_key","id":"openai","key":"sk-secret-123"}"#)?["ok"] as? Bool == true)
                let plist = ask(#"{"op":"providers.list"}"#)
                let pl = plist?["providers"] as? [[String: Any]]
                check("a stored key shows as has_key and never appears in a reply", pl?.first?["has_key"] as? Bool == true && !String(describing: plist ?? [:]).contains("sk-secret-123"))
                check("an empty key removes it", ask(#"{"op":"providers.set_key","id":"openai","key":""}"#)?["ok"] as? Bool == true && ((ask(#"{"op":"providers.list"}"#)?["providers"] as? [[String: Any]])?.first?["has_key"] as? Bool) == false)
                check("a key with a line break is refused", ask(#"{"op":"providers.set_key","id":"openai","key":"a\nb"}"#)?["ok"] as? Bool == false)
                check("providers.add needs a name and an http address", ask(#"{"op":"providers.add","name":"Mine","base_url":"ftp://x"}"#)?["ok"] as? Bool == false && ask(#"{"op":"providers.add","name":" ","base_url":"https://x"}"#)?["ok"] as? Bool == false && ask(#"{"op":"providers.add","name":"Mine","base_url":"https://my.server/v1/"}"#)?["ok"] as? Bool == true)
                check("a built-in provider can't be removed, your own can", ask(#"{"op":"providers.remove","id":"openai"}"#)?["ok"] as? Bool == false && ask(#"{"op":"providers.remove","id":"Mine"}"#)?["ok"] as? Bool == true)
                // Bookshelf: the real client against a stubbed site (no network), token in an in-memory store.
                let bs = bookshelfSession
                check("bookshelf starts disconnected", ask(#"{"op":"bookshelf.status"}"#)?["connected"] as? Bool == false)
                check("bookshelf history refuses before pairing", ask(#"{"op":"bookshelf.history"}"#)?["ok"] as? Bool == false)
                check("bookshelf refuses an unsupported player", ask(#"{"op":"bookshelf.pair_start","provider":"tidal","device_name":"Mac"}"#)?["ok"] as? Bool == false)
                let started = ask(#"{"op":"bookshelf.pair_start","provider":"spotify","device_name":"myOS on a Mac"}"#)
                check("bookshelf pair_start returns the code and link, never the secret", started?["user_code"] as? String == "ABCD-1234" && (started?["verification_url"] as? String)?.hasPrefix("https://") == true && !"\(started ?? [:])".contains("PAIRSECRET"))
                check("bookshelf pair_start sent the device name and player", bs.lastBody["deviceName"] as? String == "myOS on a Mac" && bs.lastBody["provider"] as? String == "spotify")
                check("bookshelf pending is reported", ask(#"{"op":"bookshelf.pair_poll"}"#)?["status"] as? String == "pending")
                bs.approved = true
                check("bookshelf approval stores the token and connects", ask(#"{"op":"bookshelf.pair_poll"}"#)?["status"] as? String == "approved" && bs.store.token == "DEVICE-TOKEN-1" && ask(#"{"op":"bookshelf.status"}"#)?["connected"] as? Bool == true)
                check("bookshelf status never carries the token", !"\(ask(#"{"op":"bookshelf.status"}"#) ?? [:])".contains("DEVICE-TOKEN-1"))
                let hist = ask(#"{"op":"bookshelf.history","limit":5}"#)?["events"] as? [[String: Any]]
                check("bookshelf history is read with the bearer token and shaped for myOS", hist?.count == 2 && hist?.first?["title"] as? String == "Song A" && hist?.first?["score"] as? Double == 7.5 && hist?.first?["editable"] as? Bool == true && hist?.last?["score"] == nil && bs.lastAuth == "Bearer DEVICE-TOKEN-1" && bs.lastURL.contains("limit=5"))
                check("bookshelf history uses the album artist when present", hist?.first?["artist"] as? String == "Album Artist")
                let rated = ask(#"{"op":"bookshelf.rate_history","id":"e2","score":8.26,"note":"fire"}"#)
                check("bookshelf rate_history rounds to one decimal and sends the note", rated?["ok"] as? Bool == true && bs.lastBody["score"] as? Double == 8.3 && bs.lastBody["note"] as? String == "fire" && bs.lastBody["dailyEventId"] as? String == "e2")
                check("bookshelf rate_history can clear a grade", ask(#"{"op":"bookshelf.rate_history","id":"e2","score":null}"#)?["ok"] as? Bool == true && bs.lastBody["score"] is NSNull)
                check("bookshelf refuses a grade outside 0-10", ask(#"{"op":"bookshelf.rate_history","id":"e2","score":11}"#)?["ok"] as? Bool == false)
                // Capture: the player says it is playing; the loop reports it and a grade is written against the target the site hands back.
                try? await Task.sleep(nanoseconds: 300_000_000)
                await bookshelfCapture.tick()
                let early = ask(#"{"op":"bookshelf.now"}"#)
                check("bookshelf now shows the playing track, not yet gradable until the site answers a posted report", early?["title"] as? String == "Live Song" && early?["state"] as? String == "playing" && early?["provider"] as? String == "spotify")
                await bookshelfCapture.tick()
                let live = ask(#"{"op":"bookshelf.now"}"#)
                check("bookshelf capture posts now-playing with the track and a playback observation", bs.lastNowPlayingBody["playerState"] as? String == "playing" && (bs.lastNowPlayingBody["track"] as? [String: Any])?["title"] as? String == "Live Song" && (bs.lastNowPlayingBody["observation"] as? [String: Any])?["playbackId"] is String && bs.lastNowPlayingAuth == "Bearer DEVICE-TOKEN-1")
                check("bookshelf now becomes gradable and carries the grade the site already holds", live?["can_rate"] as? Bool == true && live?["score"] as? Double == 6.5 && live?["status"] as? String == "Ready to rate")
                let gradedNow = ask(#"{"op":"bookshelf.rate_now","score":9.14,"note":"yes"}"#)
                check("bookshelf rate_now writes against the rating target with the track title and a rounded score", gradedNow?["ok"] as? Bool == true && bs.lastRatingBody["ratingTargetId"] as? String == "TARGET-1" && bs.lastRatingBody["trackTitle"] as? String == "Live Song" && bs.lastRatingBody["score"] as? Double == 9.1 && bs.lastRatingBody["note"] as? String == "yes" && gradedNow?["score"] as? Double == 9.1)
                check("bookshelf rate_now refuses a grade outside 0-10", ask(#"{"op":"bookshelf.rate_now","score":12}"#)?["ok"] as? Bool == false)
                bs.status = 401
                check("bookshelf forgets a token the site no longer accepts", ask(#"{"op":"bookshelf.history"}"#)?["ok"] as? Bool == false && bs.store.token == nil && ask(#"{"op":"bookshelf.status"}"#)?["connected"] as? Bool == false)
                bs.status = 200
                bs.store.token = "T2"
                check("bookshelf unpair forgets the token", ask(#"{"op":"bookshelf.unpair"}"#)?["ok"] as? Bool == true && bs.store.token == nil)
                // Bump: sign-in through a loopback page against a stubbed OAuth + MCP server, tokens in memory.
                let bump = bumpStub
                check("bump starts disconnected", ask(#"{"op":"bump.status"}"#)?["connected"] as? Bool == false)
                check("reminders.today refuses until the permission is granted", ask(#"{"op":"reminders.status"}"#)?["authorization"] as? String == "not_determined" && ask(#"{"op":"reminders.today"}"#)?["ok"] as? Bool == false)
                check("reminders.request grants and reminders.today then lists the items", ask(#"{"op":"reminders.request"}"#)?["authorization"] as? String == "authorized" && ((ask(#"{"op":"reminders.today"}"#)?["items"] as? [[String: Any]])?.first?["title"] as? String) == "Pay rent")
                check("reminders.complete ticks one off and back, and refuses an unknown id", ask(#"{"op":"reminders.complete","id":"r1","completed":true}"#)?["ok"] as? Bool == true && (((ask(#"{"op":"reminders.today"}"#)?["items"] as? [[String: Any]])?.first?["completed"]) as? Bool) == true && ask(#"{"op":"reminders.complete","id":"r1","completed":false}"#)?["ok"] as? Bool == true && (((ask(#"{"op":"reminders.today"}"#)?["items"] as? [[String: Any]])?.first?["completed"]) as? Bool) == false && ask(#"{"op":"reminders.complete","id":"nope"}"#)?["ok"] as? Bool == false && ask(#"{"op":"reminders.complete"}"#)?["ok"] as? Bool == false)
                check("messages.thread reads the one-to-one chat and refuses an unknown person", (ask(#"{"op":"messages.thread","handles":["+15550100"],"limit":5}"#)?["items"] as? [[String: Any]])?.first?["text"] as? String == "hi" && ask(#"{"op":"messages.thread","handles":["+15559999"]}"#)?["ok"] as? Bool == false && ask(#"{"op":"messages.thread"}"#)?["ok"] as? Bool == false)
                check("messages.send refuses without confirm, with empty text, or to someone with no chat; sends once when confirmed", ask(#"{"op":"messages.send","handles":["+15550100"],"text":"hello"}"#)?["ok"] as? Bool == false && fakeMessages.sentCount == 0 && ask(#"{"op":"messages.send","handles":["+15550100"],"text":"   ","confirm":true}"#)?["ok"] as? Bool == false && ask(#"{"op":"messages.send","handles":["+15559999"],"text":"hello","confirm":true}"#)?["ok"] as? Bool == false && fakeMessages.sentCount == 0 && ask(#"{"op":"messages.send","handles":["+15550100"],"text":"hello","confirm":true}"#)?["ok"] as? Bool == true && fakeMessages.sentCount == 1)
                check("photos.status reports the permission, summary refuses until it is granted and then returns counts only", ask(#"{"op":"photos.status"}"#)?["authorization"] as? String == "not_determined" && ask(#"{"op":"photos.summary"}"#)?["ok"] as? Bool == false)
                check("photos.request grants and summary then carries counts and no file names", ask(#"{"op":"photos.request"}"#)?["authorization"] as? String == "authorized" && (ask(#"{"op":"photos.summary"}"#)?["located"] as? Int) == 2 && !"\(ask(#"{"op":"photos.summary"}"#) ?? [:])".contains("IMG_"))
                let photoClusters = ask(#"{"op":"photos.locations"}"#)?["clusters"] as? [[String: Any]]
                check("photos.locations groups by day and ~5 km cell, keeping first/last time, mean position and count", photoClusters?.count == 3 && photoClusters?.first(where: { ($0["n"] as? Int) == 2 }) != nil && (photoClusters?.first(where: { ($0["n"] as? Int) == 2 })?["t1"] as? Int) == 2000)
                check("photos.locations never carries a file name or an individual photo's coordinates beyond the cluster mean", !"\(photoClusters ?? [])".contains("IMG_") && photoClusters?.allSatisfy { $0.keys.sorted() == ["lat", "lon", "n", "t0", "t1"] } == true)
                check("bump refuses to call a tool before signing in", ask(#"{"op":"bump.me"}"#)?["ok"] as? Bool == false)
                let bumpStart = ask(#"{"op":"bump.connect_start"}"#)
                let authURL = (bumpStart?["authorize_url"] as? String).flatMap { URLComponents(string: $0) }
                let q = Dictionary(uniqueKeysWithValues: (authURL?.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
                check("bump connect_start builds a PKCE sign-in link with a loopback redirect and the MCP resource", q["code_challenge_method"] == "S256" && (q["code_challenge"]?.count ?? 0) >= 40 && q["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true && q["resource"]?.hasSuffix("/mcp") == true && q["client_id"] == "CLIENT-1")
                check("bump registered the loopback address as a public client", (bump.registered["redirect_uris"] as? [String])?.first == q["redirect_uri"] && bump.registered["token_endpoint_auth_method"] as? String == "none")
                check("bump is pending until the browser comes back", ask(#"{"op":"bump.connect_poll"}"#)?["status"] as? String == "pending")
                if let redirect = q["redirect_uri"], let url = URL(string: redirect + "?code=CODE-1&state=" + (q["state"] ?? "")) { _ = try? await URLSession.shared.data(from: url) }
                check("bump connects once the browser delivers the code, and the token exchange carried the PKCE verifier", ask(#"{"op":"bump.connect_poll"}"#)?["status"] as? String == "connected" && bump.tokenForm["code"] == "CODE-1" && (bump.tokenForm["code_verifier"]?.count ?? 0) >= 43 && bump.tokenForm["client_id"] == "CLIENT-1")
                check("bump status never carries a token", ask(#"{"op":"bump.status"}"#)?["connected"] as? Bool == true && !"\(ask(#"{"op":"bump.status"}"#) ?? [:])".contains("ACCESS-1"))
                let who = ask(#"{"op":"bump.me"}"#)
                check("bump me initializes the MCP session, then reads your profile with the bearer token", who?["first_name"] as? String == "Ada" && who?["home_country"] as? String == "Freedonia" && bump.sawInitialize && bump.sawInitialized && bump.lastAuth == "Bearer ACCESS-1")
                check("bump tools lists names from a streamed reply", (ask(#"{"op":"bump.tools"}"#)?["tools"] as? [String]) == ["bump_friends_places", "bump_watch"])
                check("bump call answers read-only tools", (ask(#"{"op":"bump.call","name":"bump_friends_places","arguments":{"limit":5}}"#)?["result"] as? [String: Any])?["total_count"] as? Int == 74 && (bump.lastToolArgs["limit"] as? Int) == 5)
                check("bump call refuses tools that change things", ask(#"{"op":"bump.call","name":"bump_watch","arguments":{}}"#)?["ok"] as? Bool == false)
                bump.expireAccess = true
                check("bump refreshes an expired token on its own and keeps going", ask(#"{"op":"bump.me"}"#)?["first_name"] as? String == "Ada" && bump.refreshForm["refresh_token"] == "REFRESH-1" && bump.lastAuth == "Bearer ACCESS-2")
                bump.revokeRefresh = true; bump.expireAccess = true
                check("bump forgets the sign-in when it can no longer be refreshed", ask(#"{"op":"bump.me"}"#)?["ok"] as? Bool == false && ask(#"{"op":"bump.status"}"#)?["connected"] as? Bool == false)
                check("providers.models lists models and providers.select refuses an unknown provider", (ask(#"{"op":"providers.models","id":"openai"}"#)?["models"] as? [String]) == ["m-a", "m-b"] && ask(#"{"op":"providers.select","id":"nope"}"#)?["ok"] as? Bool == false)
                check("the provider rules trim and tidy", (try? ProviderRules.baseURL(" https://a.b/v1// ")) == "https://a.b/v1" && (try? ProviderRules.key("  k  ")) == "k")
            }
            // the on-device model
            do {
                let ms = ask(#"{"op":"model.status"}"#)?["model"] as? [String: Any]
                check("model.status reports state, selection and the catalog", ms?["state"] as? String == "ready" && ms?["selected"] as? String == "m1" && (ms?["models"] as? [[String: Any]])?.count == 1)
                check("model.enable, select and download reach the model", ask(#"{"op":"model.enable","enabled":false}"#)?["ok"] as? Bool == true && ask(#"{"op":"model.select","id":"m1"}"#)?["ok"] as? Bool == true && ask(#"{"op":"model.download"}"#)?["ok"] as? Bool == true && fakeModel.calls == ["enable:false", "select:m1", "download"])
                check("model.select refuses an unknown or busy model", ask(#"{"op":"model.select","id":"nope"}"#)?["ok"] as? Bool == false && ask(#"{"op":"model.select","id":"busy"}"#)?["ok"] as? Bool == false)
                check("model.enable needs true or false", ask(#"{"op":"model.enable"}"#)?["ok"] as? Bool == false)
            }
            // fixing meetings
            do {
                let a = UUID().uuidString, b = UUID().uuidString, m = UUID().uuidString
                check("meetings.merge_speakers merges", ask(#"{"op":"meetings.merge_speakers","id":"\#(m)","source":"\#(a)","into":"\#(b)"}"#)?["ok"] as? Bool == true)
                check("meetings.merge_speakers refuses merging a speaker into itself", ask(#"{"op":"meetings.merge_speakers","id":"\#(m)","source":"\#(a)","into":"\#(a)"}"#)?["ok"] as? Bool == false)
                check("meetings.reassign and meetings.undo work", ask(#"{"op":"meetings.reassign","id":"\#(m)","segment":"\#(a)","speaker":"\#(b)"}"#)?["ok"] as? Bool == true && ask(#"{"op":"meetings.undo","id":"\#(m)"}"#)?["ok"] as? Bool == true)
                check("meetings.reassign needs a segment and speaker", ask(#"{"op":"meetings.reassign","id":"\#(m)"}"#)?["ok"] as? Bool == false)
                check("meetings.export returns the transcript and refuses odd formats", (ask(#"{"op":"meetings.export","id":"\#(m)","format":"json"}"#)?["file"] as? String)?.contains("json") == true && ask(#"{"op":"meetings.export","id":"\#(m)","format":"pdf"}"#)?["ok"] as? Bool == false)
                check("the edits reached the meeting service", fakeEdits.calls == ["merge", "reassign", "undo"])
            }
            // a stuck check gives up instead of hanging
            do {
                let quick: Int? = await EngineTimeout.run(seconds: 1) { 7 }
                let stuck: Int? = await EngineTimeout.run(seconds: 0.2) { try? await Task.sleep(nanoseconds: 2_000_000_000); return 7 }
                check("a quick operation returns its answer", quick == 7)
                check("a stuck operation gives up with nothing instead of hanging", stuck == nil)
            }
            // group chats for the people map
            do {
                let day = Date(timeIntervalSince1970: 1_790_000_000)
                let raw = [
                    GroupChatsExport.Group(guid: "g1", name: " Ski trip ", handles: ["+14155550101", "ada@x.com", "+14155550101", "123", "+14155550102"], total: 40, fromMe: 9, lastAt: day),
                    GroupChatsExport.Group(guid: "g2", name: "Pair", handles: ["+14155550101"], total: 5, fromMe: 1, lastAt: nil),
                    GroupChatsExport.Group(guid: "g3", name: "Big list", handles: (0..<60).map { "+1415555\(String(format: "%04d", $0))" }, total: 3, fromMe: 0, lastAt: nil),
                    GroupChatsExport.Group(guid: "g4", name: "With a blocked one", handles: ["+14155550101", "+14155550103"], total: 2, fromMe: 0, lastAt: day),
                ]
                let kept = GroupChatsExport.prepare(raw, excluded: ["+14155550103"])
                check("group chats keep 2 to 40 other people with a usable handle, deduplicated", kept.map(\.name) == ["Ski trip"] && kept[0].handles == ["+14155550101", "+14155550102", "ada@x.com"])
                check("an excluded person leaves a chat that is then too small", !kept.contains { $0.guid == "g4" })
                let data = (try? GroupChatsExport.encode(kept, now: day)) ?? Data()
                let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let first = (parsed?["groups"] as? [[String: Any]])?.first
                check("the group file has members and counts and no text, and hides the chat identifier", (first?["handles"] as? [String])?.count == 3 && first?["total"] as? Int == 40 && first?["id"] as? String == GroupChatsExport.id(for: "g1") && !String(decoding: data, as: UTF8.self).contains("g1"))
            }
            // ambient now playing
            do {
                check("the strip shows while something plays and nothing else holds the notch", NotchNowPlayingAmbientSettings.shouldShow(enabled: true, playing: true, hubOpen: false, meetingLive: false))
                check("it stays away when paused, switched off, the hub is open or a meeting is live",
                      !NotchNowPlayingAmbientSettings.shouldShow(enabled: true, playing: false, hubOpen: false, meetingLive: false)
                        && !NotchNowPlayingAmbientSettings.shouldShow(enabled: false, playing: true, hubOpen: false, meetingLive: false)
                        && !NotchNowPlayingAmbientSettings.shouldShow(enabled: true, playing: true, hubOpen: true, meetingLive: false)
                      && !NotchNowPlayingAmbientSettings.shouldShow(enabled: true, playing: true, hubOpen: false, meetingLive: false, bannerShowing: true)
                        && !NotchNowPlayingAmbientSettings.shouldShow(enabled: true, playing: true, hubOpen: false, meetingLive: true))
            }
            // quick link logos
            do {
                let kinds = ["https://www.linkedin.com/in/me", "https://open.spotify.com/album/abc", "https://music.apple.com/us/album/x", "https://youtu.be/abc", "https://github.com/me", "https://x.com/me", "https://twitter.com/me",
                             "https://www.instagram.com/me", "https://me.com", "ada@example.com", "+1 (415) 555-0101", "123 Main Street", "mailto:ada@example.com"].map(QuickLinkKind.of)
                check("quick links pick the logo from where they point", kinds == [.linkedin, .spotify, .appleMusic, .youtube, .github, .x, .x, .instagram, .web, .email, .phone, .text, .email])
                check("GitHub and Cal.com links get their own marks", QuickLinkKind.of("https://github.com/me") == .github && QuickLinkKind.of("https://cal.com/me/15min") == .calcom && QuickLinkKind.of("https://app.cal.com/me") == .calcom && QuickLinkKind.of("https://notcal.com/me") == .web)
                check("the brand outlines draw inside their boxes", {
                    let gh = BrandMarks.bounds(of: BrandMarks.github), cal = BrandMarks.bounds(of: BrandMarks.calcom)
                    return gh.minX >= -0.01 && gh.maxX <= 24.01 && gh.minY >= -0.01 && gh.maxY <= 24.01 && gh.width > 23.9
                        && abs(cal.minY - BrandMarks.calcomBox.minY) < 0.1 && abs(cal.maxY - BrandMarks.calcomBox.maxY) < 0.1 && cal.width > 23.9
                }())
                check("a look-alike address is not mistaken for a brand", QuickLinkKind.of("https://notlinkedin.com/in/me") == .web && QuickLinkKind.of("https://linkedin.com.evil.example/in/me") == .web)
            }
            // freeze snapshots
            do {
                check("a short stall is ignored", !StallRecorder.shouldCapture(stalledFor: 0.3, sinceLastCapture: 500))
                check("a real stall is recorded", StallRecorder.shouldCapture(stalledFor: 1.2, sinceLastCapture: 500))
                check("snapshots are spaced out", !StallRecorder.shouldCapture(stalledFor: 5, sinceLastCapture: 30))
            }
            // now playing
            do {
                let big = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
                let soft = NowPlayingArtwork.soft(big)
                check("the now playing backdrop is a tiny copy, not the full cover", soft.size == NSSize(width: 32, height: 32))
                check("asking for the same backdrop again reuses it", NowPlayingArtwork.soft(big) === soft)
            }
            // quick links in the notch
            do {
                let file = #"{"links":[{"id":"a","label":" LinkedIn ","value":"https://linkedin.com/in/me"},{"id":"a","label":"Site","value":"https://me.com"},{"id":"c","label":"","value":"x"},{"id":"d","label":"No text","value":"  "}]}"#
                let parsed = QuickLinksStore.parse(Data(file.utf8))
                check("quick links are read in order, trimmed, with blank entries dropped", parsed.map(\.label) == ["LinkedIn", "Site"] && parsed[0].value == "https://linkedin.com/in/me")
                check("quick link ids stay unique", Set(parsed.map(\.id)).count == 2)
                let added = try? QuickLinksStore.adding(label: " Site ", value: " https://me.com ", to: parsed, id: "a")
                check("adding a quick link trims it, keeps the others and keeps ids unique", added?.count == 3 && added?.last?.label == "Site" && added?.last?.value == "https://me.com" && Set(added?.map(\.id) ?? []).count == 3)
                check("a quick link needs a name and text and the list holds forty", (try? QuickLinksStore.adding(label: "", value: "x", to: [])) == nil && (try? QuickLinksStore.adding(label: "x", value: " ", to: [])) == nil
                        && (try? QuickLinksStore.adding(label: "x", value: "y", to: (0..<40).map { QuickLinksStore.Link(id: "\($0)", label: "l", value: "v") })) == nil)
                check("what is saved reads back the same", (try? QuickLinksStore.encode(added ?? [])).map(QuickLinksStore.parse) == added)
                check("a link suggests a name from its address", QuickLinksWidgetView.nameGuess(for: "https://www.linkedin.com/in/me") == "Linkedin" && QuickLinksWidgetView.nameGuess(for: "just text") == nil)
                check("a file that isn't ours gives no links", QuickLinksStore.parse(Data("not json".utf8)).isEmpty && QuickLinksStore.parse(Data(#"{"other":1}"#.utf8)).isEmpty)
            }
            // the Messages tab never shows an empty thread while it loads
            do {
                let (fresh, filled, afterRead) = await MainActor.run { () -> ((Bool, Bool), Bool, (Bool, Int)) in
                    let store = MessagesStore()
                    let before = (store.hasLoaded, store.loadFailed)
                    let sample = MessagesStore.sample()
                    store.apply(conversations: sample.conversations, threads: [:], incoming: [], announce: false)
                    return (before, sample.hasLoaded, (store.hasLoaded, store.conversations.count))
                }
                check("a new Messages store has not loaded and has not failed", fresh == (false, false))
                check("sample data counts as loaded, and so does a first read", filled && afterRead == (true, 5))
            }
            // marking a chat seen after a reply
            do {
                check("a one-to-one chat has an address that opens it, a group does not", MessagesSender.conversationURL(handles: ["+15551230001"], isGroup: false)?.absoluteString == "imessage://+15551230001"
                        && MessagesSender.conversationURL(handles: ["sam@example.com"], isGroup: false)?.absoluteString == "imessage://sam@example.com"
                        && MessagesSender.conversationURL(handles: ["+1", "+2"], isGroup: true) == nil && MessagesSender.conversationURL(handles: [], isGroup: false) == nil)
            }
            // FaceTime from the notch
            do {
                check("a number keeps its plus and an email its at sign in the call address", FaceTimeDatabase.callURL(address: "+14155550101", audio: false)?.absoluteString == "facetime://+14155550101" && FaceTimeDatabase.callURL(address: "ada@example.com", audio: true)?.absoluteString == "facetime-audio://ada@example.com")
                check("an empty address starts no call", FaceTimeDatabase.callURL(address: "  ", audio: false) == nil)
                check("a search takes percent and underscore literally", FaceTimeDatabase.pattern(for: " a%b_c ") == "%a\\%b\\_c%")
                check("a missing people file reads as unavailable, not as no one", FaceTimeDatabase.read(query: "", url: URL(fileURLWithPath: "/nonexistent/people.db")) == nil)
            }
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
