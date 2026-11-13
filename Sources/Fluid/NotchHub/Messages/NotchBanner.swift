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
    /// The group's own picture, when it has one.
    var groupPhoto: NSImage? = nil
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
    /// A second, quieter button beside the first ("Allow once" next to "Always for Dia"); it only appears with the first.
    var action2Label: String? = nil
    var action2ID: String? = nil
    /// Look's own, quieter card (see NotchLookCardView) instead of the connection alert's coloured disc.
    var lookStyle = false
    /// Set when Look proposes a calendar event: the card draws it as a calendar tile with Approve (see NotchEventProposalCard), and the card's own button is not drawn.
    var eventProposal: EventProposal? = nil
    /// Set for a WhatsApp message: the number it came from. Replies go out through WhatsApp, and pressing the card opens that chat in the WhatsApp tab.
    var whatsAppPhone: String? = nil
    /// The files that came with the message: shown as small tiles under the name (enlarged when the pointer rests on one).
    var files: [MessageAttachment] = []
    /// `text` is only the stand-in for the files ("Photo"), so the tiles are shown instead of it.
    var textIsPlaceholder = false
    /// Set for the card that confirms a new calendar meeting (its time, the Meet link, who was invited), instead of a message.
    var meetingSet: MeetingSet? = nil
    /// Set for the "Welcome back" strip that widens out of the notch when it comes back on (see NotchWelcomeStripView); it has no text of its own.
    var welcomeBack = false

    /// A meeting that was just set, as the card tells it.
    struct MeetingSet: Equatable {
        var title: String
        var start: Date
        var end: Date
        var meetLink: URL?
        /// Who was invited, by name.
        var invited: [String]
        /// Made through Google (which sends the invitations); false for a meeting saved in the Mac's Calendar only.
        var viaGoogle: Bool

        /// "Today · 3:45 – 4:15 PM", "Tomorrow · ...", or the weekday and date for another day.
        static func whenLine(start: Date, end: Date, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
            let day: String
            if calendar.isDate(start, inSameDayAs: now) { day = "Today" }
            else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) { day = "Tomorrow" }
            else { day = start.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated).month(.abbreviated).day()) }
            let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            return "\(day) · \(start.formatted(time)) – \(end.formatted(time))"
        }

        var whenLine: String { Self.whenLine(start: self.start, end: self.end) }

        /// "Google Meet link ready · Invited Léa D., Martin B. +1", or what is true when there is neither.
        var detailLine: String {
            var parts: [String] = []
            if self.meetLink != nil { parts.append("Google Meet link ready") }
            if !self.invited.isEmpty {
                let names = self.invited.prefix(2).joined(separator: ", ") + (self.invited.count > 2 ? " +\(self.invited.count - 2)" : "")
                parts.append("Invited \(names)")
            }
            return parts.isEmpty ? "Added to your calendar" : parts.joined(separator: " · ")
        }
    }

    /// Whether the words are drawn (not when they are only the stand-in for tiles that are).
    var showsText: Bool { self.files.isEmpty || !self.textIsPlaceholder }
    /// The card's height while a file is enlarged: room for the picture, and a video's motion.
    static let enlargedHeight: CGFloat = 214

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

    /// Everything in the card that sits under the notch band, with the reply row only when expanded, and room for the enlarged file while one is.
    func contentHeight(expanded: Bool, enlarged: Bool = false) -> CGFloat {
        if self.welcomeBack { return 0 }
        // Title row, the time, one more line, then the buttons.
        if self.meetingSet != nil { return 8 + 19 + 2 + 17 + 2 + 15 + 12 + 30 + 18 }
        if let event = self.eventProposal { return NotchEventProposalCard.contentHeight(event) }
        if self.lookStyle { return NotchLookCardView.contentHeight(text: self.text, hasButtons: self.actionLabel != nil, cardWidth: NotchGeometry.bannerWidth) }
        // With no words under the name, the row is as tall as the avatar (40) rather than the name, so the tile does not sit on the card's edge.
        let top: CGFloat = self.showsText
            ? 8 + 19 + (self.subtitle == nil ? 0 : 16) + 2 + self.textHeight
            : 8 + max(40, 19 + (self.subtitle == nil ? 0 : 18))
        let tiles: CGFloat = self.files.isEmpty ? 0 : 12 + AttachmentTile.side
        let base = top + tiles + 18 + (expanded && self.alertSymbol == nil ? 12 + 34 : 0) + (self.actionLabel != nil ? 12 + 30 : 0)
        return enlarged && !self.files.isEmpty ? max(base, Self.enlargedHeight) : base
    }
}

