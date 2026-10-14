import SwiftUI

/// "Reach out" on the left (overdue against the cadence for their circle), "Recently in touch" on the right.
struct PeopleWidgetView: View {
    @ObservedObject var store: PeopleStore
    var staticLayout = false

    var body: some View {
        Group {
            switch self.store.state {
            case .loading:
                ProgressView().controlSize(.small).tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .unavailable:
                Text("myOS isn’t set up on this Mac, or hasn’t calculated anyone yet.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready:
                HStack(alignment: .top, spacing: 28) {
                    self.column(title: "REACH OUT") {
                        if self.store.nudges.isEmpty {
                            Text("No one is overdue.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        }
                        ForEach(self.store.nudges) { n in
                            self.row(name: n.name, detail: Self.shortReason(n), badge: n.circle.map { "\($0)" })
                        }
                    }
                    self.column(title: "RECENTLY IN TOUCH") {
                        ForEach(self.store.recent) { r in
                            self.row(name: r.name, detail: Self.ago(r.daysSince), badge: nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(.white)
        .onAppear { if !self.staticLayout { self.store.refresh() } }
    }

    private func column<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(.white.opacity(0.4))
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(name: String, detail: String, badge: String?) -> some View {
        Button { if !self.staticLayout { self.store.openMyOS() } } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open myOS")
    }

    static func ago(_ days: Int) -> String {
        switch days {
        case ...0: return "today"
        case 1: return "yesterday"
        case 2..<60: return "\(days) days ago"
        default: return "\(days / 30) months ago"
        }
    }

    /// "28 days · every 14" from the longer reason myOS writes.
    static func shortReason(_ n: PersonNudge) -> String {
        let cadence = n.reason.components(separatedBy: "aim for every ").last?.split(separator: " ").first.map(String.init)
        return "\(ago(n.daysSince))" + (cadence.map { " · aim for every \($0) days" } ?? "")
    }
}
