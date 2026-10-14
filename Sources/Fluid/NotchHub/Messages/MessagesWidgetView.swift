import AppKit
import SwiftUI

/// Conversations on the left, the open thread and a reply box on the right.
struct MessagesWidgetView: View {
    @ObservedObject var store: MessagesStore
    /// Image previews can't draw scroll views or text fields; this swaps in static stand-ins.
    var staticLayout = false

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

    private var conversationsAndThread: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if self.staticLayout {
                    self.rows
                } else {
                    ScrollView(.vertical, showsIndicators: false) { self.rows }
                }
            }
            .frame(width: 232)

            ThreadView(store: self.store, staticLayout: self.staticLayout)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
    }

    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(self.store.conversations) { conversation in
                ConversationRow(
                    conversation: conversation,
                    title: self.store.title(for: conversation),
                    selected: conversation.id == self.store.selectedChatID
                )
                .onTapGesture { self.store.select(conversation.id) }
            }
        }
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

private struct ConversationRow: View {
    let conversation: MessageConversation
    let title: String
    let selected: Bool

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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(self.selected ? 0.12 : 0)))
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard NotchMessagesSettings.showsPreviews else { return self.conversation.unreadCount > 0 ? "New message" : "Message" }
        return (self.conversation.lastIsFromMe ? "You: " : "") + self.conversation.lastText
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

    var body: some View {
        VStack(spacing: 8) {
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
                        .background(Circle().fill(Color.white.opacity(self.draft.isEmpty ? 0.3 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(self.draft.trimmingCharacters(in: .whitespaces).isEmpty || self.store.isSending)
            }
        }
        .onChange(of: self.store.selectedChatID) { _, _ in self.draft = "" }
        // However the field got focus (a click on the native field, or the tap handler), make sure the notch has the
        // keyboard and stays open while you type.
        .onChange(of: self.focused) { _, isFocused in
            if isFocused { NotchHubController.shared.beginTextEntry() }
        }
        .onDisappear { NotchHubController.shared.endTextEntry() }
    }

    private func send() {
        self.store.send(self.draft)
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
        }
    }

    private var row: some View {
        HStack {
            if self.message.isFromMe { Spacer(minLength: 40) }
            Text(NotchMessagesSettings.showsPreviews ? NotchLinkText.attributed(self.message.text, linkColor: self.message.isFromMe ? .white : Color(red: 0.45, green: 0.72, blue: 1.0)) : AttributedString("Message"))
                .environment(\.openURL, NotchLinkText.openAction)
                .font(.system(size: 12.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(self.message.isFromMe ? Color.blue : Color.white.opacity(0.16)))
                .fixedSize(horizontal: false, vertical: true)
            if !self.message.isFromMe { Spacer(minLength: 40) }
        }
    }
}
