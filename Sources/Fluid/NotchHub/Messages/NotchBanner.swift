import AppKit
import SwiftUI

/// What a notification card shows.
struct NotchBannerContent: Equatable, Identifiable {
    let id = UUID()
    let chatID: Int64
    let chatGUID: String
    let title: String
    /// The person's phone number or email, used to look up their photo. nil for group chats.
    var avatarHandle: String? = nil
    /// Everyone in the group, so a group card can show overlapping avatars. Empty for one-to-one chats.
    var groupHandles: [String] = []
    /// Who spoke, in a group chat.
    let subtitle: String?
    let text: String
    let date: Date
    /// Set for a connection alert (not a message): the card shows this symbol instead of an avatar and has no reply box.
    var alertSymbol: String? = nil
    /// A connector's logo (its id, e.g. "bump") drawn instead of the symbol on an alert card.
    var alertIcon: String? = nil
    /// What clicking an alert card does.
    var alertAction: AlertAction = .fullDiskAccess
    enum AlertAction: Equatable { case fullDiskAccess, openMyOS }
    /// A button on an alert card (and what pressing the card does): myOS runs the action, e.g. signing a mailbox in again.
    var actionLabel: String? = nil
    var actionID: String? = nil
    /// Set for a WhatsApp message: the number it came from. Replies go out through WhatsApp, and pressing the card opens that chat in the WhatsApp tab.
    var whatsAppPhone: String? = nil

    /// Width left for the message text inside the card: card width minus side padding, avatar and spacing.
    static let textWidth: CGFloat = NotchGeometry.bannerWidth - 44 - 40 - 12
    static let textFont = NSFont.systemFont(ofSize: 13.5)
    /// Longest message shown in full; anything beyond ends in an ellipsis.
    static let maxLines = 5

    private static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: self.textFont) }

    /// How many lines the message really needs at the card's width, so the card can grow to fit it.
    var visibleLines: Int {
        let bounds = (self.text as NSString).boundingRect(
            with: CGSize(width: Self.textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.textFont]
        )
        return min(Self.maxLines, max(1, Int((bounds.height / Self.lineHeight).rounded(.up))))
    }

    /// Height of the message text block.
    var textHeight: CGFloat { CGFloat(self.visibleLines) * Self.lineHeight + 2 }

    /// Everything in the card that sits under the notch band, with the reply row only when expanded.
    func contentHeight(expanded: Bool) -> CGFloat {
        let header: CGFloat = 8 + 19 + (self.subtitle == nil ? 0 : 16) + 2
        return header + self.textHeight + 18 + (expanded && self.alertSymbol == nil ? 12 + 34 : 0) + (self.actionLabel != nil ? 12 + 30 : 0)
    }
}

/// An iOS-style notification card that drops out of the notch. Hover to reveal a reply box.
struct NotchBannerView: View {
    let content: NotchBannerContent
    let expanded: Bool
    /// Image previews can't draw text fields; this swaps in a static stand-in.
    var staticLayout = false

    @State private var draft = ""
    @State private var sent = false
    @FocusState private var focused: Bool

