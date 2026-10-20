import Combine
import SwiftUI

/// Your quick links as chips; click one and it is on the clipboard. The + chip adds one (it offers whatever you just copied).
struct QuickLinksWidgetView: View {
    @ObservedObject var store: QuickLinksStore
    @Environment(\.notchWidgetActive) private var active
    @State private var adding = false
    @State private var label = ""
    @State private var value = ""
    @State private var problem: String?
    @FocusState private var focused: Field?
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private enum Field { case label, value }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if self.adding {
                self.form
            } else if self.store.links.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 24)).foregroundStyle(.white.opacity(0.35))
                    Text("Keep the links you paste often right here").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                    Button("Add a link") { self.startAdding() }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(self.store.links) { link in
                            QuickLinkChip(link: link, copied: self.store.copiedID == link.id) { self.store.copy(link) }
                                .contextMenu { Button("Remove") { self.store.remove(link) } }
                        }
                        Button { self.startAdding() } label: {
                            HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 11)); Text("Add").font(.system(size: 13, weight: .medium)) }
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(maxWidth: .infinity).frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { self.store.reload() }
        .onReceive(self.refresh) { _ in if self.active, !self.adding { self.store.reload() } }
        .onChange(of: self.focused) { _, f in if f != nil { NotchHubController.shared.beginTextEntry() } }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New quick link").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).textCase(.uppercase)
            HStack(spacing: 8) {
                self.field("Name, e.g. LinkedIn", text: self.$label, focus: .label).frame(width: 190)
                self.field("Link or text to copy", text: self.$value, focus: .value)
            }
            HStack(spacing: 10) {
                Button("Save") { self.save() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 28)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
                Button("Cancel") { self.adding = false; self.problem = nil }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                if let problem = self.problem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange) }
            }
        }
    }

    private func field(_ prompt: String, text: Binding<String>, focus: Field) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(.white.opacity(0.45)))
            .textFieldStyle(.plain)
            .foregroundStyle(.white)
            .tint(.white)
            .focused(self.$focused, equals: focus)
            .onSubmit { if focus == .label { self.focused = .value } else { self.save() } }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private func startAdding() {
        self.label = ""
        self.problem = nil
        // Offer what you just copied, when it is a short single line (the usual case: you copied your own link to save it).
        let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.value = (!copied.isEmpty && copied.count <= 300 && !copied.contains("\n")) ? copied : ""
        if let guess = Self.nameGuess(for: self.value) { self.label = guess }
        self.adding = true
        DispatchQueue.main.async { self.focused = self.label.isEmpty ? .label : .value }
    }

    private func save() {
        do {
            try self.store.add(label: self.label, value: self.value)
            self.adding = false
            self.problem = nil
        } catch {
            self.problem = error.localizedDescription
        }
    }

    /// "https://www.linkedin.com/in/me" suggests "Linkedin"; anything that isn't a link suggests nothing.
    nonisolated static func nameGuess(for text: String) -> String? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = host.split(separator: ".")
        guard let name = parts.count >= 2 ? parts[parts.count - 2] : parts.first, !name.isEmpty else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

private struct QuickLinkChip: View {
    let link: QuickLinksStore.Link
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 6) {
                if self.copied {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).frame(width: 18, height: 18)
                } else {
                    QuickLinkIcon(kind: QuickLinkKind.of(self.link.value))
                }
                Text(self.copied ? "Copied" : self.link.label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(self.copied ? 0.22 : (self.hovering ? 0.14 : 0.07))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
        .help(self.link.value)
    }
}
