import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The colors you draw and write with on a picture about to go.
enum ChatImageInk: String, CaseIterable, Sendable {
    case white, black, red, yellow, green, blue

    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: return (1, 1, 1)
        case .black: return (0, 0, 0)
        case .red: return (0.94, 0.23, 0.2)
        case .yellow: return (1, 0.8, 0.1)
        case .green: return (0.2, 0.78, 0.4)
        case .blue: return (0.2, 0.5, 1)
        }
    }
}

/// What you did to a picture before sending it: turned, cropped, drawn and written on. It stays a description until the
/// send, so every step can be undone and the file itself is left alone (`ChatImageRender` makes the picture that goes).
///
/// Every place is in the turned picture's own unit square: (0, 0) is its top left, (1, 1) its bottom right, whatever the
/// size it is shown at and however it is cropped.
struct ChatImageEdit: Equatable, Sendable {
    struct Stroke: Equatable, Sendable {
        var points: [CGPoint]
        var ink: ChatImageInk
    }

    struct Label: Equatable, Identifiable, Sendable {
        var id = UUID()
        var text: String
        var center: CGPoint
        var ink: ChatImageInk
    }

    /// What a drag on the crop frame takes hold of.
    enum CropHandle: CaseIterable, Sendable {
        case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, inside

        var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
        var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
        var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
        var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    }

    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// The crop never gets smaller than this part of the picture, so a handle stays within reach.
    static let minimumCrop: CGFloat = 0.05
    /// A line's width and a label's size, as parts of the picture's longest side: they look the same on a screenshot
    /// and on a photo of many times its pixels.
    static let strokeWidth: CGFloat = 0.006
    static let labelSize: CGFloat = 0.04

    /// Quarter turns clockwise.
    var turns = 0
    var crop = whole
    var strokes: [Stroke] = []
    var labels: [Label] = []

    /// Nothing to do to the picture: it can go as it is.
    var isUntouched: Bool { turns == 0 && crop == Self.whole && strokes.isEmpty && labels.isEmpty }

    /// A quarter turn clockwise. What is on the picture moves along, and text stays upright.
    mutating func rotate() {
        turns = (turns + 1) % 4
        crop = CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
        for index in strokes.indices { strokes[index].points = strokes[index].points.map(Self.turned) }
        for index in labels.indices { labels[index].center = Self.turned(labels[index].center) }
    }

    private static func turned(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - point.y, y: point.x)
    }

    /// A place on what is shown of the picture (`window`, in the same unit square), as a place on the whole picture.
    static func point(_ shown: CGPoint, in window: CGRect) -> CGPoint {
        clamped(CGPoint(x: window.minX + shown.x * window.width, y: window.minY + shown.y * window.height))
    }

    static func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    /// The crop after dragging `handle` by `delta`: inside the picture, never smaller than `minimumCrop`. The inside of
    /// the frame moves it whole, without changing its size.
    static func crop(_ crop: CGRect, moving handle: CropHandle, by delta: CGSize) -> CGRect {
        if handle == .inside {
            return CGRect(x: min(1 - crop.width, max(0, crop.minX + delta.width)),
                          y: min(1 - crop.height, max(0, crop.minY + delta.height)),
                          width: crop.width, height: crop.height)
        }
        var (left, right, top, bottom) = (crop.minX, crop.maxX, crop.minY, crop.maxY)
        if handle.movesLeft { left = min(right - minimumCrop, max(0, left + delta.width)) }
        if handle.movesRight { right = max(left + minimumCrop, min(1, right + delta.width)) }
        if handle.movesTop { top = min(bottom - minimumCrop, max(0, top + delta.height)) }
        if handle.movesBottom { bottom = max(top + minimumCrop, min(1, bottom + delta.height)) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The crop in pixels of a turned picture this size, whole pixels and at least one.
    static func pixels(of crop: CGRect, width: Int, height: Int) -> CGRect {
        let (w, h) = (CGFloat(width), CGFloat(height))
        let left = (crop.minX * w).rounded(), top = (crop.minY * h).rounded()
        return CGRect(x: left, y: top, width: max(1, (crop.maxX * w).rounded() - left),
                      height: max(1, (crop.maxY * h).rounded() - top))
    }
}
