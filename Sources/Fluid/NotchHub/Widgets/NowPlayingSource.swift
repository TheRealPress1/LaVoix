import AppKit
import SwiftUI

/// Where a track is coming from: a music app, or a website playing in a browser.
struct NowPlayingSource: Equatable, Codable {
    enum Kind: String, Codable {
        case youtube, youtubeMusic, spotify, appleMusic, soundcloud, netflix, twitch, vimeo, other
    }

    var kind: Kind
    var name: String

    static let browserBundleIDs: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "company.thebrowser.dia",
        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        bundleID.map { self.browserBundleIDs.contains($0) || $0.hasPrefix("com.google.Chrome.app.") } ?? false
    }

    /// The source for a native app (Spotify, Music, ...); other apps just use their own name.
    static func native(bundleID: String?, appName: String?) -> NowPlayingSource {
        switch bundleID {
        case "com.spotify.client": return NowPlayingSource(kind: .spotify, name: "Spotify")
        case "com.apple.Music": return NowPlayingSource(kind: .appleMusic, name: "Apple Music")
        default: return NowPlayingSource(kind: .other, name: appName ?? "Unknown")
        }
    }

    /// The website a browser tab is on, from its host name.
    static func site(forHost host: String) -> NowPlayingSource? {
        let host = host.lowercased()
        func matches(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if host == "music.youtube.com" { return NowPlayingSource(kind: .youtubeMusic, name: "YouTube Music") }
        if matches("youtube.com") || matches("youtu.be") { return NowPlayingSource(kind: .youtube, name: "YouTube") }
        if matches("spotify.com") { return NowPlayingSource(kind: .spotify, name: "Spotify") }
        if matches("soundcloud.com") { return NowPlayingSource(kind: .soundcloud, name: "SoundCloud") }
        if matches("netflix.com") { return NowPlayingSource(kind: .netflix, name: "Netflix") }
        if matches("twitch.tv") { return NowPlayingSource(kind: .twitch, name: "Twitch") }
        if matches("vimeo.com") { return NowPlayingSource(kind: .vimeo, name: "Vimeo") }
        if matches("music.apple.com") { return NowPlayingSource(kind: .appleMusic, name: "Apple Music") }
        return nil
    }
}

/// A small logo for a source: the real app icon for native apps, a drawn mark for well-known websites.
struct NowPlayingSourceLogo: View {
    let source: NowPlayingSource?
    let bundleID: String?
    var size: CGFloat = 16

    var body: some View {
        Group {
            switch self.source?.kind {
            case .youtube:
                RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(Color(red: 1, green: 0, blue: 0))
                    .overlay(Triangle().fill(.white).frame(width: self.size * 0.34, height: self.size * 0.38).offset(x: self.size * 0.03))
            case .youtubeMusic:
                Circle().fill(Color(red: 1, green: 0, blue: 0))
                    .overlay(Circle().strokeBorder(.white, lineWidth: self.size * 0.07).padding(self.size * 0.14))
                    .overlay(Triangle().fill(.white).frame(width: self.size * 0.26, height: self.size * 0.3).offset(x: self.size * 0.02))
            case .soundcloud:
                RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(Color.orange)
                    .overlay(Image(systemName: "cloud.fill").font(.system(size: self.size * 0.55)).foregroundStyle(.white))
            case .netflix:
                RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(Color(red: 0.12, green: 0.12, blue: 0.12))
                    .overlay(Text("N").font(.system(size: self.size * 0.7, weight: .heavy)).foregroundStyle(Color(red: 0.9, green: 0.04, blue: 0.08)))
            case .twitch:
                RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(Color(red: 0.57, green: 0.27, blue: 1))
                    .overlay(Image(systemName: "bubble.left.fill").font(.system(size: self.size * 0.5)).foregroundStyle(.white))
            case .vimeo:
                RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(Color(red: 0.1, green: 0.72, blue: 0.93))
                    .overlay(Text("v").font(.system(size: self.size * 0.75, weight: .heavy, design: .rounded)).foregroundStyle(.white))
            default:
                if let icon = Self.appIcon(bundleID: self.bundleID) {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous).fill(Color.white.opacity(0.15))
                        .overlay(Image(systemName: "music.note").font(.system(size: self.size * 0.5)).foregroundStyle(.white.opacity(0.7)))
                }
            }
        }
        .frame(width: self.size, height: self.size)
        .clipShape(RoundedRectangle(cornerRadius: self.size * 0.28, style: .continuous))
    }

    private static var iconCache: [String: NSImage] = [:]

    /// The app's own icon, found from its bundle ID.
    static func appIcon(bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = self.iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        self.iconCache[bundleID] = icon
        return icon
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
