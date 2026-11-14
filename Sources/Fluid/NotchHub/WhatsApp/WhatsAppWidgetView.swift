import SwiftUI

/// WhatsApp in the notch, laid out like Messages: your latest chats on the left (with a search above them for anyone else with a phone number), and on the
/// right the open chat with a box to write in. A chat is always open. Messages go out through WhatsApp Desktop without it coming to the front.
struct WhatsAppWidgetView: View {
    @ObservedObject var store: WhatsAppStore
    /// Image previews can't draw scroll views or text fields, and must not read anything: this swaps in static stand-ins.
    var staticLayout = false
    /// A still preview can't hover, so it can ask for one file's enlarged view to be drawn.
    var previewEnlargedFileID: Int64? = nil
    /// Previews can't click: this draws the emoji row open.
    var previewEmojiOpen = false
    /// Previews can't type: this draws a `/look` in the reply box with what it found (or was looking for) above it.
    var previewPlaces: NotchPlaceLookup.State? = nil
    /// `/look <place>` typed in the reply box: what Apple Maps found, shown above the box.
    @StateObject private var places = NotchPlaceLookup()
    @Environment(\.notchWidgetActive) private var active
    @State private var query = ""
    @State private var draft = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var draftFocused: Bool
    /// The file the pointer has rested on, shown large over the chat until the pointer leaves it.
    @StateObject private var hovering = AttachmentHoverModel()
    /// The emoji row above the reply box, opened by the smiley beside it (the recents are shared with Messages).
    @State private var emojiOpen = false
    @State private var recentEmojis = NotchEmojiSettings.recents
    private var showsEmoji: Bool { self.emojiOpen || self.previewEmojiOpen }

