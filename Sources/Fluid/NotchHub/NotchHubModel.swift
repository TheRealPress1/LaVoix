import Combine
import SwiftUI

/// State shared by the notch window and its SwiftUI content.
@MainActor
final class NotchHubModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var selectedWidgetID: String
    @Published private(set) var closedSize: CGSize = .init(width: 190, height: 32)

    let widgets: [NotchWidget]

    init(widgets: [NotchWidget]? = nil) {
        let resolved = widgets ?? NotchWidgetRegistry.all()
        self.widgets = resolved
        self.selectedWidgetID = resolved.first?.id ?? ""
    }

    var selectedWidget: NotchWidget? {
        self.widgets.first { $0.id == self.selectedWidgetID } ?? self.widgets.first
    }

    func setClosedSize(_ size: CGSize) {
        guard size != self.closedSize else { return }
        self.closedSize = size
    }

    func open() {
        guard !self.isOpen else { return }
        self.isOpen = true
    }

    func close() {
        guard self.isOpen else { return }
        self.isOpen = false
    }
}
