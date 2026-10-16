import AppKit
import SwiftUI

/// Meeting notes: write your own notes, then let the on-device model merge them with the transcript.
struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    @Environment(\.theme) private var theme

    @StateObject private var model = MeetingNotesViewModel()
    @ObservedObject private var local = LocalCleanupController.shared

    var body: some View {
        if let session {
            self.content(session)
                .task(id: session.id) {
                    await self.model.load(session: session)
                    self.model.autoGenerateIfNeeded(session: session, asr: self.asrService, isQuiescent: self.isQuiescent)
                }
        } else {
            Text("Select a meeting to write notes.")
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, self.theme.metrics.spacing.md)
        }
    }

    private func content(_ session: MeetingSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Meeting notes")
                    .font(self.theme.typography.bodyStrong)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Style", selection: Binding(
                    get: { self.model.kind },
                    set: { kind in Task { await self.model.select(kind: kind, session: session) } }
                )) {
                    ForEach(MeetingSummaryKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(self.model.isGenerating)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Your notes")
                    .font(.fluidSystem(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(get: { self.model.notes }, set: { self.model.updateNotes($0) }))
                        .font(.fluidSystem(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 96)
                    if self.model.notes.isEmpty {
                        Text("Jot anything that matters. It gets woven into the notes. Use **bold** or ### headings for what's important.")
                            .font(.fluidSystem(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }

            self.controls(session)

            if !self.model.output.isEmpty {
                self.result
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
    }

    @ViewBuilder
    private func controls(_ session: MeetingSession) -> some View {
        if self.local.status != .ready, SettingsStore.shared.meetingNotesCommand.trimmingCharacters(in: .whitespaces).isEmpty {
            self.modelSetup
        } else {
            HStack(spacing: 12) {
                if self.model.isGenerating {
                    ProgressView().controlSize(.small)
                    if case let .generating(message) = self.model.phase {
                        Text(message)
                            .font(.fluidSystem(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Cancel") { self.model.cancel() }
                } else {
                    Button(self.model.output.isEmpty ? "Write notes" : "Regenerate") {
                        self.model.generate(session: session, asr: self.asrService)
                    }
                    .disabled(!self.isQuiescent)
                    .help(self.isQuiescent ? (SettingsStore.shared.meetingNotesCommand.isEmpty ? "Runs on this Mac" : "Runs your notes command") : "Finish the recording first")
                    if self.model.isStale, !self.model.output.isEmpty {
                        Text("Your notes changed since these were written.")
                            .font(.fluidSystem(size: 12))
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
            if case let .failed(message) = self.model.phase {
                Text(message)
                    .font(.fluidSystem(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }

    private var modelSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes are written by an AI model that runs on your Mac. Nothing is uploaded.")
                .font(.fluidSystem(size: 13))
                .foregroundStyle(.secondary)
            switch self.local.status {
            case let .downloading(fraction):
                if let fraction {
                    ProgressView(value: fraction)
                    Text("Downloading \(Int(fraction * 100))%")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .loading:
                ProgressView().controlSize(.small)
            case let .failed(message):
                Text(message).font(.fluidSystem(size: 12)).foregroundStyle(.red)
                Button("Try again") { self.local.prepare() }
            default:
                Button("Download the model (\(String(format: "%.1f", Double(self.local.selectedModel.approximateBytes) / 1_000_000_000)) GB)") {
                    self.local.prepare()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.model.output, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
            MarkdownNotesText(markdown: self.model.output)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .opacity(self.model.isStale || self.model.isGenerating ? 0.6 : 1)
    }
}

/// Renders the small Markdown subset the notes use: headings, bullets, checkboxes and inline emphasis.
private struct MarkdownNotesText: View {
    let markdown: String

    private struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
        enum Kind { case heading, bullet, checkbox, number, body, gap }
    }

    private var lines: [Line] {
        self.markdown.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return Line(id: index, kind: .gap, text: "") }
            if let range = line.range(of: #"^#{1,3}\s+"#, options: .regularExpression) {
                return Line(id: index, kind: .heading, text: String(line[range.upperBound...]))
            }
            if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                return Line(id: index, kind: .checkbox, text: String(line.dropFirst(6)))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return Line(id: index, kind: .bullet, text: String(line.dropFirst(2)))
            }
            if line.range(of: #"^\d+\.\s+"#, options: .regularExpression) != nil {
                return Line(id: index, kind: .number, text: line)
            }
            return Line(id: index, kind: .body, text: line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(self.lines) { line in
                switch line.kind {
                case .gap:
                    Color.clear.frame(height: 4)
                case .heading:
                    Text(Self.inline(line.text))
                        .font(.fluidSystem(size: 16, weight: .semibold))
                        .padding(.top, 8)
                case .bullet:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(line.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.fluidSystem(size: 14))
                case .checkbox:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "square").foregroundStyle(.secondary).font(.system(size: 12))
                        Text(Self.inline(line.text)).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.fluidSystem(size: 14))
                case .number, .body:
                    Text(Self.inline(line.text))
                        .font(.fluidSystem(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
