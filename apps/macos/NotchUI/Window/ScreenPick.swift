import Foundation

/// Which screen a window is on, from frames alone, so it is tested without real screens.
enum ScreenPick {
    /// The frame of the screen showing most of a window whose frame is in accessibility coordinates (origin top left of
    /// the primary screen, the first one, y running down). `screens` are in Cocoa coordinates (origin bottom left, y
    /// running up). Nil when the window is on none of them.
    static func screen(showing window: CGRect, in screens: [CGRect]) -> CGRect? {
        guard let primary = screens.first else { return nil }
        let cocoa = CGRect(x: window.minX, y: primary.maxY - window.maxY, width: window.width, height: window.height)
        guard let best = screens.max(by: { overlap($0, cocoa) < overlap($1, cocoa) }), overlap(best, cocoa) > 0 else { return nil }
        return best
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }
}
