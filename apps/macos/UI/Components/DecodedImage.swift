import AppKit
import ImageIO

/// Pictures that came in as bytes (a cover, an avatar, a favicon, a link's picture), decoded once at the size they are
/// shown at. `NSImage(data:)` keeps the downloaded bytes and decodes the full picture again for drawing: a 2000-pixel
/// og:image then took 16 MB for a 280-point card.
enum DecodedImage {
    /// The picture in `data`, at most `maxPixel` pixels on its longest side (never enlarged), upright, decoded now; the
    /// bytes are not kept. Of a file with several sizes (a favicon `.ico`) the largest is used.
    static func image(_ data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, largest(source), options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The bytes the picture takes in memory, for a cache's cost.
    static func cost(_ image: NSImage) -> Int {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg.bytesPerRow * cg.height }
        return Int(image.size.width * image.size.height * 4)
    }

    /// The index of the widest image in the file: the first of equals, so a GIF or a photo gives its first frame.
    private static func largest(_ source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return 0 }
        var best = (index: 0, width: 0)
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
            if width > best.width { best = (index, width) }
        }
        return best.index
    }
}