    private var blue: Color { self.content.whatsAppPhone == nil ? Color(red: 0.04, green: 0.52, blue: 1.0) : Color(red: 0.145, green: 0.827, blue: 0.4) }
    private var serviceName: String { self.content.whatsAppPhone == nil ? "iMessage" : "WhatsApp" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let icon = self.content.alertIcon {
                    ConnectorIconView(id: icon, title: self.content.title, size: 40)
                        .frame(width: 40, height: 40)
                } else if let symbol = self.content.alertSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color.orange.opacity(0.9)))
                } else if self.content.groupHandles.isEmpty {
                    NotchAvatar(name: self.content.title, handle: self.content.avatarHandle)
                } else {
                    NotchGroupAvatar(handles: self.content.groupHandles)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(self.content.title)
                            .font(.system(size: 14.5, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("now")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if let subtitle = self.content.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    Text(NotchLinkText.attributed(self.content.text))
                        .environment(\.openURL, OpenURLAction { url in
                            NSWorkspace.shared.open(url)
                            NotchHubController.shared.dismissBanner()
                            return .handled
                        })
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(self.content.visibleLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { NotchHubController.shared.openConversationFromBanner() }

            if let label = self.content.actionLabel, let id = self.content.actionID {
                Button {
                    NotchHubController.shared.dismissBanner()
                    ConnectionsWidgetView.press(id)
                } label: {
                    Text(label)
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .background(Capsule().fill(Color.orange.opacity(0.95)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }

            if self.expanded, self.content.alertSymbol == nil { self.replyRow.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private var replyRow: some View {
        HStack(spacing: 8) {
            Group {
                if self.sent {
                    Label("Sent", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if self.staticLayout {
                    Text(self.serviceName)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: self.$draft, prompt: Text(self.serviceName).foregroundStyle(.white.opacity(0.45)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused(self.$focused)
                        .onSubmit { self.send() }
                        .onExitCommand { self.focused = false; NotchHubController.shared.dismissBanner() }
                        .onChange(of: self.draft) { _, text in NotchHubController.shared.bannerHasDraft = !text.isEmpty }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.13)))
            .contentShape(Capsule())
            .onAppear { self.focusSoon() }

            Button(action: self.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(self.draft.isEmpty || self.sent ? self.blue.opacity(0.35) : self.blue))
            }
            .buttonStyle(.plain)
            .disabled(self.draft.trimmingCharacters(in: .whitespaces).isEmpty || self.sent)
        }
    }

    /// The notch window has to become key before a field can take focus, so ask a moment later.
    private func focusSoon() {
        guard !self.staticLayout else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.focused = true
        }
    }

    private func send() {
        let text = self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !self.sent else { return }
        self.sent = true
        self.draft = ""
        NotchHubController.shared.sendFromBanner(text, content: self.content)
    }
}

struct NotchAvatar: View {
    let name: String
    var handle: String?
    var size: CGFloat = 40
    @ObservedObject private var contacts = ContactResolver.shared

    var body: some View {
        ZStack {
            if let handle, let photo = self.contacts.photo(for: handle) {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: [self.tint, self.tint.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                Text(self.initials)
                    .font(.system(size: self.size * 0.375, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(Circle())
    }

    private var initials: String {
        let letters = self.name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty || self.name.first?.isNumber == true || self.name.first == "+" ? "•" : letters
    }

    private var tint: Color {
        let palette: [Color] = [
            Color(red: 0.96, green: 0.45, blue: 0.35), Color(red: 0.98, green: 0.65, blue: 0.20),
            Color(red: 0.30, green: 0.75, blue: 0.45), Color(red: 0.25, green: 0.68, blue: 0.85),
            Color(red: 0.42, green: 0.45, blue: 0.95), Color(red: 0.75, green: 0.40, blue: 0.85),
        ]
        let hash = self.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }
}


/// A group chat's picture: two overlapping avatars (the first two people in it), so it reads as a group at a glance.
struct NotchGroupAvatar: View {
    let handles: [String]
    var size: CGFloat = 40
    @ObservedObject private var contacts = ContactResolver.shared

    var body: some View {
        let inner = self.size * 0.68
        ZStack {
            if self.handles.count >= 2 {
                self.avatar(self.handles[0], size: inner)
                    .position(x: inner / 2, y: inner / 2)
                self.avatar(self.handles[1], size: inner)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: max(1.5, self.size * 0.05)))
                    .position(x: self.size - inner / 2, y: self.size - inner / 2)
            } else {
                // Not enough people known to draw two: a plain group mark.
                Circle().fill(Color.white.opacity(0.18))
                Image(systemName: "person.2.fill").font(.system(size: self.size * 0.42)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: self.size, height: self.size)
    }

    private func avatar(_ handle: String, size: CGFloat) -> some View {
        NotchAvatar(name: self.contacts.name(for: handle) ?? handle, handle: handle, size: size)
    }
}