/// An iOS-style notification card that drops out of the notch. Hover to reveal a reply box.
struct NotchBannerView: View {
    let content: NotchBannerContent
    let expanded: Bool
    /// Image previews can't draw text fields; this swaps in a static stand-in.
    var staticLayout = false
    /// The closed notch's width, which the welcome strip leaves clear.
    var notchWidth: CGFloat = 190
    /// A still preview can't hover, so it can ask for a file's enlarged view to be drawn.
    static var previewEnlarged: MessageAttachment?

    @StateObject private var hovering = AttachmentHoverModel()
    @State private var draft = ""
    @State private var sent = false
    @State private var copied = false
    @FocusState private var focused: Bool

    private var blue: Color { self.content.whatsAppPhone == nil ? Color(red: 0.04, green: 0.52, blue: 1.0) : Color(red: 0.145, green: 0.827, blue: 0.4) }
    private var serviceName: String { self.content.whatsAppPhone == nil ? "iMessage" : "WhatsApp" }

    private var enlargedFile: MessageAttachment? { self.hovering.enlarged ?? Self.previewEnlarged }

    var body: some View {
        if self.content.welcomeBack {
            NotchWelcomeStripView(notchWidth: self.notchWidth, staticLayout: self.staticLayout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let set = self.content.meetingSet {
            self.meetingBody(set)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let event = self.content.eventProposal {
            NotchEventProposalCard(
                proposal: event, width: NotchGeometry.bannerWidth,
                onApprove: { id in
                    NotchHubController.shared.dismissBanner()
                    ConnectionsWidgetView.press(id)
                },
                onDismiss: { NotchHubController.shared.dismissBanner() }
            )
        } else if self.content.lookStyle {
            self.lookBody
        } else {
            self.standardBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .overlay {
                    // The file the pointer rests on, large over the card. It never takes the pointer, so its tile stays hovered.
                    if let file = self.enlargedFile {
                        EnlargedFile(file: file, staticLayout: self.staticLayout)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                            .padding(.bottom, 16)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: self.enlargedFile?.id)
                .onAppear {
                    self.hovering.onChange = { on in NotchHubController.shared.setBannerEnlarged(on) }
                }
                .onDisappear {
                    self.hovering.clear()
                }
        }
    }

    /// The card that says a meeting was set: who and when, whether it has a Meet link or invitations, and two buttons.
    private func meetingBody(_ set: NotchBannerContent.MeetingSet) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.14))
                    if set.meetLink != nil {
                        GoogleMeetLogo().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "calendar.badge.checkmark").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(set.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("Meeting set").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                    }
                    Text(set.whenLine).font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    Text(set.detailLine).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { NotchHubController.shared.openConversationFromBanner() }
            HStack(spacing: 8) {
                if let link = set.meetLink {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(link.absoluteString, forType: .string)
                        self.copied = true
                    } label: {
                        Label(self.copied ? "Copied" : "Copy Meet link", systemImage: self.copied ? "checkmark" : "link")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.16)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                Button { NotchHubController.shared.openConversationFromBanner() } label: {
                    Text("Open").font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).frame(height: 30)
                        .background(Capsule().fill(Color.white))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private var lookBody: some View {
        NotchLookCardView(
            title: self.content.title,
            text: self.content.text,
            symbol: self.content.alertSymbol ?? "sparkles",
            width: NotchGeometry.bannerWidth,
            primaryLabel: self.content.actionID == nil ? nil : self.content.actionLabel,
            secondaryLabel: self.content.action2Label,
            onPrimary: {
                guard let id = self.content.actionID else { return }
                NotchHubController.shared.dismissBanner()
                ConnectionsWidgetView.press(id)
            },
            onSecondary: {
                guard let id = self.content.action2ID else { return }
                NotchHubController.shared.dismissBanner()
                ConnectionsWidgetView.press(id)
            }
        )
    }

    private var standardBody: some View {
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
                    NotchGroupAvatar(handles: self.content.groupHandles, photo: self.content.groupPhoto)
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
                    if self.content.showsText {
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
            }
            .contentShape(Rectangle())
            .onTapGesture { NotchHubController.shared.openConversationFromBanner() }

            // The files that came with the message, under the name and words, past the avatar. Pressing one opens it (the card then goes away).
            if !self.content.files.isEmpty {
                HStack {
                    AttachmentTiles(files: self.content.files, fromMe: false, staticLayout: self.staticLayout, onHover: { self.hovering.hover($0, $1) }, onOpen: { file in
                        AttachmentOpener.open(file)
                        NotchHubController.shared.dismissBanner()
                    })
                    Spacer(minLength: 0)
                }
                .padding(.leading, 52)
            }

            if let label = self.content.actionLabel, let id = self.content.actionID {
                HStack(spacing: 8) {
                    if let label2 = self.content.action2Label, let id2 = self.content.action2ID {
                        Button {
                            NotchHubController.shared.dismissBanner()
                            ConnectionsWidgetView.press(id2)
                        } label: {
                            Text(label2)
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(Capsule().fill(Color.white.opacity(0.16)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
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
            // The whole capsule is the reply box, not only the line of text inside it: pressing anywhere on it starts the cursor.
            .onTapGesture { self.startTyping() }
            // Hovering a card is enough to start typing; this runs for as long as the box is on screen, until the cursor is really in it.
            .task { await self.focusWhenReady() }

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

    /// Gives the notch the keyboard and puts the cursor in the box (looking again until it is really there).
    private func startTyping() {
        guard !self.staticLayout, !self.sent else { return }
        NotchHubController.shared.placeCursor { self.focused = $0 }
    }

    /// Hovering a card is enough to start typing: once the reply box is on screen, the cursor is put in it (see `placeCursorLoop`), for as long as the box stays.
    @MainActor
    private func focusWhenReady() async {
        guard !self.staticLayout, !self.sent else { return }
        await NotchHubController.shared.placeCursorLoop { self.focused = $0 }
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
    /// The group's own picture: shown whole when there is one.
    var photo: NSImage? = nil
    var size: CGFloat = 40
    @ObservedObject private var contacts = ContactResolver.shared

    var body: some View {
        let inner = self.size * 0.68
        ZStack {
            if let photo = self.photo {
                Image(nsImage: photo).resizable().scaledToFill().frame(width: self.size, height: self.size).clipShape(Circle())
            } else if self.handles.count >= 2 {
                // No picture of its own: two of the people's faces, and a plus when there are more.
                self.avatar(self.handles[0], size: inner)
                    .position(x: inner / 2, y: inner / 2)
                self.avatar(self.handles[1], size: inner)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: max(1.5, self.size * 0.05)))
                    .position(x: self.size - inner / 2, y: self.size - inner / 2)
                if self.handles.count > 2 {
                    ZStack {
                        Circle().fill(Color(white: 0.28))
                        Image(systemName: "plus").font(.system(size: self.size * 0.2, weight: .bold)).foregroundStyle(.white)
                    }
                    .frame(width: self.size * 0.36, height: self.size * 0.36)
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: max(1.5, self.size * 0.05)))
                    .position(x: self.size - self.size * 0.18, y: self.size * 0.18)
                }
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
