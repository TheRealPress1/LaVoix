import CoreText
import SwiftUI

/// Bundled display fonts. Instrument Serif is licensed under the SIL OFL (see Resources/InstrumentSerif-OFL.txt).
enum LaVoixFonts {
    private static let registration: Void = {
        guard let url = Bundle.main.url(forResource: "InstrumentSerif-Italic", withExtension: "ttf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func instrumentSerifItalic(size: CGFloat) -> Font {
        _ = self.registration
        return .custom("InstrumentSerif-Italic", size: size)
    }
}
