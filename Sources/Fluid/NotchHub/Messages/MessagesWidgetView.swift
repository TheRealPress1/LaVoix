import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Conversations on the left, the open thread and a reply box on the right.
struct MessagesWidgetView: View {
    @ObservedObject var store: MessagesStore
    /// Image previews can't draw scroll views or text fields; this swaps in static stand-ins.
    var staticLayout = false
    /// The conversation a dragged file is over.
    @State private var dropChatID: Int64?

    var body: some View {
        switch self.store.access {
        case .granted:
            self.conversationsAndThread
        case .needsFullDiskAccess:
            self.permissionCard
        case .missing:
            self.infoCard(icon: "message", title: "Messages isn't set up on this Mac", detail: "Sign in to Messages and your conversations will show up here.")
        case .unknown:
            ProgressView().controlSize(.small).colorScheme(.dark).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Main layout

    @ViewBuilder
    private var conversationsAndThread: some View {
        if !self.store.hasLoaded {
            // Reading the Messages database takes a few seconds the first time. Say so, never draw an empty thread with a send box.
            if self.store.loadFailed {
                VStack(spacing: 8) {
                    self.infoCard(icon: "exclamationmark.bubble", title: "Couldn't read your messages yet", detail: "Messages may be busy. myOS keeps trying.")
                    self.pill("Try again", prominent: false) { self.store.recheckAccess() }
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                    Text("Loading your messages…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if self.store.conversations.isEmpty || self.store.selectedChatID == nil {
            self.infoCard(icon: "message", title: "No conversations yet", detail: "Messages you send and receive will show up here.")
        } else {
            self.loadedLayout
        }
    }

    private var loadedLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 4) {
                if !self.staticLayout { self.newMessageBar }
                Group {
                    if self.store.composing {
                        ComposeList(store: self.store)
                    } else if self.staticLayout {
                        self.rows
                    } else {
                        ScrollView(.vertical, showsIndicators: false) { self.rows }
                    }
                }
            }
            .frame(width: 232)

            ThreadView(store: self.store, staticLayout: self.staticLayout)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    /// The + above the list: write to someone who is not among the latest chats.
    private var newMessageBar: some View {
        Button {
            if self.store.composing { self.store.cancelCompose() } else { self.store.startCompose() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: self.store.composing ? "xmark" : "plus").font(.system(size: 11, weight: .bold))
                Text(self.store.composing ? "Cancel" : "New message").font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(self.store.conversations) { conversation in
                self.row(for: conversation)
            }
        }
    }

    private func row(for conversation: MessageConversation) -> some View {
        let targeted = Binding<Bool>(
            get: { self.dropChatID == conversation.id },
            set: { on in
                if on { self.dropChatID = conversation.id } else if self.dropChatID == conversation.id { self.dropChatID = nil }
            }
        )
        return ConversationRow(
            conversation: conversation,
            title: self.store.title(for: conversation),
            selected: conversation.id == self.store.selectedChatID,
            dropTargeted: self.dropChatID == conversation.id
        )
        .onTapGesture { self.store.select(conversation.id) }
        // A file dropped on a conversation opens it and waits there for Send.
        .modifier(MessagesDropTarget(enabled: !self.staticLayout, targeted: targeted) { providers in
            self.dropOnRow(providers, chatID: conversation.id)
        })
    }

    private func dropOnRow(_ providers: [NSItemProvider], chatID: Int64) {
        let store = self.store
        NotchDropLoader.load(providers) { urls in store.stage(urls, chatID: chatID) }
    }

    // MARK: - Permission and empty states

    private var permissionCard: some View {
        HStack(spacing: 18) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow LaVoix to read your messages")
                    .font(.system(size: 15, weight: .semibold))
                Text("Turn on Full Disk Access for LaVoix in Privacy & Security. Your messages are read on this Mac only and never leave it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    pill("Open Privacy Settings", prominent: true) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    pill("Check again", prominent: false) { self.store.recheckAccess() }
                }
                .padding(.top, 4)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func infoCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.6))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

/// Lets a conversation row or the open thread take a dropped file. Previews can't draw drop targets, so they leave it out.
private struct MessagesDropTarget: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let drop: ([NSItemProvider]) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if self.enabled {
            content.onDrop(of: [.fileURL, .image], isTargeted: self.$targeted) { providers in
                self.drop(providers)
                return true
            }
        } else {
            content
        }
    }
}

/// The files waiting to be sent, above the reply box, on one line with who they would go to. Nothing leaves until Send is pressed.
private struct StagedFilesBar: View {
    @ObservedObject var store: MessagesStore
    let recipient: String?

    var body: some View {
        let files = self.store.stagedFiles
        HStack(spacing: 8) {
            if let first = files.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path)).resizable().frame(width: 20, height: 20)
                Text(files.count > 1 ? "\(first.lastPathComponent) +\(files.count - 1)" : first.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(self.recipient.map { "to \($0)" } ?? "open a chat first")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { for file in files { self.store.unstage(file) } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("Don't send")
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

private struct ConversationRow: View {
    let conversation: MessageConversation
    let title: String
    let selected: Bool
    var dropTargeted = false

    var body: some View {
        HStack(spacing: 9) {
            if self.conversation.isGroup {
                NotchGroupAvatar(handles: self.conversation.handles, size: 30)
            } else {
                NotchAvatar(name: self.title, handle: self.conversation.handles.first, size: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(self.title)
                        .font(.system(size: 12.5, weight: self.conversation.unreadCount > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.relative(self.conversation.lastDate))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text(self.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(self.conversation.unreadCount > 0 ? 0.8 : 0.5))
                    .lineLimit(1)
            }
            if self.conversation.unreadCount > 0 {
                Circle().fill(Color.blue).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(self.dropTargeted ? 0.22 : (self.selected ? 0.12 : 0))))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(self.dropTargeted ? 0.8 : 0), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        )
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard NotchMessagesSettings.showsPreviews else { return self.conversation.unreadCount > 0 ? "New message" : "Message" }
        return self.conversation.lastText
    }

    private var initials: String {
        let words = self.title.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty || self.title.first?.isNumber == true || self.title.first == "+" ? "•" : letters
    }

    static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct ThreadView: View {
    @ObservedObject var store: MessagesStore
    var staticLayout = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// A dragged file is over the thread.
    @State private var dropTargeted = false

    private var recipient: String? {
        self.store.conversations.first { $0.id == self.store.selectedChatID }.map { self.store.title(for: $0) }
    }

    private var canSend: Bool {
        !self.draft.trimmingCharacters(in: .whitespaces).isEmpty || !self.store.stagedFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            if let draft = self.store.newChat {
                Text("New message to \(draft.name)").font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading)
            }
            if self.staticLayout {
                VStack(spacing: 5) {
                    ForEach(Array(self.store.thread.enumerated()), id: \.element.id) { index, message in
                        Bubble(message: message, label: self.senderLabel(at: index))
                    }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 5) {
                            ForEach(Array(self.store.thread.enumerated()), id: \.element.id) { index, message in
                                Bubble(message: message, label: self.senderLabel(at: index)).id(message.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: self.store.thread) { _, thread in
                        if let last = thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let last = self.store.thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let error = self.store.sendError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            }

            if !self.store.stagedFiles.isEmpty {
                StagedFilesBar(store: self.store, recipient: self.recipient)
            }

            HStack(spacing: 8) {
                (self.staticLayout ? AnyView(Text("iMessage").foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)) : AnyView(TextField("", text: self.$draft, prompt: Text("iMessage").foregroundStyle(.white.opacity(0.45))).foregroundStyle(.white).tint(.white)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(self.$focused)
                    .onSubmit { self.send() }
                    .onExitCommand { self.focused = false; NotchHubController.shared.endTextEntry() }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
                    .onTapGesture {
                        NotchHubController.shared.beginTextEntry()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            self.focused = true
                        }
                    }
                Button(action: self.send) {
                    Image(systemName: self.store.isSending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(self.canSend ? 1 : 0.3)))
                }
                .buttonStyle(.plain)
                .disabled(!self.canSend || self.store.isSending)
            }
        }
        .overlay {
            if self.dropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.6)))
                    .overlay(Text("Drop to attach").font(.system(size: 13, weight: .medium)).foregroundStyle(.white))
            }
        }
        // A file dropped on the open chat waits above the reply box until Send is pressed.
        .modifier(MessagesDropTarget(enabled: !self.staticLayout, targeted: self.$dropTargeted) { providers in
            let store = self.store
            NotchDropLoader.load(providers) { urls in store.stage(urls) }
        })
        .onChange(of: self.store.selectedChatID) { _, _ in self.draft = "" }
        // However the field got focus (a click on the native field, or the tap handler), make sure the notch has the
        // keyboard and stays open while you type.
        .onChange(of: self.focused) { _, isFocused in
            if isFocused { NotchHubController.shared.beginTextEntry() }
        }
        .onDisappear { NotchHubController.shared.endTextEntry() }
    }

    private func send() {
        if self.store.stagedFiles.isEmpty {
            self.store.send(self.draft)
        } else {
            // Files go first, then the text typed beside them.
            self.store.sendStaged(thenText: self.draft)
        }
        self.draft = ""
    }

    /// In a group, the first name of who is talking, shown above their first message in a run.
    private func senderLabel(at index: Int) -> String? {
        guard self.store.isGroup(chatID: self.store.selectedChatID) else { return nil }
        let thread = self.store.thread
        let message = thread[index]
        guard !message.isFromMe, !message.senderHandle.isEmpty else { return nil }
        if index > 0, !thread[index - 1].isFromMe, thread[index - 1].senderHandle == message.senderHandle { return nil }
        return self.store.firstName(forHandle: message.senderHandle)
    }
}

private struct Bubble: View {
    let message: ThreadMessage
    var label: String? = nil
    @State private var pressing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let label {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.leading, 10)
                    .padding(.top, 3)
            }
            self.row
            if self.message.failed {
                Text("Not delivered")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 10)
            }
        }
    }

    private var row: some View {
        HStack {
            if self.message.isFromMe { Spacer(minLength: 40) }
            Text(NotchMessagesSettings.showsPreviews ? NotchLinkText.attributed(self.message.text, linkColor: self.message.isFromMe ? .white : Color(red: 0.45, green: 0.72, blue: 1.0)) : AttributedString("Message"))
                .environment(\.openURL, NotchLinkText.openAction)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                // Drag to highlight words, double-click for a word, ⌘C or the right-click menu to copy. Pressing on a message takes the keyboard
                // (the notch stays open until you click away or press Esc, as when typing a reply), which is what lets ⌘C reach it.
                .textSelection(.enabled)
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !self.pressing else { return }
                        self.pressing = true
                        NotchHubController.shared.beginTextEntry()
                    }
                    .onEnded { _ in self.pressing = false })
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.message.isFromMe ? Color.blue : Color.white.opacity(0.16)))
                .fixedSize(horizontal: false, vertical: true)
            if !self.message.isFromMe { Spacer(minLength: 40) }
        }
    }
}

