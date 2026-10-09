import CoreText
import SwiftUI

/// Bundled display fonts. Sorts Mill Goudy is licensed under the SIL OFL (see Resources/SortsMillGoudy-OFL.txt).
enum LaVoixFonts {
    private static let registration: Void = {
        guard let url = Bundle.main.url(forResource: "SortsMillGoudy-Regular", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func tagline(size: CGFloat) -> Font {
        _ = self.registration
        return .custom("SortsMillGoudy-Regular", size: size)
    }
}
