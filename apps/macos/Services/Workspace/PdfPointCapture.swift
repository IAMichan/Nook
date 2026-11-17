import AppKit
import PDFKit

/// What a click on a PDF page in the side panel turns into: the spot measured on its page (`PickedPdfPoint`), a picture
/// of the area around it with the spot marked, and the mark left on the page in view.
enum PdfPointCapture {
    /// The iris the browser picker marks elements with (`BrowserPickScript`): the same mark for the same gesture, and it
    /// shows on a white page, where the theme's soft white accent would not.
    static let markColor = NSColor(srgbRed: 124 / 255, green: 108 / 255, blue: 240 / 255, alpha: 1)

    /// The area around the spot the picture shows, in points, and how many pixels a point gets.
    private static let pictureSize = CGSize(width: 280, height: 180)
    private static let pictureScale: CGFloat = 2

    /// The spot `location` (in the page's own space) on `page` of `document`.
    static func point(on page: PDFPage, at location: CGPoint, in document: PDFDocument, path: String) -> PickedPdfPoint {
        let box = page.bounds(for: .cropBox)
        let shown = PickedPdfPoint.shown(x: location.x, y: location.y, box: (box.minX, box.minY, box.maxX, box.maxY),
                                         rotation: page.rotation)
        return PickedPdfPoint(path: path, page: document.index(for: page) + 1, pageCount: document.pageCount,
                              width: shown.width, height: shown.height, fromLeft: shown.fromLeft, fromTop: shown.fromTop,
                              pdfX: location.x, pdfY: location.y, text: text(on: page, at: location))
    }

    /// The words on the line under the spot; else those close around it.
    private static func text(on page: PDFPage, at location: CGPoint) -> String {
        if let line = page.selectionForLine(at: location), line.bounds(for: page).insetBy(dx: -6, dy: -6).contains(location),
           let words = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty {
            return words
        }
        let around = CGRect(x: location.x - 80, y: location.y - 16, width: 160, height: 32)
        return page.selection(for: around)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// A picture of the page around the spot, the spot marked with a crosshair in a ring.
    static func picture(of page: PDFPage, around point: PickedPdfPoint) -> NSImage? {
        // The page is drawn as it is shown (rotation applied, origin bottom left), so the spot is measured that way too.
        let spot = CGPoint(x: point.fromLeft, y: point.height - point.fromTop)
        let size = CGSize(width: min(pictureSize.width, point.width), height: min(pictureSize.height, point.height))
        let crop = CGRect(x: min(max(0, spot.x - size.width / 2), point.width - size.width),
                          y: min(max(0, spot.y - size.height / 2), point.height - size.height),
                          width: size.width, height: size.height)
        let pixels = (width: Int(crop.width * pictureScale), height: Int(crop.height * pictureScale))
        guard pixels.width > 0, pixels.height > 0,
              let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        context.scaleBy(x: pictureScale, y: pictureScale)
        context.translateBy(x: -crop.minX, y: -crop.minY)
        context.saveGState()
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
        drawMark(at: spot, in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: crop.width, height: crop.height))
    }

    private static func drawMark(at spot: CGPoint, in context: CGContext) {
        let radius: CGFloat = 9, arm: CGFloat = 16
        for (color, width) in [(NSColor.white.withAlphaComponent(0.9), CGFloat(4)), (markColor, CGFloat(1.75))] {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.strokeEllipse(in: CGRect(x: spot.x - radius, y: spot.y - radius, width: radius * 2, height: radius * 2))
            context.move(to: CGPoint(x: spot.x - arm, y: spot.y))
            context.addLine(to: CGPoint(x: spot.x + arm, y: spot.y))
            context.move(to: CGPoint(x: spot.x, y: spot.y - arm))
            context.addLine(to: CGPoint(x: spot.x, y: spot.y + arm))
            context.strokePath()
        }
    }

    /// The mark left on the page in view: a ring around the spot. Only in memory; the file is never written.
    static func mark(at location: CGPoint) -> PDFAnnotation {
        let radius: CGFloat = 7
        let mark = PDFAnnotation(bounds: CGRect(x: location.x - radius, y: location.y - radius, width: radius * 2, height: radius * 2),
                                 forType: .circle, withProperties: nil)
        mark.color = markColor
        mark.interiorColor = markColor.withAlphaComponent(0.25)
        let border = PDFBorder()
        border.lineWidth = 2
        mark.border = border
        return mark
    }
}
