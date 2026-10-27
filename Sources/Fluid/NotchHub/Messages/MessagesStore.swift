import AppKit
import Combine
import Foundation

/// Live view of your conversations. It reads the Messages database on this Mac, watches it for changes, and
/// never writes to it. Message text is never logged.
@MainActor
final class MessagesStore: ObservableObject {
    static let shared = MessagesStore()

    enum AccessState: Equatable {
        case unknown
        case granted
        case needsFullDiskAccess
        case missing
    }

    @Published private(set) var access: AccessState = .unknown
    @Published private(set) var conversations: [MessageConversation] = []
    /// True once the conversations have been read at least once. Until then the screen says it is loading instead of drawing an empty thread.
    @Published private(set) var hasLoaded = false
    /// True when the first read keeps failing, so the screen can say so and offer to try again.
    @Published private(set) var loadFailed = false
    @Published private(set) var thread: [ThreadMessage] = []
    @Published private(set) var unreadTotal = 0
    @Published private(set) var selectedChatID: Int64?
    @Published private(set) var sendError: String?
    @Published private(set) var isSending = false

    /// "New message": the search for someone (or a named group) to write to, beyond the latest chats.
    struct ComposeResult: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
        /// Who to send to; nil for a group (which is opened as the chat it is).
        let handle: String?
        let group: MessageConversation?
    }
    /// A conversation with someone you have no chat with yet: it exists once the first message is sent.
    struct NewChat: Equatable {
        let name: String
        let handle: String
    }
    @Published private(set) var composing = false
    @Published private(set) var composeResults: [ComposeResult] = []
    @Published private(set) var newChat: NewChat?
    /// A chat opened from the search that is not among the latest ones, kept in the list so it stays on screen.
    private var pinned: MessageConversation?
    private var composeQuery = ""

    /// Called for a fresh incoming message: (message, sender's display name).
    var onIncoming: ((IncomingMessage, String) -> Void)?

    private let database: MessagesDatabase
    private let contacts = ContactResolver.shared
    private var contactsObserver: AnyCancellable?
    /// Recent messages per chat, so switching conversations shows the thread instantly instead of waiting on the
    /// database. `cacheStamps` remembers which last-message date each cached thread was read at.
    private var threadCache: [Int64: [ThreadMessage]] = [:]
    private var cacheStamps: [Int64: Date] = [:]
    /// Messages you just sent that the Messages database hasn't shown yet. They are drawn right away, looking like any sent message, and dropped
    /// as soon as the real message appears, so sending feels instant even when Messages is slow to confirm.
    private struct PendingMessage {
        let tempID: Int64
        let chatID: Int64
        let text: String
        let date: Date
    }
    private var pending: [PendingMessage] = []
    private var nextTempID: Int64 = -1
    /// How a message is actually sent. Tests replace this so no real message is ever sent.
    var sendHandler: (String, String) async throws -> Void = { text, chatGUID in
        try await MessagesSender.send(text, toChat: chatGUID)
    }
    /// How a first message to someone with no chat is sent. Tests replace this too.
    var sendNewHandler: (String, String) async throws -> Void = { text, handle in
        try await MessagesSender.sendNew(text, toHandle: handle)
    }
    /// The newest message time (seconds since 1970) you have looked at, per chat, kept in this app only. Messages itself keeps its own unread state, which
    /// the notch cannot change; this is what clears the notch's unread dot once you have opened or answered a chat.
    private static let seenKey = "LaVoixNotchMessagesSeenUpTo"
    private(set) var seenUpTo: [Int64: TimeInterval] = {
        let stored = UserDefaults.standard.dictionary(forKey: "LaVoixNotchMessagesSeenUpTo") as? [String: Double] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in Int64(key).map { ($0, value) } })
    }()
    /// Tests turn this off so they never touch the real preferences.
    var persistsSeen = true

    /// A chat shows unread only while its newest message is from someone else and newer than what you last looked at.
    private func adjustedForSeen(_ list: [MessageConversation]) -> [MessageConversation] {
        list.map { chat in
            guard chat.unreadCount > 0 else { return chat }
            if chat.lastIsFromMe || (self.seenUpTo[chat.id] ?? 0) >= chat.lastDate.timeIntervalSince1970 { return chat.withUnread(0) }
            return chat
        }
    }

    /// You have looked at this chat (opened it in the notch or answered it): its unread dot goes away until something newer arrives.
    func markSeen(_ chatID: Int64) {
        guard let chat = self.conversations.first(where: { $0.id == chatID }) else { return }
        let stamp = chat.lastDate.timeIntervalSince1970
        guard (self.seenUpTo[chatID] ?? 0) < stamp else { return }
        self.seenUpTo[chatID] = stamp
        if self.persistsSeen {
            UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: self.seenUpTo.map { (String($0.key), $0.value) }), forKey: Self.seenKey)
        }
        self.conversations = self.adjustedForSeen(self.conversations)
        self.unreadTotal = self.conversations.reduce(0) { $0 + $1.unreadCount }
    }
    private var refreshFailures = 0
    /// Watches for reads that keep failing: re-checks access, tells the user, and relaunches the app once if that is what cures it.
    private var watch: ConnectionWatch = {
        var w = ConnectionWatch()
        let last = UserDefaults.standard.double(forKey: "messages.lastAutoRestart")
        if last > 0 { w.lastRestart = Date(timeIntervalSince1970: last) }
        return w
    }()
    /// Title, text and symbol of a connection alert for the notch to show.
    var onConnectionAlert: ((String, String, String) -> Void)?
    /// True while the user is dictating or recording, so the app never relaunches itself then.
    var isBusy: () -> Bool = { false }
    /// One read of the Messages database at a time, on its own queue. The read is synchronous and can take seconds on a big database; started
    /// again on every change and every 20 seconds with no limit, they piled up, filled Swift's worker threads and froze the whole engine.
    private var refreshInFlight = false
    private var pendingAnnounce: Bool?
    private static let readQueue = DispatchQueue(label: "com.myos.messages-read", qos: .utility)
    private var retryTask: Task<Void, Never>?
    private var lastSeenRowID: Int64 = 0
    private var watcher: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var debounce: Task<Void, Never>?
    private var isStarted = false

    init(database: MessagesDatabase = MessagesDatabase()) {
        self.database = database
    }

    /// A store filled with sample data, for previews. It never touches the real database.
    static func sample(access: AccessState = .granted) -> MessagesStore {
        let store = MessagesStore()
        let now = Date()
        store.access = access
        store.hasLoaded = true
        store.conversations = [
            MessageConversation(id: 1, guid: "g1", title: "Maya Chen", handles: ["+15551230001"], isGroup: false, lastText: "see you at the place 🍕", lastDate: now.addingTimeInterval(-120), lastIsFromMe: false, unreadCount: 2),
            MessageConversation(id: 2, guid: "g2", title: "Launch crew", handles: ["+15551230004", "+15551230005"], isGroup: true, lastText: "shipping at 5", lastDate: now.addingTimeInterval(-1800), lastIsFromMe: false, unreadCount: 0, hasGroupName: true),
            MessageConversation(id: 5, guid: "g5", title: "+15551230004", handles: ["+15551230004", "+15551230005", "+15551230006"], isGroup: true, lastText: "Aryan is going to be in Jersey next week", lastDate: now.addingTimeInterval(-3000), lastIsFromMe: false, unreadCount: 1, hasGroupName: false),
            MessageConversation(id: 3, guid: "g3", title: "Dad", handles: ["+15551230003"], isGroup: false, lastText: "Call me when you land", lastDate: now.addingTimeInterval(-7200), lastIsFromMe: false, unreadCount: 1),
            MessageConversation(id: 4, guid: "g4", title: "Sam", handles: ["sam@example.com"], isGroup: false, lastText: "sounds good", lastDate: now.addingTimeInterval(-86400), lastIsFromMe: true, unreadCount: 0),
        ]
        store.selectedChatID = 1
        store.unreadTotal = 3
        store.thread = [
            ThreadMessage(id: 1, text: "hey are you free tonight?", date: now.addingTimeInterval(-600), isFromMe: false, senderHandle: ""),
            ThreadMessage(id: 2, text: "yes! 7pm works", date: now.addingTimeInterval(-500), isFromMe: true, senderHandle: ""),
            ThreadMessage(id: 3, text: "see you at the place 🍕", date: now.addingTimeInterval(-120), isFromMe: false, senderHandle: ""),
        ]
        store.threadCache[1] = store.thread
        store.threadCache[5] = [
            ThreadMessage(id: 20, text: "Aryan is going to be in Jersey next week", date: now.addingTimeInterval(-3000), isFromMe: false, senderHandle: "+15551230004"),
            ThreadMessage(id: 21, text: "and will come work w us for a day", date: now.addingTimeInterval(-2990), isFromMe: false, senderHandle: "+15551230004"),
            ThreadMessage(id: 22, text: "lets do dinner thursday", date: now.addingTimeInterval(-2900), isFromMe: false, senderHandle: "+15551230005"),
            ThreadMessage(id: 23, text: "yes!! booking it", date: now.addingTimeInterval(-2800), isFromMe: true, senderHandle: ""),
            ThreadMessage(id: 24, text: "perfect", date: now.addingTimeInterval(-2700), isFromMe: false, senderHandle: "+15551230006"),
        ]
        store.threadCache[2] = [ThreadMessage(id: 10, text: "shipping at 5", date: now.addingTimeInterval(-1800), isFromMe: false, senderHandle: "")]
        return store
    }

    // MARK: - Lifecycle

    func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        self.contacts.loadIfNeeded()
        self.contactsObserver = self.contacts.$version.sink { [weak self] _ in self?.objectWillChange.send() }
        self.recheckAccess()
    }

    func stop() {
        self.isStarted = false
        self.watcher?.cancel()
        self.watcher = nil
        self.fallbackTimer?.invalidate()
        self.fallbackTimer = nil
        self.debounce?.cancel()
        self.retryTask?.cancel()
        self.retryTask = nil
        self.contactsObserver = nil
    }

    /// Re-reads access, e.g. after the user grants Full Disk Access.
    func recheckAccess() {
        let access = self.database.checkAccess()
        DebugLogger.shared.info("Messages database access: \(access)", source: "MessagesStore")
        switch access {
        case .granted:
            self.access = .granted
            self.lastSeenRowID = max(self.lastSeenRowID, self.database.maxRowID())
            self.refresh(announce: false)
            self.armWatcher()
        case .denied: self.access = .needsFullDiskAccess
        case .missing: self.access = .missing
        }
    }

    // MARK: - Reading

    func refresh(announce: Bool) {
        guard self.access == .granted else { return }
        let database = self.database
        let after = self.lastSeenRowID
        let chatID = self.selectedChatID
        let stamps = self.cacheStamps
        if self.refreshInFlight {
            // Fold into one more read once the current one lands, remembering whether any asker wanted new-message announcements.
            self.pendingAnnounce = (self.pendingAnnounce ?? false) || announce
            return
        }
        self.refreshInFlight = true
        Task {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<([MessageConversation], [Int64: [ThreadMessage]], [IncomingMessage])?, Never>) in
                Self.readQueue.async {
                    let value = { () -> ([MessageConversation], [Int64: [ThreadMessage]], [IncomingMessage])? in
                // A failed read (the Messages app can hold the database locked for a moment) is not "no conversations":
                // report it so the screen keeps what it has and tries again.
                guard let conversations = database.conversations(limit: 12) else { return nil }
                let selected = chatID ?? conversations.first?.id
                // Read the selected thread, plus any thread that is new or has a newer message since it was cached,
                // so the next tap on a conversation is already loaded.
                var threads: [Int64: [ThreadMessage]] = [:]
                for conversation in conversations where conversation.id == selected || stamps[conversation.id] != conversation.lastDate {
                    if let messages = database.messages(chatID: conversation.id, limit: 12) { threads[conversation.id] = messages }
                }
                // A chat opened from the search is not in the latest list, so its thread is read on its own.
                if let selected, threads[selected] == nil, !conversations.contains(where: { $0.id == selected }), let own = database.messages(chatID: selected, limit: 12) {
                    threads[selected] = own
                }
                let incoming = announce ? database.incomingMessages(after: after) : []
                return (conversations, threads, incoming)
                    }()
                    continuation.resume(returning: value)
                }
            }
            self.refreshInFlight = false
            // Applied first, so the follow-up read starts from the newest row seen and announces nothing twice.
            defer {
                if let again = self.pendingAnnounce {
                    self.pendingAnnounce = nil
                    self.refresh(announce: again)
                }
            }
            guard let result else {
                self.retryRefresh(announce: announce)
                return
            }
            self.refreshFailures = 0
            self.loadFailed = false
            if self.watch.succeeded() == .recovered {
                DebugLogger.shared.info("Messages connection recovered", source: "MessagesStore")
                self.onConnectionAlert?("Messages reconnected", "Your messages are being read again.", "checkmark.circle.fill")
            }
            self.apply(conversations: result.0, threads: result.1, incoming: result.2, announce: announce)
        }
    }

    private func handle(_ step: ConnectionWatch.Step) {
        switch step {
        case .none, .recovered:
            break
        case .recheck:
            // Also flips the screen to the Full Disk Access card when the system really has taken access away.
            self.recheckAccess()
        case .alert:
            DebugLogger.shared.info("Messages connection lost: alerting", source: "MessagesStore")
            self.onConnectionAlert?("Messages disconnected", "myOS can't read your messages right now. It is trying to reconnect.", "exclamationmark.triangle.fill")
        case .restart:
            DebugLogger.shared.info("Messages still unreadable: relaunching to reconnect", source: "MessagesStore")
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "messages.lastAutoRestart")
            self.onConnectionAlert?("Reconnecting Messages", "Restarting to fix the connection. This takes a few seconds.", "arrow.clockwise.circle.fill")
            Self.relaunchApp()
        case .stillBroken:
            DebugLogger.shared.info("Messages still unreadable after a restart", source: "MessagesStore")
            self.onConnectionAlert?("Messages is still disconnected", "A restart didn't fix it. Click here to open Full Disk Access and make sure myOS Engine is switched on.", "exclamationmark.triangle.fill")
        }
    }

    /// Quits and starts the app again a moment later (the same bundle, in the background as it was).
    private static func relaunchApp() {
        let path = Bundle.main.bundlePath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 4; /usr/bin/open -a \"$0\" --args --background", path]
        try? process.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { NSApp.terminate(nil) }
    }

    /// Tries again shortly after a failed read, backing off a little each time, for up to a few attempts.
    private func retryRefresh(announce: Bool) {
        self.refreshFailures += 1
        DebugLogger.shared.info("Messages database read failed (attempt \(self.refreshFailures)); keeping what is shown", source: "MessagesStore")
        if !self.hasLoaded, self.refreshFailures >= 3 { self.loadFailed = true }
        self.handle(self.watch.failed(now: Date(), busy: self.isBusy()))
        // Never gives up: a few quick retries, then one every 15 seconds for as long as the notch is running.
        guard self.retryTask == nil else { return }
        let delay = self.refreshFailures <= 6 ? 0.6 * Double(self.refreshFailures) : 15
        self.retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.refresh(announce: announce)
        }
    }

    func apply(conversations latest: [MessageConversation], threads: [Int64: [ThreadMessage]], incoming: [IncomingMessage], announce: Bool) {
        let adjustedLatest = self.adjustedForSeen(latest)
        var conversations = adjustedLatest
        if let pinned = self.pinned {
            if let index = conversations.firstIndex(where: { $0.id == pinned.id }) { self.pinned = conversations[index] }
            else { conversations.append(pinned) }
        }
        for conversation in conversations {
            if let fresh = threads[conversation.id] {
                self.threadCache[conversation.id] = fresh
                self.cacheStamps[conversation.id] = conversation.lastDate
            }
        }
        self.resolvePending()
        self.hasLoaded = true
        self.conversations = self.withPendingPreviews(conversations)
        self.unreadTotal = adjustedLatest.reduce(0) { $0 + $1.unreadCount }
        // Forget chats that fell out of the list so the cache stays small.
        let visible = Set(conversations.map(\.id))
        self.threadCache = self.threadCache.filter { visible.contains($0.key) }
        self.cacheStamps = self.cacheStamps.filter { visible.contains($0.key) }
        if self.selectedChatID == nil { self.selectedChatID = conversations.first?.id }
        if let selected = self.selectedChatID {
            let shown = self.mergedThread(for: selected)
            if self.threadCache[selected] != nil || !self.pending.isEmpty, shown != self.thread { self.thread = shown }
        }
        if let newest = incoming.last { self.lastSeenRowID = max(self.lastSeenRowID, newest.rowID) }
        guard announce else { return }
        // Only the latest message per chat, and nothing stale (e.g. a backlog arriving after sleep).
        var latestPerChat: [Int64: IncomingMessage] = [:]
        for message in incoming where message.date > Date().addingTimeInterval(-90) { latestPerChat[message.chatID] = message }
        for message in latestPerChat.values.sorted(by: { $0.rowID < $1.rowID }) {
            self.onIncoming?(message, self.displayName(forHandle: message.senderHandle))
        }
    }

    func select(_ chatID: Int64) {
        if self.newChat != nil { self.newChat = nil; self.thread = [] }
        self.markSeen(chatID)
        guard chatID != self.selectedChatID else { return }
        self.selectedChatID = chatID
        self.sendError = nil
        // Cached thread: show it right now, with no database work at all.
        if self.threadCache[chatID] != nil {
            self.thread = self.mergedThread(for: chatID)
            return
        }
        // Not cached yet (e.g. opened from a notification): clear the old thread and load just this one.
        self.thread = []
        guard self.access == .granted else { return }
        let database = self.database
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { database.messages(chatID: chatID, limit: 12) }.value
            guard self.selectedChatID == chatID else { return }
            // A failed read leaves the thread empty for now; the next refresh fills it in.
            guard let messages = loaded else { self.retryRefresh(announce: false); return }
            self.threadCache[chatID] = messages
            self.thread = self.mergedThread(for: chatID)
        }
    }

    // MARK: - Names

    /// First name for someone in a chat, or their number when they aren't in Contacts.
    func firstName(forHandle handle: String) -> String {
        guard let full = self.contacts.name(for: handle) else { return handle }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    /// "Krish, Aryan", "Krish, Aryan, Maya", "Krish, Aryan +2": an unnamed group, described by who is in it.
    static func participantsSummary(_ names: [String]) -> String {
        switch names.count {
        case 0: return "Group"
        case 1...3: return names.joined(separator: ", ")
        default: return names.prefix(2).joined(separator: ", ") + " +\(names.count - 2)"
        }
    }

    /// For a notification card: the group's name, or its members when it has none.
    func groupTitle(chatID: Int64, groupName: String) -> String {
        if !groupName.isEmpty { return groupName }
        guard let chat = self.conversations.first(where: { $0.id == chatID }) else { return "Group" }
        return self.title(for: chat)
    }

    func participantHandles(chatID: Int64) -> [String] {
        self.conversations.first { $0.id == chatID }?.handles ?? []
    }

    func isGroup(chatID: Int64?) -> Bool {
        guard let chatID else { return false }
        return self.conversations.first { $0.id == chatID }?.isGroup ?? false
    }

    func displayName(forHandle handle: String) -> String {
        self.contacts.name(for: handle) ?? handle
    }

    func title(for conversation: MessageConversation) -> String {
        if conversation.isGroup {
            return conversation.hasGroupName ? conversation.title : Self.participantsSummary(conversation.handles.map(self.firstName(forHandle:)))
        }
        return conversation.handles.first.map(self.displayName(forHandle:)) ?? conversation.title
    }

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let draft = self.newChat, !trimmed.isEmpty {
            self.deliverNew(trimmed, to: draft)
            return
        }
        guard !trimmed.isEmpty,
              let chat = self.conversations.first(where: { $0.id == self.selectedChatID }) else { return }
        self.deliver(trimmed, chatID: chat.id, chatGUID: chat.guid)
    }

    /// Sends to a specific chat (used by notification cards, which may not be the selected conversation).
    func send(_ text: String, toChatGUID guid: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.deliver(trimmed, chatID: self.conversations.first { $0.guid == guid }?.id, chatGUID: guid)
    }

    private func deliver(_ text: String, chatID: Int64?, chatGUID: String) {
        self.sendError = nil
        let tempID = chatID.map { self.addPending(text, chatID: $0) }
        Task {
            do {
                try await self.sendHandler(text, chatGUID)
                // Replying means you have seen it.
                if let id = chatID ?? self.conversations.first(where: { $0.guid == chatGUID })?.id { self.markSeen(id) }
                // The database lags the send by a moment; check a few times, quickly at first, until the real message shows.
                for delay in [0.3, 0.6, 1.2, 2.5, 5.0] as [Double] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    self.refresh(announce: false)
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if let tempID, !self.pending.contains(where: { $0.tempID == tempID }) { break }
                }
            } catch {
                self.sendError = error.localizedDescription
                if let tempID { self.removePending(tempID) }
            }
        }
    }

    // MARK: - New message

    func startCompose() {
        self.composing = true
        self.composeResults = []
        self.composeQuery = ""
        self.contacts.loadIfNeeded()
    }

    func cancelCompose() {
        self.composing = false
        self.composeResults = []
    }

    /// Looks for who was typed: contacts by name or number, named groups, and the number or email itself if that is what it looks like.
    func updateCompose(query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.composeQuery = q
        guard !q.isEmpty else { self.composeResults = []; return }
        var results = self.contacts.search(q).map {
            ComposeResult(id: "h:" + $0.handle, name: $0.name, detail: $0.handle, handle: $0.handle, group: nil)
        }
        if let handle = ContactResolver.sendableHandle(q), !results.contains(where: { $0.handle == handle }) {
            results.append(ComposeResult(id: "h:" + handle, name: handle, detail: "Send to this number or email", handle: handle, group: nil))
        }
        self.composeResults = results
        let database = self.database
        Task {
            let groups = await withCheckedContinuation { (continuation: CheckedContinuation<[MessageConversation], Never>) in
                Self.readQueue.async { continuation.resume(returning: database.groupChats(matching: q) ?? []) }
            }
            guard self.composeQuery == q, !groups.isEmpty else { return }
            let more = groups.map { ComposeResult(id: "g:\($0.id)", name: self.title(for: $0), detail: "Group", handle: nil, group: $0) }
            self.composeResults += more.filter { m in !self.composeResults.contains { $0.id == m.id } }
        }
    }

    /// Opens the chat with that person (or group). With no chat yet, it opens an empty one that is created by the first message.
    func openResult(_ result: ComposeResult) {
        if let group = result.group {
            self.show(group)
            return
        }
        guard let handle = result.handle else { return }
        let database = self.database
        Task {
            let found = await withCheckedContinuation { (continuation: CheckedContinuation<MessageConversation?, Never>) in
                Self.readQueue.async {
                    let chat = database.oneToOneChat(handles: [handle])?.first
                    continuation.resume(returning: chat.flatMap { database.conversation(id: $0.id) })
                }
            }
            if let found { self.show(found); return }
            self.selectedChatID = nil
            self.thread = []
            self.sendError = nil
            self.newChat = NewChat(name: result.name == handle ? handle : result.name, handle: handle)
            self.composing = false
        }
    }

    private func show(_ conversation: MessageConversation) {
        self.newChat = nil
        self.pinned = conversation
        if !self.conversations.contains(where: { $0.id == conversation.id }) { self.conversations.insert(conversation, at: 0) }
        self.composing = false
        self.composeResults = []
        self.select(conversation.id)
    }

    /// The first message to someone: sent through Messages, shown at once, and the real chat is picked up as soon as it exists.
    private func deliverNew(_ text: String, to draft: NewChat) {
        self.sendError = nil
        self.thread.append(ThreadMessage(id: -1_000_000 - Int64(self.thread.count), text: text, date: Date(), isFromMe: true, senderHandle: ""))
        let database = self.database
        Task {
            do {
                try await self.sendNewHandler(text, draft.handle)
                for delay in [0.5, 1.0, 2.0, 4.0, 8.0] as [Double] {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard self.newChat == draft else { return }
                    let found = await withCheckedContinuation { (continuation: CheckedContinuation<MessageConversation?, Never>) in
                        Self.readQueue.async {
                            let chat = database.oneToOneChat(handles: [draft.handle])?.first
                            continuation.resume(returning: chat.flatMap { database.conversation(id: $0.id) })
                        }
                    }
                    if let found { self.show(found); self.refresh(announce: false); return }
                }
            } catch {
                self.sendError = error.localizedDescription
                self.thread.removeAll { $0.id <= -1_000_000 }
            }
        }
    }

    // MARK: - Pending (just sent) messages

    private func addPending(_ text: String, chatID: Int64) -> Int64 {
        let tempID = self.nextTempID
        self.nextTempID -= 1
        self.pending.append(PendingMessage(tempID: tempID, chatID: chatID, text: text, date: Date()))
        self.showPending(chatID: chatID)
        return tempID
    }

    private func removePending(_ tempID: Int64) {
        guard let index = self.pending.firstIndex(where: { $0.tempID == tempID }) else { return }
        let chatID = self.pending[index].chatID
        self.pending.remove(at: index)
        self.showPending(chatID: chatID)
    }

    /// Redraws the thread and the conversation list with the pending messages included.
    private func showPending(chatID: Int64) {
        if self.selectedChatID == chatID { self.thread = self.mergedThread(for: chatID) }
        self.conversations = self.withPendingPreviews(self.conversations)
    }

    private func mergedThread(for chatID: Int64) -> [ThreadMessage] {
        let sent = self.pending.filter { $0.chatID == chatID }.map {
            ThreadMessage(id: $0.tempID, text: $0.text, date: $0.date, isFromMe: true, senderHandle: "")
        }
        return (self.threadCache[chatID] ?? []) + sent
    }

    /// Drops pending messages the database now shows (same text from you, sent after we queued it), or that never showed
    /// up after a minute.
    private func resolvePending() {
        self.pending.removeAll { item in
            if Date().timeIntervalSince(item.date) > 60 { return true }
            return (self.threadCache[item.chatID] ?? []).contains {
                $0.isFromMe && $0.text == item.text && $0.date >= item.date.addingTimeInterval(-10)
            }
        }
    }

    /// Shows the newest pending message as each conversation's preview and moves that conversation to the top.
    private func withPendingPreviews(_ list: [MessageConversation]) -> [MessageConversation] {
        var result = list
        for item in self.pending.sorted(by: { $0.date < $1.date }) {
            guard let index = result.firstIndex(where: { $0.id == item.chatID }) else { continue }
            let old = result.remove(at: index)
            guard old.lastDate <= item.date else { result.insert(old, at: index); continue }
            result.insert(MessageConversation(
                id: old.id, guid: old.guid, title: old.title, handles: old.handles, isGroup: old.isGroup,
                lastText: item.text, lastDate: item.date, lastIsFromMe: true, unreadCount: 0,
                hasGroupName: old.hasGroupName
            ), at: 0)
        }
        return result
    }

    // MARK: - Watching for new messages

    private func armWatcher() {
        self.watcher?.cancel()
        self.fallbackTimer?.invalidate()
        let walPath = self.database.url.path + "-wal"
        let descriptor = open(walPath, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main
            )
            source.setEventHandler { [weak self, weak source] in
                guard let self else { return }
                self.scheduleRefresh()
                if let flags = source?.data, flags.contains(.delete) || flags.contains(.rename) {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if self.isStarted { self.armWatcher() }
                    }
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            self.watcher = source
        }
        // Safety net in case file events are missed.
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(announce: true) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.fallbackTimer = timer
    }

    private func scheduleRefresh() {
        self.debounce?.cancel()
        self.debounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.refresh(announce: true)
        }
    }
}
