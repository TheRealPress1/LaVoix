import SwiftUI

/// What a quick link points at, so its chip can wear the right logo: LinkedIn's mark for a LinkedIn link, Spotify's for a Spotify
/// link, and so on. Anything else gets a generic link, mail or phone symbol, or a note for plain text.
enum QuickLinkKind: Equatable {
    case linkedin, spotify, appleMusic, youtube, soundcloud, github, calcom, x, instagram, tiktok, facebook, netflix, twitch, vimeo
    case email, phone, web, text

    nonisolated static func of(_ value: String) -> QuickLinkKind {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), var host = url.host?.lowercased() {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
            if on("linkedin.com") || on("lnkd.in") { return .linkedin }
            if on("spotify.com") || on("spoti.fi") { return .spotify }
            if on("music.apple.com") { return .appleMusic }
            if on("youtube.com") || on("youtu.be") { return .youtube }
            if on("soundcloud.com") { return .soundcloud }
            if on("github.com") { return .github }
            if on("cal.com") { return .calcom }
            if on("x.com") || on("twitter.com") { return .x }
            if on("instagram.com") { return .instagram }
            if on("tiktok.com") { return .tiktok }
            if on("facebook.com") || on("fb.com") { return .facebook }
            if on("netflix.com") { return .netflix }
            if on("twitch.tv") { return .twitch }
            if on("vimeo.com") { return .vimeo }
            return .web
        }
        if text.hasPrefix("mailto:") || (text.contains("@") && !text.contains(" ") && text.split(separator: "@").count == 2 && text.contains(".")) { return .email }
        let digits = text.filter(\.isNumber).count
        if digits >= 7, text.filter(\.isLetter).isEmpty { return .phone }
        return .text
    }
}

/// The chip's small logo. The marks are drawn here (simple versions of each brand's mark), so nothing is downloaded and no address
/// ever leaves the Mac to find an icon.
struct QuickLinkIcon: View {
    let kind: QuickLinkKind
    var size: CGFloat = 18

    var body: some View {
        Group {
            switch self.kind {
            case .linkedin:
                self.tile(Color(red: 0.04, green: 0.4, blue: 0.76)) { Text("in").font(.system(size: self.size * 0.6, weight: .heavy)).foregroundStyle(.white) }
            case .spotify:
                ZStack {
                    Circle().fill(Color(red: 0.12, green: 0.73, blue: 0.33))
                    SpotifyWaves().stroke(Color.black, style: StrokeStyle(lineWidth: self.size * 0.09, lineCap: .round)).padding(self.size * 0.2)
                }
            case .appleMusic:
                self.tile(LinearGradient(colors: [Color(red: 0.98, green: 0.34, blue: 0.45), Color(red: 0.98, green: 0.17, blue: 0.3)], startPoint: .top, endPoint: .bottom)) {
                    Image(systemName: "music.note").font(.system(size: self.size * 0.55, weight: .bold)).foregroundStyle(.white)
                }
            case .youtube, .soundcloud, .netflix, .twitch, .vimeo:
                NowPlayingSourceLogo(source: NowPlayingSource.site(forHost: self.host) ?? NowPlayingSource(kind: .other, name: ""), bundleID: nil, size: self.size)
            case .github:
                SVGPathShape(d: BrandMarks.github).fill(Color.white)
            case .calcom:
                // The wordmark is wide, so its icon is wider than the others and the chip makes room for it.
                SVGPathShape(d: BrandMarks.calcom, box: BrandMarks.calcomBox).fill(Color.white)
                    .frame(width: self.size * 2.2, height: self.size * 2.2 * BrandMarks.calcomBox.height / BrandMarks.calcomBox.width)
            case .x:
                self.tile(Color.black) { Text("X").font(.system(size: self.size * 0.62, weight: .black)).foregroundStyle(.white) }
                    .overlay(RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8))
            case .instagram:
                self.tile(LinearGradient(colors: [Color(red: 0.99, green: 0.69, blue: 0.2), Color(red: 0.88, green: 0.2, blue: 0.4), Color(red: 0.45, green: 0.25, blue: 0.75)], startPoint: .bottomLeading, endPoint: .topTrailing)) {
                    ZStack {
                        RoundedRectangle(cornerRadius: self.size * 0.2, style: .continuous).strokeBorder(.white, lineWidth: self.size * 0.09).frame(width: self.size * 0.62, height: self.size * 0.62)
                        Circle().strokeBorder(.white, lineWidth: self.size * 0.09).frame(width: self.size * 0.3, height: self.size * 0.3)
                    }
                }
            case .tiktok:
                self.tile(Color.black) { Image(systemName: "music.note").font(.system(size: self.size * 0.55, weight: .bold)).foregroundStyle(.white) }
                    .overlay(RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8))
            case .facebook:
                self.tile(Color(red: 0.09, green: 0.47, blue: 0.95)) { Text("f").font(.system(size: self.size * 0.8, weight: .heavy)).foregroundStyle(.white).offset(y: self.size * 0.04) }
            case .email:
                Image(systemName: "envelope.fill").font(.system(size: self.size * 0.8)).foregroundStyle(.white.opacity(0.7))
            case .phone:
                Image(systemName: "phone.fill").font(.system(size: self.size * 0.75)).foregroundStyle(.white.opacity(0.7))
            case .web:
                Image(systemName: "link").font(.system(size: self.size * 0.8, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            case .text:
                Image(systemName: "text.alignleft").font(.system(size: self.size * 0.75)).foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: self.kind == .calcom ? self.size * 2.2 : self.size, height: self.size)
    }

    /// The host for kinds that reuse the Now Playing logos, which choose by address.
    private var host: String {
        switch self.kind {
        case .youtube: "youtube.com"
        case .soundcloud: "soundcloud.com"
        case .netflix: "netflix.com"
        case .twitch: "twitch.tv"
        case .vimeo: "vimeo.com"
        default: ""
        }
    }

    private func tile<S: ShapeStyle, Content: View>(_ fill: S, @ViewBuilder _ content: () -> Content) -> some View {
        RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(fill).overlay(content())
    }
}

/// Three curved bars, the mark inside Spotify's circle.
private struct SpotifyWaves: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, inset) in [0.0, 0.17, 0.32].enumerated() {
            let y = rect.minY + rect.height * (0.16 + 0.3 * Double(index))
            let left = rect.minX + rect.width * inset * 0.5
            let right = rect.maxX - rect.width * inset * 0.5
            path.move(to: CGPoint(x: left, y: y + rect.height * 0.06))
            path.addQuadCurve(to: CGPoint(x: right, y: y + rect.height * 0.1), control: CGPoint(x: rect.midX, y: y - rect.height * 0.12))
        }
        return path
    }
}
