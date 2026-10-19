import AppKit
import Foundation

/// Helpers for artwork that isn't really artwork, and for fetching YouTube's own thumbnail and view count.
enum NowPlayingArtwork {
    /// Fingerprint of Chromium's default app icon, which Chromium browsers (Dia, Chrome, Arc) hand over as "artwork" when a
    /// page has none. Measured from the real image.
    private static let genericFingerprints: [UInt64] = [0xf7e1_fde4_e0f1_81c3]

    /// A 64-bit fingerprint: the image shrunk to 8x8 grey, each pixel marked brighter or darker than the average.
    static func fingerprint(_ image: NSImage) -> UInt64? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        let mean = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var bits: UInt64 = 0
        for (index, pixel) in pixels.enumerated() where Int(pixel) >= mean { bits |= 1 << UInt64(index) }
        return bits
    }

    /// True for the browser's own placeholder icon (allowing for a few bits of difference from scaling).
    static func isGeneric(_ image: NSImage) -> Bool {
        guard let print = self.fingerprint(image) else { return false }
        return self.genericFingerprints.contains { ($0 ^ print).nonzeroBitCount <= 8 }
    }

    private static let softCache: NSCache<NSImage, NSImage> = { let c = NSCache<NSImage, NSImage>(); c.countLimit = 8; return c }()

    /// A tiny copy of the artwork for the card's backdrop. Drawn large and smooth it looks blurred, and unlike a live blur it costs
    /// nothing to redraw (a 28-point blur of a full-size cover on every update is what made the notch stall).
    static func soft(_ image: NSImage) -> NSImage {
        if let cached = self.softCache.object(forKey: image) { return cached }
        let side: CGFloat = 32
        let small = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
            return true
        }
        self.softCache.setObject(small, forKey: image)
        return small
    }

    // MARK: - YouTube

    struct YouTubeInfo: Equatable {
        var viewCount: Int64?
        var thumbnail: NSImage?
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.viewCount == rhs.viewCount && (lhs.thumbnail == nil) == (rhs.thumbnail == nil) }
    }

    /// The video ID from a watch, shorts, embed or youtu.be address.
    static func youTubeVideoID(host: String, path: String, query: String) -> String? {
        let host = host.lowercased()
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        func valid(_ id: String) -> String? {
            id.count == 11 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } ? id : nil
        }
        if host == "youtu.be" { return valid(String(path.dropFirst().prefix(11))) }
        guard isYouTube else { return nil }
        if path == "/watch" {
            let value = query.split(separator: "&").first { $0.hasPrefix("v=") }.map { String($0.dropFirst(2)) }
            return value.flatMap(valid)
        }
        for prefix in ["/shorts/", "/embed/", "/live/"] where path.hasPrefix(prefix) {
            return valid(String(path.dropFirst(prefix.count).prefix(11)))
        }
        return nil
    }

    /// YouTube's public thumbnail for a video, and its view count read from the video page. Contacts youtube.com and
    /// i.ytimg.com, only for videos the user is actually watching and only when lookups are turned on.
    static func fetchYouTube(videoID: String) async -> YouTubeInfo {
        async let thumbnail = self.fetchThumbnail(videoID: videoID)
        async let views = self.fetchViewCount(videoID: videoID)
        return await YouTubeInfo(viewCount: views, thumbnail: thumbnail)
    }

    static func fetchThumbnail(videoID: String) async -> NSImage? {
        // Widescreen first (HD videos), then the always-present 16:9 medium size.
        for name in ["maxresdefault", "mqdefault"] {
            guard let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg"),
                  let (data, response) = try? await self.session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data), image.size.width > 200 else { continue }
            return image
        }
        return nil
    }

    private static func fetchViewCount(videoID: String) async -> Int64? {
        guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await self.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data.prefix(2_000_000), encoding: .utf8) else { return nil }
        return self.viewCount(inPage: html)
    }

    /// The view count YouTube embeds in the page's player data (`"viewCount":"1234567"`).
    static func viewCount(inPage html: String) -> Int64? {
        guard let range = html.range(of: "\"viewCount\":\"") else { return nil }
        let digits = html[range.upperBound...].prefix { $0.isNumber }
        return Int64(digits)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// "1.2M views", "48K views", "312 views".
    static func viewsText(_ count: Int64) -> String {
        func compact(_ value: Double, _ suffix: String) -> String {
            let text = value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + suffix
        }
        switch count {
        case 1_000_000_000...: return compact(Double(count) / 1_000_000_000, "B views")
        case 1_000_000...: return compact(Double(count) / 1_000_000, "M views")
        case 1000...: return compact(Double(count) / 1000, "K views")
        case 1: return "1 view"
        default: return "\(count) views"
        }
    }
}
