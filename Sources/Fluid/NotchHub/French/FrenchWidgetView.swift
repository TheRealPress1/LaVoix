import AppKit
import SwiftUI

/// The French tab: type or paste French on the left, Claude's corrected version on the right with the changed words marked and the reason for each.
struct FrenchWidgetView: View {
    @ObservedObject var store: FrenchStore
    /// Image previews can't draw a text editor; this swaps in a static stand-in.
    var staticLayout = false
    @FocusState private var focused: Bool
    @State private var copied = false

    /// Where the first line of typed text sits inside the editor: the editor's own padding plus the text view's side gap (5 pt) horizontally,
    /// and just the padding vertically. The placeholder, the static preview and the hint on the right all use these so they share one first line.
    private static let editorPadding: CGFloat = 6
    private static let textInsetX: CGFloat = editorPadding + 5
    private static let textInsetY: CGFloat = editorPadding
    private static let placeholder = "Type or paste text, in any language"

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            self.inputColumn.frame(width: 280)
            self.resultColumn.frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onDisappear { NotchHubController.shared.endTextEntry() }
    }

    // MARK: - Input

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.1))
                if self.staticLayout {
                    Text(self.store.input.isEmpty ? Self.placeholder : self.store.input)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(self.store.input.isEmpty ? 0.4 : 1))
                        .padding(.horizontal, Self.textInsetX)
                        .padding(.vertical, Self.textInsetY)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: self.$store.input)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused(self.$focused)
                        .padding(Self.editorPadding)
                        .onExitCommand { self.focused = false; NotchHubController.shared.endTextEntry() }
                        .onChange(of: self.focused) { _, on in if on { NotchHubController.shared.beginTextEntry() } }
                        .onChange(of: self.store.input) { _, _ in self.copied = false }
                    if self.store.input.isEmpty {
                        Text(Self.placeholder)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, Self.textInsetX)
                            .padding(.vertical, Self.textInsetY)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { self.startTyping() }

            HStack(spacing: 8) {
                // What the button will do: translate when the text looks like another language than the destination, correct otherwise.
                self.pill(self.store.willTranslate ? "Translate" : "Correct", prominent: true, enabled: self.store.canCorrect) { self.store.correct() }
                    .keyboardShortcut(.return, modifiers: .command)
                if !self.store.input.isEmpty {
                    self.pill("Clear", prominent: false, enabled: true) { self.store.clear(); self.startTyping() }
                }
                Spacer(minLength: 0)
                if !self.store.input.isEmpty {
                    Text(self.store.detected.map { "\($0.name) · \(self.store.input.count)" } ?? "\(self.store.input.count)")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.white.opacity(self.store.input.count > FrenchStore.maxCharacters ? 0.9 : 0.35))
                }
            }
        }
    }

    private func startTyping() {
        guard !self.staticLayout else { return }
        NotchHubController.shared.beginTextEntry()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.focused = true
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultColumn: some View {
        switch self.store.phase {
        case .idle:
            self.hint("Claude translates it into \(self.store.destination.name), or corrects the spelling, grammar and punctuation if it is already in \(self.store.destination.name), and keeps your wording.")
        case .working:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text(self.store.willTranslate ? "Claude is translating…" : "Claude is checking…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .needsAllow:
            self.allowCard
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                self.pill("Try again", prominent: false, enabled: true) { self.store.correct() }
                Spacer(minLength: 0)
            }
            .padding(.top, Self.textInsetY + 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        case let .done(result):
            self.resultView(result)
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 12 pt text, so one point lower than the editor's inset puts its first baseline level with the placeholder's.
            .padding(.top, Self.textInsetY + 1)
    }

    /// The first time only: what is sent, to whom, and what is not.
    private var allowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Send what you type to Claude?", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
            Text("The text goes to Claude through your own login, only when you press Correct or Translate. Email addresses, links and long numbers are hidden before it leaves this Mac; names and the rest of the words are not. Nothing is kept: the log holds counts, never text.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                self.pill("Allow and correct", prominent: true, enabled: true) { self.store.correct(allow: true) }
                self.pill("Not now", prominent: false, enabled: true) { self.store.dismissResult() }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Self.textInsetY)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultView(_ result: FrenchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // The same top inset as the editor's text, inside the scrolled content so a scrolled result still slides under the top edge.
            self.scrolling { self.resultBody(result).padding(.top, Self.textInsetY) }
            HStack(spacing: 8) {
                self.pill(self.copied ? "Copied" : "Copy", prominent: true, enabled: true) { self.copy(result.corrected) }
                self.pill("Keep editing", prominent: false, enabled: true) { self.store.keepEditing(); self.startTyping() }
                Spacer(minLength: 0)
            }
        }
    }

    /// Previews can't draw a scroll view, so they get the same content, cut at the edge. It is laid over an empty box so a long result can't
    /// ask for its full height and push the Copy row (and the editor's Correct row beside it) off the bottom, as a real scroll view never lets it.
    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if self.staticLayout {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) { content().frame(maxWidth: .infinity, alignment: .topLeading) }
                .clipped()
        } else {
            ScrollView(.vertical, showsIndicators: false) { content() }
        }
    }

    private func resultBody(_ result: FrenchResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(self.marked(result))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let note = result.note {
                Text(note).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).fixedSize(horizontal: false, vertical: true)
            }
            if let from = result.translatedFrom {
                Text("Translated from \(from)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
            } else if result.changes.isEmpty {
                Text(result.note == nil ? "Already correct: nothing to change." : "")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
            } else {
                Text("\(result.changes.count) correction\(result.changes.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .textCase(.uppercase)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.changes) { change in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(change.before).strikethrough().foregroundStyle(.white.opacity(0.5))
                                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                                Text(change.after).fontWeight(.medium)
                            }
                            .font(.system(size: 12))
                            if !change.why.isEmpty {
                                Text(change.why).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The corrected text with the words that changed marked.
    private func marked(_ result: FrenchResult) -> AttributedString {
        var text = AttributedString(result.corrected)
        // A translation is new text all through, so nothing is marked in it.
        if result.translatedFrom != nil { return text }
        for range in FrenchDiff.changedRanges(old: self.store.correctedFrom, new: result.corrected) {
            guard let start = AttributedString.Index(range.lowerBound, within: text), let end = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[start..<end].backgroundColor = Color(red: 0.2, green: 0.55, blue: 0.3).opacity(0.55)
        }
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.copied = true
    }

    private func pill(_ title: String, prominent: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                // A disabled main button turns into a quiet one instead of a dimmed white one, which read as muddy grey with dark text.
                .foregroundStyle(!enabled ? Color.white.opacity(0.4) : (prominent ? Color.black : Color.white))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(!enabled ? Color.white.opacity(0.1) : (prominent ? Color.white : Color.white.opacity(0.14))))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}


/// On the right of the title band while the tab is open: the language it comes out in, which opens a short list to change it. The list is drawn
/// inside the notch (not a system menu, which would take the pointer out of the window and let the notch close under it).
struct FrenchLanguagePicker: View {
    @ObservedObject var store: FrenchStore
    @State private var open: Bool

    init(store: FrenchStore, startOpen: Bool = false) {
        self.store = store
        self._open = State(initialValue: startOpen)
    }

    var body: some View {
        Button {
            self.open.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                Text(self.store.destination.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(self.open ? 180 : 0))
            }
            .foregroundStyle(.white.opacity(self.open ? 0.8 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("The language it comes out in")
        .overlay(alignment: .topTrailing) {
            if self.open { self.list.offset(y: 24) }
        }
        .onDisappear { self.open = false }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TRANSLATE INTO")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 10)
                .padding(.top, 5)
                .padding(.bottom, 2)
            ForEach(CorrectionLanguage.allCases) { language in
                Button {
                    self.store.select(language)
                    self.open = false
                } label: {
                    HStack(spacing: 8) {
                        Text(language.name).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 16)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .opacity(language == self.store.destination ? 1 : 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .frame(width: 140)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.15)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }
}
