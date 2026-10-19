import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// An image the user gives Nook to look at (a dropped picture, a part of the screen). Brains that can see get the image
/// itself; every brain also gets the text in it (OCR on the Mac), so a model without vision still knows what it shows.
struct ChatImage: Equatable, Sendable {
    let data: Data
    /// `image/jpeg` or `image/png`.
    let mediaType: String

    var base64: String { data.base64EncodedString() }
    var dataURL: String { "data:\(mediaType);base64,\(base64)" }

    /// The longest side a vision model reads at full detail (Claude: 1568 px); larger images only cost time and tokens.
    static let maxSide = 1568

    static func isImage(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data).conforms(to: .image)
    }

    /// Reads and downsizes an image file (any format ImageIO knows: PNG, JPEG, HEIC, GIF, WebP, TIFF…). Nil when it is
    /// not an image. `cgImage` is the downsized picture, for reading the text in it.
    static func load(_ url: URL) -> (image: ChatImage, cgImage: CGImage)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let image = encode(cg) else { return nil }
        return (image, cg)
    }

    /// JPEG for photos and screenshots; PNG when the image has transparency, which JPEG would turn black.
    static func encode(_ cg: CGImage) -> ChatImage? {
        let alpha = cg.alphaInfo
        let transparent = !(alpha == .none || alpha == .noneSkipFirst || alpha == .noneSkipLast)
        let type = transparent ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = transparent ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ChatImage(data: out as Data, mediaType: transparent ? "image/png" : "image/jpeg")
    }

    /// The text that goes with the image for every brain: what Nook read in it, or that there is no text.
    static func describe(name: String, recognized: String) -> String {
        let text = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty
            ? "Image: \(name). No readable text was found in it."
            : "Image: \(name). Text recognized in the image (OCR, may contain small errors):\n\(text)"
    }

    // MARK: Message formats

    /// Anthropic Messages API: image blocks before the text, as Anthropic recommends.
    static func anthropicContent(_ images: [ChatImage], text: String) -> [[String: Any]] {
        images.map { ["type": "image", "source": ["type": "base64", "media_type": $0.mediaType, "data": $0.base64]] }
            + [["type": "text", "text": text]]
    }

    /// OpenAI-compatible `/chat/completions` (OpenAI, Gemini, Grok, Mistral, OpenRouter, LM Studio…).
    static func openAIContent(_ images: [ChatImage], text: String) -> [[String: Any]] {
        [["type": "text", "text": text]] + images.map { ["type": "image_url", "image_url": ["url": $0.dataURL]] }
    }
}
