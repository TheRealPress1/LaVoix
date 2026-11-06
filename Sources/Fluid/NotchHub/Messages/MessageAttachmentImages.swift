import AppKit
import AVFoundation
import ImageIO

/// Pictures for the files in a conversation: a small one for the tile in the thread, a larger one for the hover preview. Read-only (the file is
/// never changed, copied or sent anywhere), made off the main thread, and kept in a small cache so scrolling back is instant.
nonisolated enum MessageAttachmentImages {
    /// A tile in the thread is 64 points: this is that on a retina screen, with room to crop.
    static let tilePixels = 192
    /// The enlarged view fills the thread's width on a retina screen.
    static let enlargedPixels = 900

    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// The picture for this file at most `maxPixel` wide or tall, or nil when it can't be made (a missing file, a voice message, a zip).
    static func image(for attachment: MessageAttachment, maxPixel: Int) async -> NSImage? {
        if let cached = self.cached(attachment, maxPixel: maxPixel) { return cached }
        guard attachment.kind == .video else {
            return await Task.detached(priority: .userInitiated) { self.load(attachment, maxPixel: maxPixel) }.value
        }
        guard FileManager.default.isReadableFile(atPath: attachment.path), let frame = await self.videoFrame(at: attachment.url, maxPixel: maxPixel) else { return nil }
        self.store(frame, for: attachment, maxPixel: maxPixel)
        return frame
    }

    static func cached(_ attachment: MessageAttachment, maxPixel: Int) -> NSImage? {
        self.cache.object(forKey: self.key(attachment, maxPixel))
    }

    /// The same, on the calling thread, for pictures and PDFs (the still previews cannot wait; a video is only made by `image(for:maxPixel:)`).
    static func load(_ attachment: MessageAttachment, maxPixel: Int) -> NSImage? {
        if let cached = self.cached(attachment, maxPixel: maxPixel) { return cached }
        guard FileManager.default.isReadableFile(atPath: attachment.path) else { return nil }
        let image: NSImage?
        switch attachment.kind {
        case .image: image = self.stillImage(at: attachment.url, maxPixel: maxPixel)
        case .pdf: image = self.pdfPage(at: attachment.url, maxPixel: maxPixel)
        case .video, .audio, .file: image = nil
        }
        if let image { self.store(image, for: attachment, maxPixel: maxPixel) }
        return image
    }

    /// Whether a picture is a cut-out (a Memoji, an emoji, a sticker): its four corners are see-through. Such a picture is drawn as it is, without the
    /// rounded square a photo gets, so it does not look like a photo of a sticker. A photo, even a PNG with an alpha channel, has solid corners.
    static func hasTransparentCorners(_ image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return false }
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        // The picture squeezed into 16 by 16: each corner pixel is the average of its corner of the picture.
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return false }
        func alpha(_ x: Int, _ y: Int) -> Int { Int(pixels[(y * side + x) * 4 + 3]) }
        return [alpha(0, 0), alpha(side - 1, 0), alpha(0, side - 1), alpha(side - 1, side - 1)].allSatisfy { $0 < 26 }
    }

    /// `hasTransparentCorners`, asked once per picture (the answer is kept by the file's path).
    static func isCutout(_ image: NSImage, for attachment: MessageAttachment) -> Bool {
        let key = attachment.path as NSString
        if let known = self.cutouts.object(forKey: key) { return known.boolValue }
        let answer = self.hasTransparentCorners(image)
        self.cutouts.setObject(NSNumber(value: answer), forKey: key)
        return answer
    }

    private static let cutouts: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 200
        return cache
    }()

    private static func store(_ image: NSImage, for attachment: MessageAttachment, maxPixel: Int) {
        self.cache.setObject(image, forKey: self.key(attachment, maxPixel), cost: Int(image.size.width * image.size.height * 4))
    }

    private static func key(_ attachment: MessageAttachment, _ maxPixel: Int) -> NSString {
        "\(attachment.path)|\(maxPixel)" as NSString
    }

    /// Photos and pictures of any kind Messages carries (HEIC, JPEG, PNG, GIF's first frame...), turned upright and cut down while reading, so a
    /// 12-megapixel photo is never held whole.
    private static func stillImage(at url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// A video's first moments as a still.
    private static func videoFrame(at url: URL, maxPixel: Int) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Slightly in, so a clip that starts on black shows something.
        for seconds in [0.3, 0.0] as [Double] {
            if let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) {
                return NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
            }
        }
        return nil
    }

    /// A PDF's first page, drawn with Core Graphics (which is safe off the main thread) on white, the way the page would print.
    private static func pdfPage(at url: URL, maxPixel: Int) -> NSImage? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0, let page = document.page(at: 1) else { return nil }
        var box = page.getBoxRect(.mediaBox)
        if page.rotationAngle % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(maxPixel) / max(box.width, box.height)
        let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}
