import AppKit

/// De maten van de notch op één scherm. Macs zonder notch krijgen een gesimuleerde notch
/// onder de menubalk, zodat Nook overal hetzelfde werkt.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var hasNotch: Bool
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Zwevend paneel in plaats van in de notch: geen notch, ruimte voor een eigen positie.
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

    /// Kiest het scherm volgens de instelling: "auto" (met notch, anders het hoofdscherm), "main",
    /// "mouse" (waar de muis is) of de naam van een scherm. Is dat scherm er niet, dan geldt "auto".
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
