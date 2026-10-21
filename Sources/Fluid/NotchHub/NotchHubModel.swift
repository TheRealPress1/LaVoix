import Combine
import SwiftUI

/// State shared by the notch window and its SwiftUI content.
@MainActor
final class NotchHubModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var selectedWidgetID: String
    /// The row of tab icons is folded away until the title's arrow is clicked.
    @Published var tabsExpanded = false
    @Published private(set) var closedSize: CGSize = .init(width: 190, height: 32)

    @Published private(set) var widgets: [NotchWidget]
    @Published private(set) var badges: [String: Int] = [:]

    init(widgets: [NotchWidget]? = nil) {
        let resolved = widgets ?? NotchWidgetRegistry.all()
        self.widgets = resolved
        self.selectedWidgetID = resolved.first?.id ?? ""
    }

    var selectedWidget: NotchWidget? {
        self.widgets.first { $0.id == self.selectedWidgetID } ?? self.widgets.first
    }

    @Published private(set) var banner: NotchBannerContent?
    @Published private(set) var bannerExpanded = false

    func showBanner(_ content: NotchBannerContent) {
        self.bannerExpanded = false
        self.banner = content
    }

    func setBannerExpanded(_ expanded: Bool) {
        guard self.banner != nil, self.bannerExpanded != expanded else { return }
        self.bannerExpanded = expanded
    }

    func hideBanner() {
        self.banner = nil
        self.bannerExpanded = false
    }

    /// Replaces the widgets outright. For self-tests that need a specific widget (e.g. Messages with sample data).
    func debugSetWidgets(_ widgets: [NotchWidget]) {
        self.widgets = widgets
        self.selectedWidgetID = widgets.first?.id ?? ""
    }

    func reloadWidgets() {
        self.widgets = NotchWidgetRegistry.all()
        if !self.widgets.contains(where: { $0.id == self.selectedWidgetID }) {
            self.selectedWidgetID = self.widgets.first?.id ?? ""
        }
    }

    func setBadge(_ id: String, _ count: Int) {
        guard self.badges[id] != count else { return }
        self.badges[id] = count
    }

    func setClosedSize(_ size: CGSize) {
        guard size != self.closedSize else { return }
        self.closedSize = size
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
    }

    /// The tab icons stay unfolded when the notch closes or a tab is picked: only the arrow in the header folds them.
    func close() {
        guard self.isOpen else { return }
        self.isOpen = false
    }
}
