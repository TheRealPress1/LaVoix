import AppKit
import SwiftUI

/// The French tab: type or paste French on the left, Claude's corrected version on the right with the changed words marked and the reason for each.
struct FrenchWidgetView: View {
    @ObservedObject var store: FrenchStore
    /// Image previews can't draw a text editor; this swaps in a static stand-in.
    var staticLayout = false
    @FocusState private var focused: Bool
    @State private var copied = false

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
                    Text(self.store.input.isEmpty ? "Écris ou colle ton texte ici" : self.store.input)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(self.store.input.isEmpty ? 0.4 : 1))
                        .padding(10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    TextEditor(text: self.$store.input)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused(self.$focused)
                        .padding(6)
                        .onExitCommand { self.focused = false; NotchHubController.shared.endTextEntry() }
                        .onChange(of: self.focused) { _, on in if on { NotchHubController.shared.beginTextEntry() } }
                        .onChange(of: self.store.input) { _, _ in self.copied = false }
                    if self.store.input.isEmpty {
                        Text("Écris ou colle ton texte ici")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { self.startTyping() }

            HStack(spacing: 8) {
                self.pill("Correct", prominent: true, enabled: self.store.canCorrect) { self.store.correct() }
                    .keyboardShortcut(.return, modifiers: .command)
                if !self.store.input.isEmpty {
                    self.pill("Clear", prominent: false, enabled: true) { self.store.clear(); self.startTyping() }
                }
                Spacer(minLength: 0)
                Text("\(self.store.input.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(self.store.input.count > FrenchStore.maxCharacters ? 0.9 : 0.35))
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
            self.hint("Claude corrects the spelling, grammar and punctuation, and keeps your wording.")
        case .working:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small).colorScheme(.dark)
                Text("Claude is checking…").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
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
            .padding(.top, 4)
    }

    /// The first time only: what is sent, to whom, and what is not.
    private var allowCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Send what you type to Claude?", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
            Text("The text goes to Claude through your own login, only when you press Correct. Email addresses, links and long numbers are hidden before it leaves this Mac; names and the rest of the words are not. Nothing is kept: the log holds counts, never text.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                self.pill("Allow and correct", prominent: true, enabled: true) { self.store.correct(allow: true) }
                self.pill("Not now", prominent: false, enabled: true) { self.store.dismissResult() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func resultView(_ result: FrenchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            self.scrolling { self.resultBody(result) }
            HStack(spacing: 8) {
                self.pill(self.copied ? "Copied" : "Copy", prominent: true, enabled: true) { self.copy(result.corrected) }
                self.pill("Keep editing", prominent: false, enabled: true) { self.store.keepEditing(); self.startTyping() }
                Spacer(minLength: 0)
            }
        }
    }

    /// Previews can't draw a scroll view, so they get the same content, cut at the edge.
    @ViewBuilder
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if self.staticLayout {
            content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
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
            if result.changes.isEmpty {
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
                .foregroundStyle(prominent ? Color.black : Color.white)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.14)))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
