import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Invented pictures, a video, a PDF and other files for the notch's Messages previews and tests. Nothing here is anyone's real file.
nonisolated enum MessagesSampleFiles {
    static func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lavoix-files-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A made-up scene: a sky, a sun, two hills and a red square in the top-left corner (so a picture turned the wrong way is easy to see).
    static func scene(width: Int, height: Int, warm: Bool) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        let top = warm ? CGColor(red: 0.98, green: 0.62, blue: 0.35, alpha: 1) : CGColor(red: 0.25, green: 0.5, blue: 0.9, alpha: 1)
        let bottom = warm ? CGColor(red: 0.98, green: 0.85, blue: 0.6, alpha: 1) : CGColor(red: 0.7, green: 0.85, blue: 0.98, alpha: 1)
        let gradient = CGGradient(colorsSpace: space, colors: [bottom, top] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h), options: [])
        context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.7, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.55, width: min(w, h) * 0.22, height: min(w, h) * 0.22))
        context.setFillColor(CGColor(red: 0.18, green: 0.45, blue: 0.3, alpha: 1))
        context.fillEllipse(in: CGRect(x: -w * 0.2, y: -h * 0.55, width: w * 0.9, height: h * 0.9))
        context.setFillColor(CGColor(red: 0.12, green: 0.32, blue: 0.22, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.35, y: -h * 0.65, width: w * 0.9, height: h * 0.9))
        context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: h - min(w, h) * 0.12, width: min(w, h) * 0.12, height: min(w, h) * 0.12))
        return context.makeImage()!
    }

    /// Writes a picture in the given format (`UTType.png`, `.jpeg`, `.heic`), with an optional EXIF orientation (6 = turned a quarter, as phones store portraits).
    @discardableResult
    static func writeImage(_ image: CGImage, to url: URL, type: UTType, orientation: Int? = nil) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var properties: [CFString: Any] = [:]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    @discardableResult
    static func writePDF(to url: URL, pages: Int = 2) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 56, y: 680, width: 500, height: 56))
            context.setFillColor(CGColor(gray: 0.75, alpha: 1))
            for line in 0..<18 { context.fill(CGRect(x: 56, y: 620 - CGFloat(line) * 30, width: line % 3 == 2 ? 300 : 500, height: 10)) }
            if page == 1 { context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)); context.fill(CGRect(x: 56, y: 60, width: 200, height: 200)) }
            context.endPDFPage()
        }
        context.closePDF()
        return true
    }

    /// A one-second moving-colour clip (H.264), 320 by 180.
    static func writeVideo(to url: URL) async -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
        ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let frames = 24
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return false }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let rows = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
                let blue = UInt8(40 + frame * 7), green = UInt8(160 - frame * 4)
                for y in 0..<rows {
                    let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<320 { row[x * 4] = blue; row[x * 4 + 1] = green; row[x * 4 + 2] = UInt8(60 + (x * 150) / 320); row[x * 4 + 3] = 255 }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24)) else { return false }
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }

    /// A small thread of invented files in the sample store's first chat, for the preview stills. Returns the id of the landscape photo (for the
    /// enlarged view). The video is read up front here because a still preview can't wait for it.
    @MainActor
    static func fill(_ store: MessagesStore, chips: Bool) -> Int64 {
        let dir = self.makeDirectory()
        let landscape = dir.appendingPathComponent("beach.png")
        let portrait = dir.appendingPathComponent("tall.png")
        let pdf = dir.appendingPathComponent("Lease agreement 2026.pdf")
        let video = dir.appendingPathComponent("clip.mp4")
        self.writeImage(self.scene(width: 1200, height: 800, warm: true), to: landscape, type: .png)
        self.writeImage(self.scene(width: 600, height: 900, warm: false), to: portrait, type: .png)
        self.writePDF(to: pdf)
        let done = DispatchSemaphore(value: 0)
        Task.detached { _ = await self.writeVideo(to: video); done.signal() }
        done.wait()
        func file(_ id: Int64, _ url: URL, _ kind: MessageAttachment.Kind) -> MessageAttachment {
            MessageAttachment(id: id, path: url.path, name: url.lastPathComponent, kind: kind)
        }
        let beach = file(900, landscape, .image), tall = file(901, portrait, .image)
        let clip = file(902, video, .video), lease = file(903, pdf, .pdf)
        let voice = file(904, dir.appendingPathComponent("Audio Message.caf"), .audio)
        let archive = file(905, dir.appendingPathComponent("Project files.zip"), .file)
        let missing = file(906, dir.appendingPathComponent("not-here.heic"), .image)
        // Prepare the video's picture for the still (the tile asks the cache).
        let ready = DispatchSemaphore(value: 0)
        Task.detached { _ = await MessageAttachmentImages.image(for: clip, maxPixel: MessageAttachmentImages.tilePixels); ready.signal() }
        ready.wait()
        let now = Date()
        func message(_ id: Int64, _ text: String, mine: Bool, _ files: [MessageAttachment] = []) -> ThreadMessage {
            let wordless = text.isEmpty && !files.isEmpty
            return ThreadMessage(id: id, text: wordless ? "Attachment" : text, date: now.addingTimeInterval(-Double(1000 - id)), isFromMe: mine,
                                 senderHandle: "", attachments: files, textIsPlaceholder: wordless)
        }
        let thread: [ThreadMessage] = chips
            ? [message(910, "", mine: false, [voice]), message(911, "", mine: false, [archive]), message(912, "", mine: true, [lease]), message(913, "", mine: false, [missing])]
            : [message(910, "look at this", mine: false), message(911, "", mine: false, [beach, tall]), message(912, "", mine: true, [clip, lease, tall])]
        let list = store.conversations.map { conversation -> MessageConversation in
            conversation.id == 1 ? conversation.withLastText(MessageAttachment.summary(chips ? [missing] : [clip, lease, tall])) : conversation
        }
        store.apply(conversations: list, threads: [1: thread], incoming: [], announce: false)
        store.select(1)
        return beach.id
    }
}
