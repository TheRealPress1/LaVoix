import SwiftUI

/// Replaces the System tiles while an agent is looking into a resource: working, then a list to approve, then what was done.
struct SystemFixPanel: View {
    @ObservedObject var agent: SystemFixAgent
    @ObservedObject private var hub = NotchHubController.shared.model
    @Environment(\.notchWidgetActive) private var active
    @State private var deselected: Set<String> = []
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        self.content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: NaturalHeightKey.self, value: proxy.size.height) })
            .onPreferenceChange(NaturalHeightKey.self) { self.naturalHeight = $0; self.growNotch() }
            .onChange(of: self.active) { _, _ in self.growNotch() }
            .onChange(of: self.hub.tabsExpanded) { _, _ in self.growNotch() }
            .onDisappear { self.hub.setExtraHeight(0) }
    }

    /// A long list makes the notch taller instead of scrolling: ask for what the content needs beyond the room there is.
    private func growNotch() {
        guard self.active else { self.hub.setExtraHeight(0); return }
        let base = self.hub.tabsExpanded ? NotchGeometry.openSize.height : NotchGeometry.openSizeCollapsed.height
        let room = base - max(self.hub.closedSize.height, 28) - 14 // the tab's own top and bottom padding
        self.hub.setExtraHeight(self.naturalHeight - room)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch self.agent.phase {
            case .idle:
                EmptyView()
            case let .investigating(resource):
                self.header("Looking into \(resource.title)…", button: "Cancel")
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("An agent is checking what holds it. It can only look; nothing changes until you approve.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            case let .proposal(resource, plan):
                self.proposal(resource, plan)
            case let .applying(resource):
                self.header("Fixing \(resource.title)…", button: nil)
                ProgressView().controlSize(.small)
            case let .finished(resource, report):
                self.finished(resource, report)
            case let .failed(resource, message):
                self.header("Couldn't look into \(resource.title)", button: "Close")
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
        .onChange(of: self.agent.phase) { _, _ in self.deselected = [] }
    }

    private func header(_ title: String, button: String?) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let button {
                Button(button) { self.agent.dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Proposal

    @ViewBuilder
    private func proposal(_ resource: SystemResource, _ plan: SystemFixPlan) -> some View {
        let chosen = plan.actions.filter { !self.deselected.contains($0.id) }
        self.header(plan.actions.isEmpty ? "Nothing safe to clear" : "Proposed for \(resource.title)", button: "Not now")
        Text(plan.summary)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        if !plan.actions.isEmpty {
            VStack(spacing: 6) {
                ForEach(plan.actions) { action in self.row(action) }
            }
            HStack {
                let bytes = chosen.reduce(UInt64(0)) { $0 + ($1.kind == .trashPath ? ($1.bytes ?? 0) : 0) }
                Text(bytes > 0 ? "Moves \(Self.size(bytes)) to the Trash" : "Nothing is deleted")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer()
                Button {
                    self.agent.apply(plan, selected: Set(chosen.map(\.id)), resource: resource)
                } label: {
                    Text("Approve \(chosen.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(chosen.isEmpty ? 0.3 : 0.95)))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty)
            }
        }
    }

    private func row(_ action: SystemFixAction) -> some View {
        let on = !self.deselected.contains(action.id)
        return Button {
            if on { self.deselected.insert(action.id) } else { self.deselected.remove(action.id) }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Color.orange : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text((action.kind == .quitApp ? "Quit " : "Trash ") + action.label)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let bytes = action.bytes {
                            Text(Self.size(bytes))
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Text(action.reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Result

    @ViewBuilder
    private func finished(_ resource: SystemResource, _ report: SystemFixReport) -> some View {
        self.header("Done", button: nil)
        VStack(alignment: .leading, spacing: 3) {
            if !report.quitAsked.isEmpty {
                Text("Asked to quit: " + report.quitAsked.joined(separator: ", "))
            }
            if !report.trashed.isEmpty {
                Text("Moved \(Self.size(report.trashedBytes)) to the Trash"
                    + (report.trashEmptied == true ? " and emptied it." : ". The space comes back once the Trash is emptied."))
            }
            if !report.skipped.isEmpty {
                Text("Skipped (gone or not allowed): " + report.skipped.joined(separator: ", "))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(2)
        HStack {
            if !report.trashed.isEmpty, report.trashEmptied == nil {
                Button("Empty Trash") { self.agent.emptyTrash(resource: resource, report: report) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Close") { self.agent.dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private static func size(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private struct NaturalHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
