import AppKit

/// Where the notch is and how big it is, measured from the screen rather than hard-coded.
enum NotchGeometry {
    static let openSize = CGSize(width: 660, height: 214)
    /// Extra transparent room around the open notch for the drop shadow.
    static let shadowPadding: CGFloat = 24

    /// The built-in display with a notch if there is one, otherwise the main display.
    @MainActor static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Size of the closed notch. On Macs without a notch this is a slim pill at the top of the screen.
    @MainActor static func closedSize(for screen: NSScreen) -> CGSize {
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width
        {
            return CGSize(width: screen.frame.width - left - right + 4, height: screen.safeAreaInsets.top)
        }
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return CGSize(width: 190, height: menuBar)
    }

    /// Notification card size. The top band sits behind the hardware notch, so content starts below it.
    static func bannerSize(expanded: Bool, notchHeight: CGFloat) -> CGSize {
        CGSize(width: 420, height: notchHeight + (expanded ? 118 : 70))
    }

    @MainActor static func bannerRect(for screen: NSScreen, expanded: Bool) -> NSRect {
        let size = self.bannerSize(expanded: expanded, notchHeight: self.closedSize(for: screen).height)
        return NSRect(x: screen.frame.midX - size.width / 2 - 8, y: screen.frame.maxY - size.height - 8, width: size.width + 16, height: size.height + 8)
    }

    static let meetingCardPadding: CGFloat = 16

    /// Live-meeting card size; like the notification card, its top band sits behind the hardware notch.
    static func meetingCardSize(notchHeight: CGFloat) -> CGSize {
        CGSize(width: 400, height: notchHeight + 66)
    }

    @MainActor static func meetingCardFrame(for screen: NSScreen) -> NSRect {
        let size = self.meetingCardSize(notchHeight: self.closedSize(for: screen).height)
        let width = size.width + self.meetingCardPadding * 2
        let height = size.height + self.meetingCardPadding
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    static var windowSize: CGSize {
        CGSize(width: self.openSize.width + self.shadowPadding * 2, height: self.openSize.height + self.shadowPadding)
    }

    /// Window frame in screen coordinates: centred horizontally, flush with the top edge.
    @MainActor static func windowFrame(for screen: NSScreen) -> NSRect {
        let size = self.windowSize
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Region of the screen that opens the notch when the pointer enters it.
    @MainActor static func triggerRect(for screen: NSScreen) -> NSRect {
        let closed = self.closedSize(for: screen)
        return NSRect(
            x: screen.frame.midX - closed.width / 2 - 6,
            y: screen.frame.maxY - closed.height - 2,
            width: closed.width + 12,
            height: closed.height + 6
        )
    }

    /// Region that keeps the notch open while the pointer is inside it.
    @MainActor static func openRect(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - self.openSize.width / 2 - 10,
            y: screen.frame.maxY - self.openSize.height - 10,
            width: self.openSize.width + 20,
            height: self.openSize.height + 10
        )
    }
}
