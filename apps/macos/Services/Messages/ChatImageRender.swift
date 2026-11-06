import AppKit
import ImageIO

extension ChatImageInk {
    var cgColor: CGColor { CGColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1) }
}

/// Makes the picture a `ChatImageEdit` describes, the same way for the preview and for what is sent.
enum ChatImageRender {
    /// The longest side of a picture that went through an edit.
    static let maxSide = 4096

    /// The picture in the file, upright, at most `side` pixels on its longest side. Called off the main thread.
    static func picture(_ url: URL, side: Int = maxSide) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? side
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? side
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(side, max(width, height)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// `image` turned, drawn and written on, and cropped.
    static func render(_ image: CGImage, edit: ChatImageEdit) -> CGImage? {
        let sideways = edit.turns % 2 != 0
        let width = sideways ? image.height : image.width
        let height = sideways ? image.width : image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(edit.turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        context.restoreGState()

        // From here on the top left is (0, 0), as in the edit.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let size = CGSize(width: width, height: height)
        let longest = CGFloat(max(width, height))
        draw(edit.strokes, in: context, size: size, longest: longest)
        draw(edit.labels, in: context, size: size, longest: longest)

        guard let made = context.makeImage() else { return nil }
        guard edit.crop != ChatImageEdit.whole else { return made }
        return made.cropping(to: ChatImageEdit.pixels(of: edit.crop, width: width, height: height))
    }

    private static func draw(_ strokes: [ChatImageEdit.Stroke], in context: CGContext, size: CGSize, longest: CGFloat) {
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(longest * ChatImageEdit.strokeWidth)
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let places = ([first] + stroke.points).map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            context.setStrokeColor(stroke.ink.cgColor)
            context.addLines(between: places)
            context.strokePath()
        }
    }

    private static func draw(_ labels: [ChatImageEdit.Label], in context: CGContext, size: CGSize, longest: CGFloat) {
        guard !labels.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let font = NSFont.systemFont(ofSize: longest * ChatImageEdit.labelSize, weight: .semibold)
        for label in labels {
            let text = NSAttributedString(string: label.text, attributes: [
                .font: font,
                .foregroundColor: NSColor(cgColor: label.ink.cgColor) ?? .white,
            ])
            let box = text.size()
            text.draw(at: CGPoint(x: label.center.x * size.width - box.width / 2,
                                  y: label.center.y * size.height - box.height / 2))
        }
    }
}
