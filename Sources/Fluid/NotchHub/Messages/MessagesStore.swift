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
    @Published private(set) var thread: [ThreadMessage] = []
    @Published private(set) var unreadTotal = 0
    @Published private(set) var selectedChatID: Int64?
    @Published private(set) var sendError: String?
    @Published private(set) var isSending = false

    /// Called for a fresh incoming message: (message, sender's display name).
    var onIncoming: ((IncomingMessage, String) -> Void)?

    private let database: MessagesDatabase
    private let contacts = ContactResolver.shared
    private var contactsObserver: AnyCancellable?
    /// Recent messages per chat, so switching conversations shows the thread instantly instead of waiting on the
    /// database. `cacheStamps` remembers which last-message date each cached thread was read at.
    private var threadCache: [Int64: [ThreadMessage]] = [:]
    private var cacheStamps: [Int64: Date] = [:]
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
        store.conversations = [
            MessageConversation(id: 1, guid: "g1", title: "Maya Chen", handles: ["+15551230001"], isGroup: false, lastText: "see you at the place 🍕", lastDate: now.addingTimeInterval(-120), lastIsFromMe: false, unreadCount: 2),
            MessageConversation(id: 2, guid: "g2", title: "Launch crew", handles: [], isGroup: true, lastText: "shipping at 5", lastDate: now.addingTimeInterval(-1800), lastIsFromMe: false, unreadCount: 0),
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
        self.contactsObserver = nil
    }

    /// Re-reads access, e.g. after the user grants Full Disk Access.
    func recheckAccess() {
        let access = self.database.checkAccess()
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
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([MessageConversation], [Int64: [ThreadMessage]], [IncomingMessage]) in
                let conversations = database.conversations(limit: 12)
                let selected = chatID ?? conversations.first?.id
                // Read the selected thread, plus any thread that is new or has a newer message since it was cached,
                // so the next tap on a conversation is already loaded.
                var threads: [Int64: [ThreadMessage]] = [:]
                for conversation in conversations where conversation.id == selected || stamps[conversation.id] != conversation.lastDate {
                    threads[conversation.id] = database.messages(chatID: conversation.id, limit: 12)
                }
                let incoming = announce ? database.incomingMessages(after: after) : []
                return (conversations, threads, incoming)
            }.value
            self.apply(conversations: result.0, threads: result.1, incoming: result.2, announce: announce)
        }
    }

    private func apply(conversations: [MessageConversation], threads: [Int64: [ThreadMessage]], incoming: [IncomingMessage], announce: Bool) {
        self.conversations = conversations
        self.unreadTotal = conversations.reduce(0) { $0 + $1.unreadCount }
        for conversation in conversations {
            if let fresh = threads[conversation.id] {
                self.threadCache[conversation.id] = fresh
                self.cacheStamps[conversation.id] = conversation.lastDate
            }
        }
        // Forget chats that fell out of the list so the cache stays small.
        let visible = Set(conversations.map(\.id))
        self.threadCache = self.threadCache.filter { visible.contains($0.key) }
        self.cacheStamps = self.cacheStamps.filter { visible.contains($0.key) }
        if self.selectedChatID == nil { self.selectedChatID = conversations.first?.id }
        if let selected = self.selectedChatID, let cached = self.threadCache[selected], cached != self.thread { self.thread = cached }
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
        guard chatID != self.selectedChatID else { return }
        self.selectedChatID = chatID
        self.sendError = nil
        // Cached thread: show it right now, with no database work at all.
        if let cached = self.threadCache[chatID] {
            self.thread = cached
            return
        }
        // Not cached yet (e.g. opened from a notification): clear the old thread and load just this one.
        self.thread = []
        guard self.access == .granted else { return }
        let database = self.database
        Task {
            let messages = await Task.detached(priority: .userInitiated) { database.messages(chatID: chatID, limit: 12) }.value
            guard self.selectedChatID == chatID else { return }
            self.threadCache[chatID] = messages
            self.thread = messages
        }
    }

    // MARK: - Names

    func displayName(forHandle handle: String) -> String {
        self.contacts.name(for: handle) ?? handle
    }

    func title(for conversation: MessageConversation) -> String {
        if conversation.isGroup { return conversation.title }
        return conversation.handles.first.map(self.displayName(forHandle:)) ?? conversation.title
    }

    // MARK: - Sending

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !self.isSending,
              let chat = self.conversations.first(where: { $0.id == self.selectedChatID }) else { return }
        self.isSending = true
        self.sendError = nil
        Task {
            do {
                try await MessagesSender.send(trimmed, toChat: chat.guid)
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.refresh(announce: false)
            } catch {
                self.sendError = error.localizedDescription
            }
            self.isSending = false
        }
    }

    /// Sends to a specific chat (used by notification cards, which may not be the selected conversation).
    func send(_ text: String, toChatGUID guid: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await MessagesSender.send(trimmed, toChat: guid)
                try? await Task.sleep(nanoseconds: 900_000_000)
                self.refresh(announce: false)
            } catch {
                self.sendError = error.localizedDescription
            }
        }
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
