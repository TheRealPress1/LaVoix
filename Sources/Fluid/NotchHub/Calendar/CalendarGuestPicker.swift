import SwiftUI

/// Small pieces the calendar's right-hand pane (about 260 points wide) shares between its screens.
enum CalendarPane {
    /// `content` in a scroll view, except in a preview picture, which cannot draw scroll views (the day list does the same).
    @ViewBuilder static func scrolling<Content: View>(staticLayout: Bool, _ axis: Axis.Set = .vertical, @ViewBuilder _ content: () -> Content) -> some View {
        if staticLayout { content() } else { ScrollView(axis, showsIndicators: false) { content() } }
    }

    static func initialsCircle(_ text: String, size: CGFloat) -> some View {
        Text(text.isEmpty ? "•" : text).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size).background(Circle().fill(Color.white.opacity(0.14)))
    }

    /// The title row of a screen inside the pane: a back arrow (or, with `doneTitle`, a Done button on the right) and a name.
    static func subHeader(_ title: String, doneTitle: String? = nil, back: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if doneTitle == nil {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.1))).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            Spacer(minLength: 0)
            if let doneTitle {
                Button(doneTitle, action: back).buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 12).frame(height: 24).background(Capsule().fill(Color.white))
            }
        }
        .frame(height: 26)
    }
}

/// The guest search: a box that looks people up as you type (the people myOS knows and your Contacts, or a full address), the people chosen so far as
/// chips you can remove, and the matches below. It fills the pane; Done (or Return on an empty box, or Escape) hands the choice back.
struct CalendarGuestPicker: View {
    @Binding var guests: [CalendarGuest]
    var title = "Guests"
    /// Addresses that are already on the meeting, never offered again.
    var alreadyInvited: Set<String> = []
    var staticLayout = false
    /// A preview picture's typed text and matches (the real search reads people and contacts, which a preview must not).
    var previewQuery = ""
    var previewSuggestions: [CalendarGuest] = []
    /// Escape throws the chosen people away (when Done is what sends the invitations) instead of keeping them.
    var escapeCancels = false
    let onDone: () -> Void

    @State private var query = ""
    @State private var suggestions: [CalendarGuest] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CalendarPane.subHeader(self.title, doneTitle: "Done", back: { self.finish() })
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                if self.staticLayout {
                    Text(self.query.isEmpty ? "Name or email" : self.query)
                        .foregroundStyle(self.query.isEmpty ? Color.white.opacity(0.45) : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField("", text: self.$query, prompt: Text("Name or email").foregroundStyle(.white.opacity(0.45)))
                        .textFieldStyle(.plain)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused(self.$focused)
                        .onSubmit { self.submit() }
                        .onExitCommand { self.escape() }
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
            if !self.guests.isEmpty { self.chips }
            CalendarPane.scrolling(staticLayout: self.staticLayout) {
                VStack(spacing: 3) {
                    ForEach(self.suggestions) { guest in
                        Button { self.add(guest) } label: {
                            HStack(spacing: 8) {
                                CalendarPane.initialsCircle(guest.initials, size: 24)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(guest.display).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    if guest.display != guest.email {
                                        Text(guest.email).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if self.suggestions.isEmpty, !self.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No one found. Type a full address to add it.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            self.query = self.previewQuery
            self.suggestions = self.previewSuggestions
            guard !self.staticLayout else { return }
            DispatchQueue.main.async { self.focused = true }
        }
        .onChange(of: self.focused) { _, focused in if focused { NotchHubController.shared.beginTextEntry() } }
        .onChange(of: self.query) { _, _ in self.refresh() }
    }

    private var chips: some View {
        CalendarPane.scrolling(staticLayout: self.staticLayout, .horizontal) {
            HStack(spacing: 4) {
                ForEach(self.guests) { guest in
                    Button { self.guests.removeAll { $0 == guest } } label: {
                        HStack(spacing: 4) {
                            Text(guest.display).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(guest.email)")
                }
            }
        }
        .frame(height: 22)
    }

    private func add(_ guest: CalendarGuest) {
        guard !self.guests.contains(where: { $0.email == guest.email }) else { return }
        self.guests.append(guest)
        self.query = ""
        self.suggestions = []
    }

    /// Return in the box: add the first match; with nothing typed, finish.
    private func submit() {
        if self.query.trimmingCharacters(in: .whitespaces).isEmpty { self.finish(); return }
        if let first = self.suggestions.first { self.add(first) }
    }

    private func escape() {
        if self.escapeCancels { self.guests = [] }
        self.finish()
    }

    private func finish() {
        self.query = ""
        self.suggestions = []
        self.onDone()
    }

    /// Looks for people as you type, off the main thread; an answer that comes after the typing moved on is dropped.
    private func refresh() {
        guard !self.staticLayout else { return }
        let typed = self.query
        let taken = Set(self.guests.map(\.email)).union(self.alreadyInvited)
        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else { self.suggestions = []; return }
        Task {
            let found = await Task.detached(priority: .userInitiated) { CalendarGuestDirectory.suggestions(for: typed, excluding: taken) }.value
            if self.query == typed { self.suggestions = found }
        }
    }
}