/// The "New message" search: type a name, number or email; pick a result to open its chat.
private struct ComposeList: View {
    @ObservedObject var store: MessagesStore
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            TextField("", text: self.$query, prompt: Text("To: name, number or email").foregroundStyle(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .tint(.white)
                .focused(self.$focused)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Capsule().fill(Color.white.opacity(0.1)))
                .onChange(of: self.query) { _, text in self.store.updateCompose(query: text) }
                .onSubmit { if let first = self.store.composeResults.first { self.store.openResult(first) } }
                .onExitCommand { self.focused = false; NotchHubController.shared.endTextEntry(); self.store.cancelCompose() }
                .onChange(of: self.focused) { _, on in if on { NotchHubController.shared.beginTextEntry() } }
                .onAppear {
                    NotchHubController.shared.beginTextEntry()
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        self.focused = true
                    }
                }
                .onDisappear { NotchHubController.shared.endTextEntry() }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(self.store.composeResults) { result in
                        Button { self.store.openResult(result) } label: {
                            HStack(spacing: 8) {
                                if let group = result.group {
                                    NotchGroupAvatar(handles: group.handles, size: 26)
                                } else {
                                    NotchAvatar(name: result.name, handle: result.handle, size: 26)
                                }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(result.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(result.detail).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if !self.query.isEmpty, self.store.composeResults.isEmpty {
                        Text("No one found. Type a full number or email to message it.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).padding(.top, 6)
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }
}
