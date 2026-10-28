import SwiftUI

/// WhatsApp in the notch: opens on your latest chats (like Messages), a search for anyone else with a phone number, and a conversation view with what was said
/// and a box to write in. Messages go out through WhatsApp Desktop without it coming to the front.
struct WhatsAppWidgetView: View {
    @ObservedObject var store: WhatsAppStore
    @Environment(\.notchWidgetActive) private var active
    @State private var query = ""
    @State private var draft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var draftFocused: Bool

    private let green = Color(red: 0.145, green: 0.827, blue: 0.4)

    var body: some View {
        Group {
            if let person = self.store.selected {
                self.conversation(person)
            } else {
                self.picker
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
                if self.store.selected != nil { self.store.refreshThread() } else { self.store.refreshRecents() }
            }
        }
    }

    private var searching: Bool { !self.query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    TextField("", text: self.$query, prompt: Text("Search for someone to message on WhatsApp").foregroundStyle(.white.opacity(0.45)))
                        .textFieldStyle(.plain).foregroundStyle(.white).tint(.white)
                        .focused(self.$searchFocused)
                        .onSubmit {
                            if self.searching, let first = self.store.contacts.first { self.store.open(contact: first) }
                            else if let first = self.store.recents.first { self.store.open(chat: first) }
                        }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                Button { self.store.openWhatsApp() } label: {
                    Text("Open WhatsApp").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            if self.searching {
                if self.store.contacts.isEmpty {
                    Text("No one with a phone number matches.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], spacing: 6) {
                            ForEach(self.store.contacts) { person in
                                Button { self.store.open(contact: person) } label: {
                                    HStack(spacing: 6) {
                                        Text(person.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 4)
                                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.35))
                                    }
                                    .padding(.horizontal, 10).frame(height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                switch self.store.state {
                case .loading:
                    ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .unavailable:
                    Text("Couldn’t read WhatsApp on this Mac. Open WhatsApp Desktop once, and make sure myOS has Full Disk Access.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    if self.store.recents.isEmpty {
                        Text("No WhatsApp chats yet.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 6)], spacing: 4) {
                                ForEach(self.store.recents) { chat in
                                    Button { self.store.open(chat: chat) } label: { self.recentRow(chat) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func recentRow(_ chat: WhatsAppChat) -> some View {
        let unread = self.store.hasUnread(chat)
        return HStack(spacing: 9) {
            NotchAvatar(name: chat.name, handle: "+" + chat.phone, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(chat.name).font(.system(size: 12.5, weight: unread ? .bold : .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.relative(chat.lastDate)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
                Text(chat.lastText.isEmpty ? "Media" : chat.lastText)
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(unread ? 0.8 : 0.5)).lineLimit(1)
            }
            if unread { Circle().fill(self.green).frame(width: 8, height: 8) }
        }
        .padding(.horizontal, 8).frame(height: 38)
        .contentShape(Rectangle())
    }

    private func conversation(_ person: WhatsAppStore.Target) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { self.store.close(); self.draft = "" } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Text(person.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text("WhatsApp").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
            }
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
                        .background(Circle().fill(self.green.opacity(self.draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.3 : 1)))
                }
                .buttonStyle(.plain)
                .disabled(self.draft.trimmingCharacters(in: .whitespaces).isEmpty || self.store.isSending)
            }
        }
    }

    private func bubble(_ text: String, fromMe: Bool) -> some View {
        Text(text)
            .font(.system(size: 13)).foregroundStyle(.white)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fromMe ? Color(red: 0.0, green: 0.36, blue: 0.3) : Color.white.opacity(0.14)))
            .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
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
