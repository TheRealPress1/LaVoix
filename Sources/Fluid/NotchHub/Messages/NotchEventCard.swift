import AppKit
import SwiftUI

/// The card Look shows for "add this to my calendar": the event drawn as a small calendar tile (the month over the day) with its title, weekday and time, the
/// place, which calendar it would go to, and one Approve button. Nothing is made until Approve is pressed: it only tells myOS which calendar was chosen on the card
/// (the action id is `<prefix><account number>`), and myOS makes the event. The calendar chip cycles through the accounts that allow it.
struct NotchEventProposalCard: View {
    let proposal: NotchBannerContent.EventProposal
    let width: CGFloat
    /// Pressed Approve: the action id for the calendar shown on the chip.
    var onApprove: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}
    @State private var selected: Int

    static let sidePadding: CGFloat = 26
    static let tileSide: CGFloat = 46
    static let rowHeight: CGFloat = 56
    private static let accountHeight: CGFloat = 24
    private static let buttonHeight: CGFloat = 32

    init(proposal: NotchBannerContent.EventProposal, width: CGFloat, onApprove: @escaping (String) -> Void = { _ in }, onDismiss: @escaping () -> Void = {}) {
        self.proposal = proposal
        self.width = width
        self.onApprove = onApprove
        self.onDismiss = onDismiss
        _selected = State(initialValue: proposal.accounts.indices.contains(proposal.selected) ? proposal.selected : 0)
    }

    /// Everything the card needs under the notch band: the tile and its words, the calendar chip when there are accounts, the buttons, and room at the bottom.
    static func contentHeight(_ proposal: NotchBannerContent.EventProposal) -> CGFloat {
        8 + self.rowHeight + (proposal.accounts.isEmpty ? 0 : 10 + self.accountHeight) + 12 + self.buttonHeight + 18
    }

    /// The action id Approve presses for the calendar at `index`.
    static func actionID(_ proposal: NotchBannerContent.EventProposal, account index: Int) -> String {
        proposal.actionPrefix + String(proposal.accounts.indices.contains(index) ? index : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                self.tile
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.proposal.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(self.proposal.weekday) · \(self.proposal.time)")
                        .font(.system(size: 13.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    if let place = self.proposal.place, !place.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.and.ellipse").font(.system(size: 10))
                            Text(place).lineLimit(1)
                        }
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(height: Self.rowHeight)
            if !self.proposal.accounts.isEmpty {
                HStack { self.accountChip; Spacer(minLength: 0) }.padding(.top, 10)
            }
            HStack(spacing: 8) {
                Button(action: self.onDismiss) {
                    Text("Not now").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: Self.buttonHeight)
                        .background(Capsule().fill(Color.white.opacity(0.14))).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                Button { self.onApprove(Self.actionID(self.proposal, account: self.selected)) } label: {
                    Text("Approve").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: Self.buttonHeight)
                        .background(Capsule().fill(Color.white)).foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.sidePadding)
        .padding(.top, 8)
        .frame(width: self.width, alignment: .leading)
    }

    /// The month in red over the day, on white: a calendar page.
    private var tile: some View {
        VStack(spacing: 0) {
            Text(self.proposal.month)
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(maxWidth: .infinity).frame(height: 15)
                .background(Color(red: 1, green: 0.27, blue: 0.23))
            Text(self.proposal.day)
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.tileSide, height: Self.tileSide)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Which calendar it goes to; pressing it moves on to the next account when there is more than one.
    private var accountChip: some View {
        let accounts = self.proposal.accounts
        let index = accounts.indices.contains(self.selected) ? self.selected : 0
        return Button {
            if accounts.count > 1 { self.selected = (index + 1) % accounts.count }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                Text(accounts[index]).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if accounts.count > 1 { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)) }
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding(.horizontal, 10)
            .frame(height: Self.accountHeight)
            .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(accounts.count > 1 ? "Click to choose another calendar" : "The calendar it goes to")
        .accessibilityLabel("Calendar: \(accounts[index])" + (accounts.count > 1 ? ". Press to choose another." : ""))
    }
}

extension NotchBannerContent {
    /// An event Look proposes, as the card draws it. Built from the `event` object of a `notch.alert` (see EngineSocket): myOS says the words (the weekday, the
    /// time as it should read, the place) and which calendars it could go to.
    struct EventProposal: Equatable {
        var title: String
        var weekday: String
        var month: String
        var day: String
        var time: String
        var place: String?
        /// The accounts whose calendar can take it, in the order the chip cycles.
        var accounts: [String]
        var selected: Int
        /// The press is `actionPrefix` + the number of the account chosen.
        var actionPrefix: String

        /// nil unless the object has what the card needs; everything is cut to a size the card can hold.
        static func parse(_ value: Any?) -> EventProposal? {
            guard let object = value as? [String: Any],
                  let title = (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
                  let month = object["month"] as? String, !month.isEmpty,
                  let day = object["day"] as? String, !day.isEmpty,
                  let time = object["time"] as? String,
                  let prefix = object["action_prefix"] as? String, !prefix.isEmpty
            else { return nil }
            let accounts = ((object["accounts"] as? [String]) ?? []).filter { $0.contains("@") }.prefix(8).map { String($0.prefix(80)) }
            let place = (object["place"] as? String).map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)) }.flatMap { $0.isEmpty ? nil : $0 }
            return EventProposal(
                title: String(title.prefix(120)), weekday: String(((object["weekday"] as? String) ?? "").prefix(12)),
                month: String(month.prefix(4)), day: String(day.prefix(2)), time: String(time.prefix(60)),
                place: place, accounts: Array(accounts), selected: (object["selected"] as? NSNumber)?.intValue ?? 0, actionPrefix: String(prefix.prefix(150))
            )
        }
    }
}
