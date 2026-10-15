import AppKit
import Combine
import SwiftUI

/// "Recent Writing": text you were typing in other apps, saved a moment after you stopped, so a draft lost to a stray click,
/// a closed tab or a reload can be copied back. Everything stays on this Mac.
struct WritingRecoveryView: View {
    @Environment(\.theme) private var theme

    @State private var entries: [WritingEntry] = []
    @State private var query = ""
    @State private var enabled = WritingRecoverySettings.isEnabled
    @State private var days = WritingRecoverySettings.retentionDays
    @State private var excluded = WritingRecoverySettings.excludedBundles
    @State private var trusted = AXIsProcessTrusted()
    @State private var expanded: Set<Int64> = []
    @State private var copied: String?
    @State private var confirmClear = false
    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                self.header
                self.controls
                if !self.trusted { self.permissionNotice }
                if self.entries.isEmpty { self.emptyState } else { ForEach(self.entries) { self.row($0) } }
                if !self.excluded.isEmpty { self.excludedList }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(self.theme.palette.contentBackground)
        .onAppear { self.reload() }
        .onReceive(self.refresh) { _ in
            self.trusted = AXIsProcessTrusted()
            self.reload()
        }
        .onChange(of: self.query) { _, _ in self.reload() }
        .confirmationDialog("Delete all saved writing?", isPresented: self.$confirmClear) {
            Button("Delete everything", role: .destructive) { WritingRecoveryStore.shared.deleteAll(); self.reload() }
        } message: { Text("This cannot be undone.") }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Writing").font(self.theme.typography.title)
            Text("Text you were typing, saved a moment after you stop. Copy it back if a page reloads, a tab closes or you click away. Stays on this Mac; passwords, terminals and code editors are never recorded.")
                .font(self.theme.typography.caption).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("Keep recent writing", isOn: Binding(get: { self.enabled }, set: { value in
                    self.enabled = value
                    WritingRecoverySettings.isEnabled = value
                    WritingRecoveryMonitor.shared.apply()
                }))
                .toggleStyle(.switch)
                Picker("Keep for", selection: Binding(get: { self.days }, set: { value in
                    self.days = value
                    WritingRecoverySettings.retentionDays = value
                    WritingRecoveryStore.shared.purge(olderThanDays: value)
                    self.reload()
                })) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.menu).frame(width: 170)
                Spacer()
                Button("Delete all…", role: .destructive) { self.confirmClear = true }.disabled(self.entries.isEmpty)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your recent writing", text: self.$query).textFieldStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(self.theme.palette.cardBackground))
        }
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Accessibility access is needed").font(self.theme.typography.captionStrong)
            Text("LaVoix reads the text field you are typing in through Accessibility. Allow LaVoix in System Settings → Privacy & Security → Accessibility.")
                .font(self.theme.typography.caption).foregroundStyle(.secondary)
            Button("Open Accessibility settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
    }

    private var emptyState: some View {
        Text(self.query.isEmpty
            ? "Nothing saved yet. Start writing somewhere (at least a sentence or two) and it will show up here a few seconds after you pause."
            : "No saved writing matches that.")
            .font(self.theme.typography.body).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24)
    }

    private func row(_ entry: WritingEntry) -> some View {
        let isOpen = self.expanded.contains(entry.id)
        let shown = entry.latest.isEmpty ? entry.peak : entry.latest
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.appName).font(self.theme.typography.captionStrong)
                if !entry.windowTitle.isEmpty {
                    Text(entry.windowTitle).font(self.theme.typography.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text("\(entry.lastAt.formatted(.relative(presentation: .named))) · \(shown.count) characters")
                    .font(self.theme.typography.caption).foregroundStyle(.secondary)
            }
            Text(isOpen ? shown : String(shown.prefix(280)) + (shown.count > 280 ? "…" : ""))
                .font(self.theme.typography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if entry.hasLongerDraft {
                Text("Earlier this was longer (\(entry.peak.count) characters). The longest version is kept too.")
                    .font(self.theme.typography.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button(self.copied == "l\(entry.id)" ? "Copied" : "Copy") { self.copy(shown, tag: "l\(entry.id)") }
                if entry.hasLongerDraft {
                    Button(self.copied == "p\(entry.id)" ? "Copied" : "Copy longest") { self.copy(entry.peak, tag: "p\(entry.id)") }
                }
                if shown.count > 280 || entry.versionCount > 1 {
                    Button(isOpen ? "Hide" : (entry.versionCount > 1 ? "Show all & \(entry.versionCount) versions" : "Show all")) {
                        if isOpen { self.expanded.remove(entry.id) } else { self.expanded.insert(entry.id) }
                    }
                }
                Spacer()
                Button("Never record \(entry.appName)") {
                    WritingRecoverySettings.excludedBundles = self.excluded + [entry.bundleID]
                    self.excluded = WritingRecoverySettings.excludedBundles
                    WritingRecoveryStore.shared.deleteAll(bundleID: entry.bundleID)
                    self.reload()
                }
                Button(role: .destructive) { WritingRecoveryStore.shared.delete(entryID: entry.id); self.reload() } label: { Image(systemName: "trash") }
                    .help("Delete this saved writing")
            }
            .buttonStyle(.link).font(self.theme.typography.caption)
            if isOpen, entry.versionCount > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WritingRecoveryStore.shared.versions(entryID: entry.id)) { v in
                        HStack(alignment: .firstTextBaseline) {
                            Text(v.at.formatted(date: .abbreviated, time: .shortened)).font(self.theme.typography.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                            Text("\(v.text.count) chars").font(self.theme.typography.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            Text(String(v.text.prefix(90))).font(self.theme.typography.caption).lineLimit(1)
                            Spacer()
                            Button("Copy") { self.copy(v.text, tag: "v\(v.id)") }.buttonStyle(.link).font(self.theme.typography.caption)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(self.theme.palette.cardBackground)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(self.theme.palette.cardBorder.opacity(0.6), lineWidth: 1)))
    }

    private var excludedList: some View {
        DisclosureGroup("Apps never recorded (\(self.excluded.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(self.excluded, id: \.self) { bundle in
                    HStack {
                        Text(bundle).font(self.theme.typography.caption)
                        Spacer()
                        Button("Allow again") {
                            WritingRecoverySettings.excludedBundles = self.excluded.filter { $0 != bundle }
                            self.excluded = WritingRecoverySettings.excludedBundles
                        }.buttonStyle(.link).font(self.theme.typography.caption)
                    }
                }
            }
        }
        .font(self.theme.typography.caption)
    }

    // MARK: Actions

    private func reload() {
        let q = self.query
        DispatchQueue.global(qos: .userInitiated).async {
            let found = WritingRecoveryStore.shared.entries(search: q)
            DispatchQueue.main.async { if q == self.query { self.entries = found } }
        }
    }

    private func copy(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        self.copied = tag
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if self.copied == tag { self.copied = nil } }
    }
}
