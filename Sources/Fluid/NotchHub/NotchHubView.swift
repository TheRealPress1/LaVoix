import SwiftUI

/// The notch itself: a black shape that matches the hardware notch when closed and grows into a panel of widgets.
struct NotchHubView: View {
    @ObservedObject var model: NotchHubModel
    /// Forces the open layout. Used when rendering previews.
    var forceOpen = false

    /// Set by the image preview tool, which can't draw text fields.
    nonisolated(unsafe) static var previewStatic = false

    private var isOpen: Bool { self.forceOpen || self.model.isOpen }

    var body: some View {
        let open = self.isOpen
        let banner = open ? nil : self.model.banner
        let size: CGSize = open
            ? NotchGeometry.openSize
            : (banner != nil
                ? NotchGeometry.bannerSize(expanded: self.model.bannerExpanded, notchHeight: self.model.closedSize.height)
                : self.model.closedSize)
        let raised = open || banner != nil
        ZStack(alignment: .top) {
            NotchHubShape(topCornerRadius: open ? 19 : (banner != nil ? 10 : 6), bottomCornerRadius: open ? 26 : (banner != nil ? 30 : 14))
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(raised ? 0.55 : 0), radius: 16, y: 8)
                .overlay(alignment: .top) {
                    if open {
                        self.openContent
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                    } else if let banner {
                        NotchBannerView(content: banner, expanded: self.model.bannerExpanded, staticLayout: self.forceOpen || Self.previewStatic)
                            .padding(.top, self.model.closedSize.height)
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .transition(.opacity)
                            .id(banner.id)
                    }
                }
        }
        .frame(width: NotchGeometry.windowSize.width, height: NotchGeometry.windowSize.height, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: open)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: self.model.banner?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: self.model.bannerExpanded)
    }

    private var openContent: some View {
        VStack(spacing: 0) {
            self.header
                .frame(height: max(self.model.closedSize.height, 28))
            if let widget = self.model.selectedWidget {
                widget.content()
                    .id(widget.id)
                    .padding(.horizontal, 34)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    /// Tabs sit left of the physical notch; the area behind it stays empty.
    private var header: some View {
        HStack(spacing: 6) {
            ForEach(self.model.widgets) { widget in
                let selected = widget.id == self.model.selectedWidget?.id
                Button {
                    self.model.selectedWidgetID = widget.id
                } label: {
                    Image(systemName: widget.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                        .frame(width: 30, height: 22)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.14) : .clear))
                        .overlay(alignment: .topTrailing) {
                            if let count = self.model.badges[widget.id], count > 0 {
                                Circle().fill(Color.blue).frame(width: 8, height: 8).offset(x: 1, y: -1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(widget.title)
            }
            Spacer()
        }
        .padding(.leading, 38)
        .padding(.trailing, 38)
    }
}
