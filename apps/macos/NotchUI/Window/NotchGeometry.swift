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

    /// The screen you work on: the one holding the focused window of the app in front, else the one with the pointer.
    /// Nil only when neither is known.
    static func screenInUse() -> NSScreen? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own,
           let window = focusedWindowFrame(pid: app.processIdentifier),
           let frame = ScreenPick.screen(showing: window, in: NSScreen.screens.map(\.frame)),
           let screen = NSScreen.screens.first(where: { $0.frame == frame }) {
            return screen
        }
        return screenWithMouse()
    }

    /// The focused window of an app, from the accessibility layer; nil without access or when it does not answer quickly.
    private static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        let root = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(root, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func screenWithMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
