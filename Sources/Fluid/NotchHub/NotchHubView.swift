import SwiftUI

/// The notch itself: a black shape that matches the hardware notch when closed and grows into a panel of widgets.
struct NotchHubView: View {
    @ObservedObject var model: NotchHubModel
    /// Forces the open layout. Used when rendering previews.
    var forceOpen = false

    /// Set by the image preview tool, which can't draw text fields.
    nonisolated(unsafe) static var previewStatic = false

    private var isOpen: Bool { self.forceOpen || self.model.isOpen }

    /// The tab on screen plus the one used just before it, so flipping back and forth is instant. Every other tab is
    /// unmounted: hidden tabs kept running their timers and data sources, which could stall the whole notch. (They are
    /// still pre-built once, off screen, by `NotchHubController.prewarmWidgets`, so a first visit is quick.)
    @State private var mounted: Set<String> = []

    var body: some View {
        let open = self.isOpen
        let banner = open ? nil : self.model.banner
        let baseSize: CGSize = open
            ? (self.model.tabsExpanded ? NotchGeometry.openSize : NotchGeometry.openSizeCollapsed)
            : (banner != nil
                ? NotchGeometry.bannerSize(content: banner, expanded: self.model.bannerExpanded, notchHeight: self.model.closedSize.height)
                : self.model.closedSize)
        let size = open ? CGSize(width: baseSize.width, height: baseSize.height + self.model.extraHeight) : baseSize
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
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: self.model.tabsExpanded)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: self.model.extraHeight)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: self.model.banner?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: self.model.bannerExpanded)
    }

    private var openContent: some View {
        let selectedID = self.model.selectedWidget?.id
        return VStack(spacing: 0) {
            self.header
                .frame(height: max(self.model.closedSize.height, 28))
            // Widgets stay mounted once shown (and the rest are warmed up just after opening), so switching tabs is a
            // quick crossfade instead of rebuilding a view and restarting its data source every time.
            // The area is always exactly the room left over (a clear box that content is drawn over), so a tab that wants more height than
            // that is clipped instead of pushing the tab row down into the notch's bottom edge.
            Color.clear.overlay(alignment: .top) { ZStack(alignment: .top) {
                ForEach(self.model.widgets) { widget in
                    if self.mounted.contains(widget.id) || widget.id == selectedID {
                        let active = widget.id == selectedID
                        widget.content()
                            .padding(.horizontal, 34)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .environment(\.notchWidgetActive, active)
                    }
                }
            } }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .animation(.easeInOut(duration: 0.16), value: selectedID)
            // The tab icons unfold along the bottom edge when the title's arrow is clicked. ImageRenderer can't draw a
            // ScrollView, so previews get the plain row.
            if self.model.tabsExpanded {
                Group {
                    if self.forceOpen || Self.previewStatic {
                        self.tabButtons.padding(.horizontal, 34).frame(maxWidth: .infinity, alignment: .leading).frame(height: NotchGeometry.tabRowHeight)
                    } else {
                        self.tabRow
                    }
                }
                .padding(.bottom, NotchGeometry.tabRowBottomInset)
                .transition(.opacity)
            }
        }
        .onAppear { self.mounted = selectedID.map { [$0] } ?? [] }
        .onChange(of: selectedID) { old, new in
            self.mounted = Set([old, new].compactMap { $0 })
        }
        .onDisappear { self.mounted = [] }
    }

    /// The band behind the camera carries the current tab's name on the left, with an arrow that unfolds the tab icons along
    /// the bottom edge, so they are never covered however many there are.
    private var header: some View {
        HStack(spacing: 0) {
            Button {
                self.model.tabsExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(self.model.selectedWidget?.title ?? "")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(self.model.tabsExpanded ? 180 : 0))
                }
                .foregroundStyle(.white.opacity(self.model.tabsExpanded ? 0.8 : 0.5))
                .frame(maxWidth: (NotchGeometry.openSize.width - self.model.closedSize.width) / 2 - 46, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(self.model.tabsExpanded ? "Hide the tabs" : "Show the tabs")
            Spacer(minLength: 0)
        }
        .padding(.leading, 38)
        .padding(.trailing, 38)
    }

    private var tabRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                self.tabButtons
            }
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 10)
                }
            )
            .onChange(of: self.model.selectedWidgetID) { _, id in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .padding(.horizontal, 34)
        .frame(height: NotchGeometry.tabRowHeight)
    }

    private var tabButtons: some View {
        HStack(spacing: 4) {
            ForEach(self.model.widgets) { widget in
                let selected = widget.id == self.model.selectedWidget?.id
                Button {
                    NotchHubController.shared.verifyTabSwitch(to: widget.id)
                    self.model.selectedWidgetID = widget.id
                } label: {
                    Group {
                        if let image = widget.brandImage {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 17, height: 17).opacity(selected ? 1 : 0.6)
                        } else {
                            Image(systemName: widget.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.45))
                        }
                    }
                        .frame(width: 30, height: 24)
                        .background(Capsule().fill(selected ? Color.white.opacity(0.14) : .clear))
                        .overlay(alignment: .topTrailing) {
                            if let count = self.model.badges[widget.id], count > 0 {
                                // Inside the icon's own frame: the tab row is a scroll view that clips at its edges, so a dot hung outside the corner was cut off.
                                Circle().fill(Color.blue).frame(width: 7, height: 7).offset(x: -2, y: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(widget.title)
                .id(widget.id)
            }
        }
    }
}
