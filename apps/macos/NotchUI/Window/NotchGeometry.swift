import AppKit

/// Notch dimensions on a single screen. Macs without a physical notch use a simulated notch
/// below the menu bar, keeping Nook's behavior uniform across all Macs.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Floating panel instead of anchored to notch: no physical notch, allows custom positioning.
    var isFloating = false

    static let placeholder = NotchGeometry(
        screenFrame: .zero, hasNotch: false, notchWidth: 180, notchHeight: 34
    )

    static func make(for screen: NSScreen, floating: Bool = false) -> NotchGeometry {
        let frame = screen.frame
        if floating {
            return NotchGeometry(screenFrame: frame, hasNotch: false, notchWidth: 64, notchHeight: 34, isFloating: true)
        }
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return NotchGeometry(
                screenFrame: frame,
                hasNotch: true,
                notchWidth: frame.width - left.width - right.width,
                notchHeight: inset
            )
        }
        let menuBar = max(frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screenFrame: frame, hasNotch: false, notchWidth: 180, notchHeight: menuBar)
    }

    /// Selects screen according to preference: "auto" (notched screen, otherwise main), "main",
    /// "mouse" (where cursor is located), or screen name. Falls back to "auto" if screen not found.
    static func preferredScreen(choice: String = "auto") -> NSScreen {
        let screens = NSScreen.screens
        let primary = screens.first ?? NSScreen.main
        switch choice {
        case "main":
            if let primary { return primary }
        case "mouse":
            if let screen = screenWithMouse() { return screen }
        case "auto":
            break
        default:
            if let named = screens.first(where: { $0.localizedName == choice }) { return named }
        }
        return screens.first { $0.safeAreaInsets.top > 0 }
            ?? primary
            ?? NSScreen.screens[0]
    }

    static func screenWithMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
