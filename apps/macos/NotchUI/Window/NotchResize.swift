import Foundation

/// Making the open notch larger or smaller by dragging its sides or bottom corners. What you drag is kept as an extra
/// width and height on top of the size each tab starts at, so the Agents tab stays wider than the music, just bigger.
enum NotchResize {
    /// The edge or corner being dragged. The notch stays centred under the camera, so a side moves both sides.
    enum Edge: String, CaseIterable {
        case left, right, bottom, bottomLeft, bottomRight

        /// Which way the drag changes the width (-1 for the left side, 1 for the right, 0 for the bottom alone).
        var horizontal: CGFloat {
            switch self {
            case .left, .bottomLeft: return -1
            case .right, .bottomRight: return 1
            case .bottom: return 0
            }
        }

        var vertical: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    }

    /// The smallest an open notch gets, whatever you drag.
    static let minimum = CGSize(width: 560, height: 300)
    static let defaultsKey = "notch.panelExtra"

    /// `base` with `extra` added, kept between the minimum and `maximum` (the room the panel window and the screen give).
    /// A tab that starts smaller than the minimum (or larger than the maximum) keeps that edge of its own size.
    static func size(base: CGSize, extra: CGSize, maximum: CGSize) -> CGSize {
        func fit(_ value: CGFloat, _ base: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            min(max(value, min(low, base)), max(high, base))
        }
        return CGSize(width: fit(base.width + extra.width, base.width, low: minimum.width, high: maximum.width),
                      height: fit(base.height + extra.height, base.height, low: minimum.height, high: maximum.height))
    }

    /// The extra size after dragging `edge` by `translation` (screen points, y down) from where it was at `start`.
    /// The notch is centred, so a side dragged 10 points out makes it 20 points wider and the edge stays under the pointer.
    static func dragged(_ edge: Edge, from start: CGSize, translation: CGSize) -> CGSize {
        CGSize(width: start.width + 2 * edge.horizontal * translation.width,
               height: start.height + (edge.vertical ? translation.height : 0))
    }

    /// `extra` limited to what `size` can actually show for `base`, so dragging past the limit and back responds at once.
    static func clamped(_ extra: CGSize, base: CGSize, maximum: CGSize) -> CGSize {
        let shown = size(base: base, extra: extra, maximum: maximum)
        return CGSize(width: shown.width - base.width, height: shown.height - base.height)
    }

    static func load(_ defaults: UserDefaults = .standard) -> CGSize {
        CGSize(width: defaults.double(forKey: defaultsKey + ".width"), height: defaults.double(forKey: defaultsKey + ".height"))
    }

    static func save(_ extra: CGSize, _ defaults: UserDefaults = .standard) {
        defaults.set(Double(extra.width), forKey: defaultsKey + ".width")
        defaults.set(Double(extra.height), forKey: defaultsKey + ".height")
    }
}
