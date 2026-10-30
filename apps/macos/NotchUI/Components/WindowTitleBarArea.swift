import AppKit
import SwiftUI

/// Empty space that acts as the window's title bar: dragging it moves the window, and a double-click does what
/// System Settings › Desktop & Dock asks of a title bar (zoom to fill the screen by default, or minimize, or nothing),
/// as in every other Mac app. SwiftUI's `WindowDragGesture` takes the mouse-down, so a tap gesture beside it never
/// hears the second click; this reads both from the event itself.
struct WindowTitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarView { TitleBarView() }
    func updateNSView(_ nsView: TitleBarView, context: Context) {}

    final class TitleBarView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                WindowTitleBarArea.doubleClick(window)
            } else {
                window.performDrag(with: event)
            }
        }
    }

    /// The title bar double-click setting. `AppleActionOnDoubleClick` is "Maximize"/"Fill" (zoom), "Minimize" or
    /// "None"; a Mac that never changed it has no value and zooms, unless the older minimize switch is on.
    static func doubleClick(_ window: NSWindow) {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "None":
            return
        case "Minimize":
            window.performMiniaturize(nil)
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"):
            window.performMiniaturize(nil)
        default:
            window.performZoom(nil)
        }
    }
}
