import AppKit
import SwiftUI

/// The Translate tab, a small hub for translating and for writing correctly in another language.
///
/// A bar on top: the language the typing looks like (found on this Mac as it is typed), a button that turns the translation round, the six languages it
/// can come out in, and the recent results. Under it two cards: what you type or paste on the left (with Paste or Clear, how formal to be, and the main
/// button), and what comes back on the right (the text to copy, read aloud or keep editing, with the corrections behind a button).
///
/// Claude does the translating through your own login, by way of myOS; what is typed is sent only when you press the button.
struct FrenchWidgetView: View {
    @ObservedObject var store: FrenchStore
    @ObservedObject private var speaker = FrenchSpeaker.shared
    /// Image previews can't draw a text editor or a scroll view; this swaps in static stand-ins.
    var staticLayout = false
    /// Previews can't click: this draws the "Copied" state.
    var previewCopied = false
    @FocusState private var focused: Bool
    @State private var copied = false
    @State private var copyToken = 0
    @State private var showRecent: Bool
    @State private var showChanges: Bool
    @State private var pulse = false

    init(store: FrenchStore, staticLayout: Bool = false, previewCopied: Bool = false, previewRecent: Bool = false, previewChanges: Bool = false) {
        self._store = ObservedObject(wrappedValue: store)
        self.staticLayout = staticLayout
        self.previewCopied = previewCopied
        self._showRecent = State(initialValue: previewRecent)
        self._showChanges = State(initialValue: previewChanges)
    }

    private var showsCopied: Bool { self.copied || self.previewCopied }

    /// Where the first line of text sits inside a card: the editor's own padding plus the text view's side gap (5 pt) horizontally, and just the padding
    /// vertically. The placeholder, the static preview and the result all use these so the two cards share one first line.
    private static let editorPadding: CGFloat = 6
    private static let textInsetX: CGFloat = editorPadding + 5
    private static let textInsetY: CGFloat = editorPadding
    private static let placeholder = "Type or paste text, in any language"
    private static let textFont = Font.system(size: 14)
    private static let green = Color(red: 0.45, green: 0.85, blue: 0.55)

