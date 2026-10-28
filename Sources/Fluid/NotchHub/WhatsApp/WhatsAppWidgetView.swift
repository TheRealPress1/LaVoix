import SwiftUI

/// WhatsApp in the notch, laid out like Messages: your latest chats on the left (with a search above them for anyone else with a phone number), and on the
/// right the open chat with a box to write in. A chat is always open. Messages go out through WhatsApp Desktop without it coming to the front.
struct WhatsAppWidgetView: View {
    @ObservedObject var store: WhatsAppStore
    @Environment(\.notchWidgetActive) private var active
    @State private var query = ""
    @State private var draft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var draftFocused: Bool

    var body: some View {
        Group {
            switch self.store.state {
            case .loading:
                ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                VStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 24, weight: .light)).foregroundStyle(.white.opacity(0.6))
                    Text("Couldn’t read WhatsApp on this Mac").font(.system(size: 14, weight: .semibold))
                    Text("Open WhatsApp Desktop once, and make sure myOS has Full Disk Access.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if self.store.recents.isEmpty && self.store.selected == nil {
                    Text("No WhatsApp chats yet.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    self.layout
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { self.store.refreshRecents(); self.store.search(self.query) }
        .onChange(of: self.query) { _, text in if self.active { self.store.search(text) } }
        .onChange(of: self.searchFocused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
        .onChange(of: self.draftFocused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
        .onDisappear { NotchHubController.shared.endTextEntry() }
        // Look again every few seconds while this tab is showing, so new messages appear without reopening the notch.
        .task(id: self.active) {
            while self.active, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard self.active else { break }
                self.store.refreshRecents()
                self.store.refreshThread()
            }
        }
    }

    private var searching: Bool { !self.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var layout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 4) {
                self.searchBar
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        if self.searching {
                            if self.store.contacts.isEmpty {
                                Text("No one with a phone number matches.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).padding(.top, 8)
                            }
                            ForEach(self.store.contacts) { person in
                                self.contactRow(person).onTapGesture { self.store.open(contact: person); self.query = "" }
                            }
                        } else {
                            ForEach(self.store.recents) { chat in
                                self.chatRow(chat).onTapGesture { self.store.open(chat: chat) }
                            }
                        }
                    }
                }
            }
            .frame(width: 232)

            self.thread.frame(maxWidth: .infinity)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.75))
            TextField("", text: self.$query, prompt: Text("Search or new message").foregroundStyle(.white.opacity(0.55)))
                .textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).tint(.white)
                .focused(self.$searchFocused)
                .onSubmit { if let first = self.store.contacts.first, self.searching { self.store.open(contact: first); self.query = "" } }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private func chatRow(_ chat: WhatsAppChat) -> some View {
        let unread = self.store.hasUnread(chat)
        let selected = self.store.selected?.phone == chat.phone
        return HStack(spacing: 9) {
            NotchAvatar(name: chat.name, handle: "+" + chat.phone, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(chat.name).font(.system(size: 12.5, weight: unread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.relative(chat.lastDate)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                Text(chat.lastText).font(.system(size: 11.5)).foregroundStyle(.white.opacity(unread ? 0.8 : 0.5)).lineLimit(1)
            }
            if unread { Circle().fill(Color(red: 0.145, green: 0.827, blue: 0.4)).frame(width: 8, height: 8) }
        }
        .padding(.horizontal, 8).frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.12 : 0)))
        .contentShape(Rectangle())
    }

    private func contactRow(_ person: FaceTimeContact) -> some View {
        HStack(spacing: 9) {
            NotchAvatar(name: person.name, handle: person.address, size: 30)
            Text(person.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8).frame(height: 38)
        .contentShape(Rectangle())
    }

    private var thread: some View {
        VStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(self.store.thread) { message in
                            self.bubble(message.text, fromMe: message.isFromMe).id(message.id)
                        }
                        ForEach(self.store.pending) { message in
                            self.bubble(message.text, fromMe: true).opacity(0.6).id(message.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: self.store.thread) { _, thread in if let last = thread.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: self.store.pending) { _, items in if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: self.store.selected) { _, _ in self.draft = "" }
                .onAppear { if let last = self.store.thread.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let error = self.store.error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField("", text: self.$draft, prompt: Text("WhatsApp").foregroundStyle(.white.opacity(0.45)))
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white).tint(.white)
                    .focused(self.$draftFocused)
                    .onSubmit { self.send() }
                    .onExitCommand { self.draftFocused = false; NotchHubController.shared.endTextEntry() }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
                    .onTapGesture {
                        NotchHubController.shared.beginTextEntry()
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            self.draftFocused = true
                        }
                    }
                Button(action: self.send) {
                    Image(systemName: self.store.isSending ? "ellipsis" : "arrow.up")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(self.draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(self.draft.trimmingCharacters(in: .whitespaces).isEmpty || self.store.isSending)
            }
        }
    }

    private func bubble(_ text: String, fromMe: Bool) -> some View {
        HStack {
            if fromMe { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: 12.5)).foregroundStyle(.white)
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fromMe ? Color(red: 0.0, green: 0.36, blue: 0.3) : Color.white.opacity(0.16)))
                .fixedSize(horizontal: false, vertical: true)
            if !fromMe { Spacer(minLength: 40) }
        }
    }

    private func send() {
        self.store.send(self.draft)
        self.draft = ""
    }

    private static func relative(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604_800 { return "\(Int(seconds / 86_400))d" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
