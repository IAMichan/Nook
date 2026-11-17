import Foundation

// Pointing at a spot in a PDF in the side panel. Foundation only, so tests can use it independently.

/// A spot you clicked in a PDF: the page and where on it, measured from each edge, so an agent that made the PDF can
/// find the place in its source. The text around it comes from the file, so it is data, never an order.
struct PickedPdfPoint: Equatable, Sendable {
    var path: String
    /// 1-based.
    var page: Int
    var pageCount: Int
    /// The page as it is shown (its rotation applied), in PDF points (1/72 inch).
    var width: Double
    var height: Double
    /// From the page's left and top edge as it is shown, in points.
    var fromLeft: Double
    var fromTop: Double
    /// The same spot in the PDF's own space: origin bottom left of the media box, rotation not applied.
    var pdfX: Double
    var pdfY: Double
    /// The words on the line at the spot, if any.
    var text: String = ""

    var fromRight: Double { max(0, width - fromLeft) }
    var fromBottom: Double { max(0, height - fromTop) }
    var shareLeft: Double { width > 0 ? fromLeft / width * 100 : 0 }
    var shareTop: Double { height > 0 ? fromTop / height * 100 : 0 }

    var fileName: String { (path as NSString).lastPathComponent }

    /// The name of its tile in the composer: file, page and where on it.
    var name: String {
        "\(fileName) · \(page)/\(pageCount) · \(Self.number(shareLeft, digits: 0))%, \(Self.number(shareTop, digits: 0))%"
    }

    /// The name of the picture of the spot that goes along.
    var imageName: String {
        "\((fileName as NSString).deletingPathExtension)-p\(page)-\(Int(fromLeft.rounded()))x\(Int(fromTop.rounded()))"
    }

    /// What the agent reads: the file, the page, and the spot measured from every edge in points, millimetres and as a
    /// share of the page, with the text at the spot.
    var snippet: String {
        let width = max(width, 0.0001), height = max(height, 0.0001)
        func edge(_ points: Double, _ size: Double) -> String {
            "\(Self.number(points, digits: 1)) pt (\(Self.number(points * Self.millimetresPerPoint, digits: 1)) mm, \(Self.number(points / size * 100, digits: 1))%)"
        }
        var lines = [
            "Point in PDF `\(path)`, page \(page) of \(pageCount)",
            "Page size: \(Self.number(self.width, digits: 1)) × \(Self.number(self.height, digits: 1)) pt "
                + "(\(Self.number(self.width * Self.millimetresPerPoint, digits: 1)) × \(Self.number(self.height * Self.millimetresPerPoint, digits: 1)) mm)",
            "From the left: \(edge(fromLeft, width))",
            "From the right: \(edge(fromRight, width))",
            "From the top: \(edge(fromTop, height))",
            "From the bottom: \(edge(fromBottom, height))",
            "PDF coordinates (origin bottom left, unrotated): x \(Self.number(pdfX, digits: 1)), y \(Self.number(pdfY, digits: 1))",
            "The attached picture `\(imageName)` shows the area around it; the point is the marked crosshair in its middle.",
        ]
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { lines += ["", "Text at this point:", String(words.prefix(Self.textLimit))] }
        return lines.joined(separator: "\n")
    }

    /// The composer's tile for this spot, with `id` as the key of its snippet.
    func reference(id: String) -> ContextRef {
        ContextRef(kind: .element, id: id, label: name)
    }

    static let millimetresPerPoint = 25.4 / 72
    static let textLimit = 600
    /// The prefix of a PDF spot's id; the record names its source by it.
    static let idPrefix = "pdf-"

    /// A spot on a page in the page's own space, as it is shown: the page's rotation (0, 90, 180, 270, clockwise) applied
    /// and the box's origin taken off. `box` is the page's crop box in its own space.
    static func shown(x: Double, y: Double, box: (minX: Double, minY: Double, maxX: Double, maxY: Double),
                      rotation: Int) -> (fromLeft: Double, fromTop: Double, width: Double, height: Double) {
        let width = box.maxX - box.minX, height = box.maxY - box.minY
        switch ((rotation % 360) + 360) % 360 {
        case 90: return (y - box.minY, x - box.minX, height, width)
        case 180: return (box.maxX - x, y - box.minY, width, height)
        case 270: return (box.maxY - y, box.maxX - x, height, width)
        default: return (x - box.minX, box.maxY - y, width, height)
        }
    }

    private static func number(_ value: Double, digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