    var body: some View {
        VStack(spacing: 8) {
            self.languageBar
            HStack(alignment: .top, spacing: 10) {
                self.inputCard.frame(maxWidth: .infinity, maxHeight: .infinity)
                self.outputCard.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(.white)
        .onDisappear {
            NotchHubController.shared.endTextEntry()
            self.speaker.stop()
        }
    }

    // MARK: - Language bar

    private var languageBar: some View {
        HStack(spacing: 8) {
            self.sourcePill
            Spacer(minLength: 6)
            self.swapButton
            Spacer(minLength: 6)
            HStack(spacing: 3) {
                ForEach(CorrectionLanguage.allCases) { self.chip($0) }
            }
            self.recentButton
        }
        .frame(height: 26)
    }

    /// The language the text is in: what the typing looks like before a result, what Claude named after one.
    private var sourcePill: some View {
        let label: String
        var auto = false
        if case let .done(result) = self.store.phase {
            label = result.translatedFrom ?? self.store.destination.name
        } else if let detected = self.store.detected {
            label = detected.name
            auto = true
        } else {
            label = "Detect language"
        }
        return HStack(spacing: 5) {
            // Nothing to show an icon for until the language is known.
            if self.store.detected != nil || self.store.phaseIsDone {
                Image(systemName: "globe").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            }
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(self.store.detected == nil && !self.store.phaseIsDone ? Color.white.opacity(0.6) : Color.white)
            if auto { Text("detected").font(.system(size: 10)).foregroundStyle(.white.opacity(0.35)) }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .help("The language of the text. It is found as you type; Claude confirms it in its answer.")
    }

    private var swapButton: some View {
        Button { self.showRecent = false; self.store.swapLanguages() } label: {
            Image(systemName: "arrow.left.arrow.right").font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(self.store.canSwap ? 0.85 : 0.25))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(self.store.canSwap ? 0.12 : 0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!self.store.canSwap)
        .help("Turn it round: the translation goes in the box and the language it came from becomes the destination")
        .accessibilityLabel("Swap languages")
    }

    private func chip(_ language: CorrectionLanguage) -> some View {
        let selected = language == self.store.destination
        return Button { self.showRecent = false; self.store.select(language) } label: {
            Text(selected ? language.name : language.code)
                .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.6))
                .padding(.horizontal, selected ? 11 : 8).frame(height: 26)
                .background(Capsule().fill(selected ? Color.white : Color.white.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(selected ? "It comes out in \(language.name)" : "Translate into \(language.name)")
        .accessibilityLabel(language.name)
    }

    private var recentButton: some View {
        Button { self.showRecent.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(self.showRecent ? 0.95 : (self.store.recent.isEmpty ? 0.25 : 0.6)))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(self.showRecent ? 0.16 : 0.05)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(self.store.recent.isEmpty)
        .help("Recent results (kept only until the notch restarts)")
        .accessibilityLabel("Recent results")
    }

    // MARK: - Cards

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var cardBackground: some View {
        self.cardShape.fill(Color.white.opacity(0.06))
            .overlay(self.cardShape.strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    // MARK: - Input

    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if self.staticLayout {
                    Text(self.store.input.isEmpty ? Self.placeholder : self.store.input)
                        .font(Self.textFont)
                        .foregroundStyle(.white.opacity(self.store.input.isEmpty ? 0.4 : 1))
                        .padding(.horizontal, Self.textInsetX)
                        .padding(.vertical, Self.textInsetY)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: self.$store.input)
                        .font(Self.textFont)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused(self.$focused)
                        .padding(Self.editorPadding)
                        .onExitCommand { self.focused = false; NotchHubController.shared.endTextEntry() }
                        .onChange(of: self.focused) { _, on in if on { NotchHubController.shared.beginTextEntry() } }
                        .onChange(of: self.store.input) { _, _ in self.copied = false }
                        .onChange(of: self.store.phase) { _, _ in self.copied = false; self.showChanges = false }
                    if self.store.input.isEmpty {
                        Text(Self.placeholder)
                            .font(Self.textFont)
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

            self.inputFooter
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(self.cardBackground)
    }

    private var inputFooter: some View {
        HStack(spacing: 6) {
            if self.store.input.isEmpty {
                self.softPill("Paste", systemImage: "doc.on.clipboard") { self.paste() }
            } else {
                Button { self.store.clear(); self.startTyping() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.09))).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Clear")
                .accessibilityLabel("Clear")
                Text(self.store.input.count.formatted())
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.white.opacity(self.store.input.count > FrenchStore.maxCharacters ? 0.95 : 0.35))
                if self.store.willTranslate { self.tonePill }
            }
            Spacer(minLength: 0)
            self.mainButton
        }
        .frame(height: 28)
    }

    /// How formal the translation is: Auto, Formal, Casual, one press at a time.
    private var tonePill: some View {
        Button { self.store.cycleTone() } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 9.5, weight: .semibold))
                Text(self.store.tone.label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(self.store.tone == .auto ? 0.55 : 0.95))
            .padding(.horizontal, 8).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(self.store.tone == .auto ? 0.07 : 0.16)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("How formal the translation is (vous or tu, Sie or du). Press to change: Auto, Formal, Casual.")
    }

    /// What the button will do: translate when the text looks like another language than the destination, correct otherwise.
    private var mainButton: some View {
        let working: Bool = { if case .working = self.store.phase { return true } else { return false } }()
        let enabled = self.store.canCorrect
        return Button { self.store.correct() } label: {
            HStack(spacing: 5) {
                Text(working ? "Working…" : (self.store.willTranslate || self.store.input.isEmpty ? "Translate" : "Correct")).font(.system(size: 12, weight: .semibold))
                if !working { Text("⌘↵").font(.system(size: 10, weight: .medium)).opacity(enabled ? 0.45 : 0.3) }
            }
            .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.4))
            .padding(.horizontal, 13).frame(height: 26)
            .background(Capsule().fill(enabled ? Color.white : Color.white.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func startTyping() {
        guard !self.staticLayout else { return }
        NotchHubController.shared.beginTextEntry()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            self.focused = true
        }
    }

    private func paste() {
        guard !self.staticLayout, let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        self.store.input = String(text.prefix(FrenchStore.maxCharacters * 2))
        self.startTyping()
    }

    // MARK: - Output

    private var outputCard: some View {
        VStack(spacing: 0) {
            Group {
                if self.showRecent {
                    self.recentList
                } else {
                    switch self.store.phase {
                    case .idle: self.emptyState
                    case .working: self.workingState
                    case .needsAllow: self.allowCard
                    case let .failed(message): self.failedState(message)
                    case let .done(result): self.resultBody(result)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if !self.showRecent, case let .done(result) = self.store.phase {
                self.outputFooter(result)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .background(
            self.cardShape.fill(Color.white.opacity(self.showsCopied ? 0.14 : 0.06))
                .overlay(self.cardShape.strokeBorder(Color.white.opacity(self.showsCopied ? 0.18 : 0.09), lineWidth: 1))
        )
    }

    /// Nothing asked yet: what the right-hand card is for.
    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "globe").font(.system(size: 26, weight: .ultraLight)).foregroundStyle(.white.opacity(0.22))
            Text("The \(self.store.destination.name) text appears here").font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white.opacity(0.45))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var workingState: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach([1.0, 0.92, 0.6], id: \.self) { width in
                GeometryReader { proxy in
                    Capsule().fill(Color.white.opacity(self.staticLayout || self.pulse ? 0.14 : 0.06)).frame(width: proxy.size.width * width, height: 9)
                }
                .frame(height: 9)
            }
            Text(self.store.willTranslate ? "Translating into \(self.store.destination.name)…" : "Checking your \(self.store.destination.name)…")
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.5)).padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Self.textInsetX).padding(.top, Self.textInsetY + 6)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { self.pulse = true } }
    }