    private var enlargedFile: MessageAttachment? {
        self.hovering.enlarged ?? self.previewEnlargedFileID.flatMap { id in self.store.thread.lazy.flatMap(\.attachments).first { $0.id == id } }
    }

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
        .onAppear { if !self.staticLayout { self.store.refreshRecents(); self.store.search(self.query) } }
        .onChange(of: self.query) { _, text in if self.active { self.store.search(text) } }
        .onChange(of: self.searchFocused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
        .onChange(of: self.draftFocused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
        .onDisappear { self.hovering.clear(); NotchHubController.shared.endTextEntry() }
        // Look again every few seconds while this tab is showing, so new messages appear without reopening the notch.
        .task(id: self.active) {
            while self.active, !self.staticLayout, !Task.isCancelled {
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
                if self.staticLayout {
                    self.listRows
                } else {
                    ScrollView(.vertical, showsIndicators: false) { self.listRows }
                }
            }
            .frame(width: 232)

            self.thread.frame(maxWidth: .infinity)
        }
    }

    private var listRows: some View {
        VStack(spacing: 4) {
            if self.searching {
                if self.store.contacts.isEmpty {
                    Text("No one with a phone number matches.").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).padding(.top, 8)
                }
                ForEach(self.store.contacts) { person in
                    self.contactRow(person).onTapGesture { self.store.open(contact: person); self.query = ""; self.store.requestReplyFocus() }
                }
            } else {
                ForEach(self.store.recents) { chat in
                    self.chatRow(chat).onTapGesture {
                        self.store.open(chat: chat)
                        // Picking a chat by hand puts you in its reply box, so you can start typing at once (as in Messages).
                        self.store.requestReplyFocus()
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.75))
            if self.staticLayout {
                Text("Search or new message").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.55)).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: self.$query, prompt: Text("Search or new message").foregroundStyle(.white.opacity(0.55)))
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.white).tint(.white)
                    .focused(self.$searchFocused)
                    .onSubmit { if let first = self.store.contacts.first, self.searching { self.store.open(contact: first); self.query = ""; self.store.requestReplyFocus() } }
            }
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
                HStack(spacing: 4) {
                    // A message that is only a picture or video: a tiny picture of it beside "Photo", as in Messages.
                    if let file = chat.lastFile { AttachmentMiniThumb(file: file, staticLayout: self.staticLayout) }
                    Text(chat.lastText).font(.system(size: 11.5)).foregroundStyle(.white.opacity(unread ? 0.8 : 0.5)).lineLimit(1)
                }
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
            if self.staticLayout {
                VStack(spacing: 5) {
                    ForEach(self.store.thread) { message in self.messageRow(message) }
                    Spacer(minLength: 0)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 5) {
                            ForEach(self.store.thread) { message in
                                self.messageRow(message).id(message.id)
                            }
                            ForEach(self.store.pending) { message in
                                self.bubble(message.text, fromMe: true).opacity(0.6).id(message.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .simultaneousGesture(TapGesture().onEnded { self.emojiOpen = false })
                    .onChange(of: self.store.thread) { _, thread in if let last = thread.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: self.store.pending) { _, items in if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                    .onChange(of: self.store.selected) { _, _ in self.draft = ""; self.hovering.clear(); self.emojiOpen = false; self.places.clear() }
                    .onChange(of: self.draft) { _, text in self.places.draftChanged(to: text) }
                    .onChange(of: self.places.ready) { _, place in if let place { self.pick(place) } }
                    .onAppear { if let last = self.store.thread.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if let error = self.store.error {
                Text(error).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            NotchPlaceResults(state: self.previewPlaces ?? self.places.state, selected: self.previewPlaces == nil ? self.places.selected : 0, resolving: self.places.resolving, staticLayout: self.staticLayout, onPick: { self.pick($0) }, onNext: { self.places.next() })
            if self.showsEmoji { NotchEmojiStrip(recents: self.recentEmojis, staticLayout: self.staticLayout) { self.add($0) } }
            HStack(spacing: 8) {
                self.replyField
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                    .contentShape(Capsule())
                    .onTapGesture { self.emojiOpen = false; self.startTyping() }
                Button { self.emojiOpen.toggle(); if self.emojiOpen { self.startTyping() } } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(self.showsEmoji ? 0.9 : 0.5))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Emoji")
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
        .overlay {
            // A picture, video or document the pointer rests on, large over the chat. It never takes the pointer itself, so the tile under it stays hovered.
            if let file = self.enlargedFile {
                EnlargedFile(file: file, staticLayout: self.staticLayout).allowsHitTesting(false).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: self.enlargedFile?.id)
        // The cursor was asked for (a chat picked by hand, or opened from a card): it goes to the reply box.
        .onChange(of: self.store.replyFocusRequest) { _, _ in
            self.emojiOpen = false
            _ = self.store.consumePendingReplyFocus()
            if !self.staticLayout { self.startTyping() }
        }
        // A chat opened from a card: the request was made before this chat was on screen, so it takes it as it appears.
        .onAppear { if !self.staticLayout, self.store.consumePendingReplyFocus() { self.startTyping() } }
    }

    /// Adds the emoji to what is being typed, remembers it among the recents (shared with Messages) and leaves the cursor in the box.
    private func add(_ emoji: String) {
        self.draft += emoji
        self.recentEmojis = EmojiPalette.recording(emoji, in: self.recentEmojis)
        NotchEmojiSettings.recents = self.recentEmojis
        self.startTyping()
    }

    /// Gives the notch the keyboard and puts the cursor in the reply box (looking again until it is really there).
    private func startTyping() {
        NotchHubController.shared.placeCursor { self.draftFocused = $0 }
    }

    /// The reply box. The focus is set on the text field itself (set on a wrapper around it, it did nothing: only a click on the field gave it the cursor).
    @ViewBuilder
    private var replyField: some View {
        if self.staticLayout {
            Text(self.previewPlaces == nil ? "WhatsApp" : (self.previewPlaces == .typing ? "/look" : "/look Atlanta International School")).font(.system(size: 13)).foregroundStyle(.white.opacity(self.previewPlaces == nil ? 0.4 : 0.95)).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: self.$draft, prompt: Text("WhatsApp").foregroundStyle(.white.opacity(0.45)))
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(.white).tint(.white)
                .focused(self.$draftFocused)
                .onSubmit { self.send() }
                .onExitCommand { self.draftFocused = false; NotchHubController.shared.endTextEntry() }
        }
    }

    /// One message: its picture, video, sticker or document as small tiles on the sender's side, then its words (none when the words were only the stand-in "Photo").
    private func messageRow(_ message: WhatsAppMessage) -> some View {
        let showsFiles = !message.attachments.isEmpty
        let showsText = !(showsFiles && message.textIsPlaceholder)
        return VStack(alignment: .leading, spacing: 2) {
            if showsFiles {
                HStack {
                    if message.isFromMe { Spacer(minLength: 40) }
                    AttachmentTiles(files: message.attachments, fromMe: message.isFromMe, staticLayout: self.staticLayout, mineColor: Color(red: 0.0, green: 0.36, blue: 0.3), onHover: { file, inside in self.hovering.hover(file, inside) })
                    if !message.isFromMe { Spacer(minLength: 40) }
                }
            }
            if showsText { self.bubble(message.text, fromMe: message.isFromMe) }
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
        // "/look <place>" is a question for the notch, never a message: Return (or the arrow) takes the suggestion showing, and its address goes in the box.
        if NotchPlaceCommand.isCommand(self.draft) { self.useShownPlace(); return }
        self.store.send(self.draft)
        self.draft = ""
    }

    /// Return (or the arrow) in a `/look` box: the suggestion showing goes in the box; with none yet, it goes in the moment one comes (`places.ready`).
    private func useShownPlace() {
        if let place = self.places.returnPressed() { self.pick(place) }
    }

    /// The address replaces the `/look` in the box, ready to send; nothing is sent. Its address was asked for in the background as the suggestion showed, so this is
    /// usually at once.
    private func pick(_ place: PlaceCandidate) {
        Task { @MainActor in
            guard let address = await self.places.address(for: place) else { return }
            self.places.clear()
            self.draft = address
            self.startTyping()
        }
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
