import CoreText
import SwiftUI

/// Bundled display fonts. Sorts Mill Goudy is licensed under the SIL OFL (see Resources/SortsMillGoudy-OFL.txt).
enum LaVoixFonts {
    /// Registers every bundled font once: Sorts Mill Goudy (tagline), Inter (text) and JetBrains Mono (labels and code),
    /// the last two being myOS's own typefaces, both SIL OFL (see Inter-OFL.txt, JetBrainsMono-OFL.txt in Resources).
    private static let registration: Void = {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []).filter {
            let name = $0.lastPathComponent
            return name.hasPrefix("SortsMillGoudy") || name.hasPrefix("Inter-") || name.hasPrefix("JetBrainsMono-")
        }
        for url in urls { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
    }()

    /// Call before any font is looked up by name. Cheap and idempotent.
    static func registerAll() { _ = self.registration }

    static func tagline(size: CGFloat) -> Font {
        _ = self.registration
        return .custom("SortsMillGoudy-Regular", size: size)
    }
}