    /// The first time only: what is sent, to whom, and what is not.
    private var allowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Send what you type to Claude?", systemImage: "lock.shield").font(.system(size: 13, weight: .semibold))
            Text("The text goes to Claude through your own login, only when you press the button. Email addresses, links and long numbers are hidden first; the rest of the words are not. Nothing is kept.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                self.pill("Allow and translate", prominent: true) { self.store.correct(allow: true) }
                self.pill("Not now", prominent: false) { self.store.dismissResult() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private func failedState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("That did not work", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            self.pill("Try again", prominent: false) { self.store.correct() }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }

    // MARK: Result

    private func resultBody(_ result: FrenchResult) -> some View {
        Group {
            if self.showChanges {
                self.scrolling { self.changesList(result).padding(.horizontal, 12).padding(.vertical, 10) }
            } else {
                self.scrolling {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(self.marked(result))
                            .font(Self.textFont)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let note = result.note {
                            Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, Self.textInsetX)
                    .padding(.vertical, Self.textInsetY)
                    .contentShape(Rectangle())
                    .onTapGesture { self.copy(result.corrected) }
                    .help("Click to copy the text")
                }
            }
        }
    }

    /// Previews can't draw a scroll view, so they get the same content, cut at the edge. It is laid over an empty box so a long result can't
    /// ask for its full height and push the footer off the bottom, as a real scroll view never lets it.
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

    private func outputFooter(_ result: FrenchResult) -> some View {
        HStack(spacing: 6) {
            self.resultCaption(result)
            Spacer(minLength: 0)
            self.iconButton(self.showsCopied ? "checkmark" : "doc.on.doc", help: self.showsCopied ? "Copied" : "Copy the text", active: self.showsCopied) { self.copy(result.corrected) }
            self.iconButton(self.speaker.speaking ? "stop.fill" : "speaker.wave.2.fill", help: self.speaker.speaking ? "Stop reading" : "Read it aloud", active: self.speaker.speaking) {
                if !self.staticLayout { self.speaker.toggle(result.corrected, language: self.store.destination) }
            }
            self.iconButton("square.and.pencil", help: "Keep editing: put the text back in the box") { self.store.keepEditing(); self.startTyping() }
        }
        .frame(height: 28)
    }

    /// What was done, at the foot of the result: where it was translated from, how many corrections (press to see them), or that it was already right.
    @ViewBuilder
    private func resultCaption(_ result: FrenchResult) -> some View {
        if let from = result.translatedFrom {
            Text("Translated from \(from)").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        } else if result.changes.isEmpty {
            Label("Already correct", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Self.green).lineLimit(1)
        } else {
            Button { self.showChanges.toggle() } label: {
                HStack(spacing: 4) {
                    Text(self.showChanges ? "Show the text" : "\(result.changes.count) correction\(result.changes.count == 1 ? "" : "s")").font(.system(size: 11, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(self.showChanges ? 180 : 0))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(self.showChanges ? 0.16 : 0.09)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func changesList(_ result: FrenchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(result.changes) { change in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(change.before).strikethrough().foregroundStyle(.white.opacity(0.5))
                        Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                        Text(change.after).fontWeight(.medium)
                    }
                    .font(.system(size: 12.5))
                    if !change.why.isEmpty {
                        Text(change.why).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: Recent

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                Text("until the notch restarts").font(.system(size: 10)).foregroundStyle(.white.opacity(0.25))
                Spacer(minLength: 0)
                Button("Clear") { self.store.clearRecent(); self.showRecent = false }.buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
            self.scrolling {
                VStack(spacing: 3) {
                    ForEach(self.store.recent) { item in
                        Button { self.store.restore(item); self.showRecent = false } label: {
                            HStack(spacing: 8) {
                                Text("\(item.source?.code ?? "··") → \(item.target.code)")
                                    .font(.system(size: 10, weight: .semibold).monospaced()).foregroundStyle(.white.opacity(0.5))
                                    .frame(width: 52, alignment: .leading)
                                Text(item.result.corrected.replacingOccurrences(of: "\n", with: " "))
                                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.88)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 10)
    }

    // MARK: - Pieces

    private func iconButton(_ name: String, help: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.black : Color.white.opacity(0.8))
                .frame(width: 26, height: 26)
                .background(Circle().fill(active ? Color.white : Color.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func softPill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10.5, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10).frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func pill(_ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12).frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private func copy(_ text: String) {
        guard !self.staticLayout else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.copied = true
        // "Copied" goes back to the copy button after a moment, so a second click later is understood as another copy.
        self.copyToken += 1
        let token = self.copyToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.copyToken == token { self.copied = false }
        }
    }
}
