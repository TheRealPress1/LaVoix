import SwiftUI

/// Write to someone on WhatsApp from the notch: type a name (the people you are closest to come first), press one, type, send. The message goes out through
/// WhatsApp Desktop without WhatsApp coming to the front. Names and numbers come from myOS and are never kept here.
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
        .onAppear { self.store.search(self.query) }
        .onChange(of: self.query) { _, text in if self.active { self.store.search(text) } }
        .onChange(of: self.searchFocused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
        .onChange(of: self.draftFocused) { _, f in if f { NotchHubController.shared.beginTextEntry() } }
        .onDisappear { NotchHubController.shared.endTextEntry() }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    TextField("", text: self.$query, prompt: Text("Who do you want to message on WhatsApp?").foregroundStyle(.white.opacity(0.45)))
                        .textFieldStyle(.plain).foregroundStyle(.white).tint(.white)
                        .focused(self.$searchFocused)
                        .onSubmit { if let first = self.store.contacts.first { self.store.open(first) } }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
                Button { self.store.openWhatsApp() } label: {
                    Text("Open WhatsApp").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
            switch self.store.state {
            case .loading:
                ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                Text("myOS isn’t set up on this Mac, so there are no people to message yet.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                if self.store.contacts.isEmpty {
                    Text("No one with a phone number matches.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 6)], spacing: 6) {
                            ForEach(self.store.contacts) { person in
                                Button { self.store.open(person) } label: {
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
            }
        }
    }

    private func conversation(_ person: FaceTimeContact) -> some View {
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
            let sent = self.store.sent[person.id] ?? []
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .trailing, spacing: 5) {
                        if sent.isEmpty {
                            Text("Messages you send here go through WhatsApp. The conversation itself stays in WhatsApp.")
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(sent) { message in
                            Text(message.text)
                                .font(.system(size: 13)).foregroundStyle(.white)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.0, green: 0.36, blue: 0.3)))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onChange(of: sent) { _, items in if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) } }
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

    private func send() {
        self.store.send(self.draft)
        self.draft = ""
    }
}
