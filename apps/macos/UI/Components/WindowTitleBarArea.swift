import AppKit
import SwiftUI

/// Empty space that acts as the window's title bar: dragging it moves the window, and a double-click does what
/// System Settings › Desktop & Dock asks of a title bar (zoom to fill the screen by default, or minimize, or nothing),
/// as in every other Mac app. SwiftUI's `WindowDragGesture` takes the mouse-down, so a tap gesture beside it never
/// hears the second click; this reads both from the event itself.
///
/// In a `.fullSizeContentView` window the system's transparent title bar still lies over the top strip (the height of
/// the traffic lights) and takes the click there before it reaches this view, without zooming. A local event monitor
/// sees the double-click first and handles it when this view is what lies under the pointer.
struct WindowTitleBarArea: NSViewRepresentable {
    func makeNSView(context: Context) -> TitleBarView { TitleBarView() }
    func updateNSView(_ nsView: TitleBarView, context: Context) {}

    final class TitleBarView: NSView {
        private var monitor: Any?

        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, event.clickCount == 2,
                      let content = window.contentView,
                      content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow) === self
                else { return event }
                WindowTitleBarArea.doubleClick(window)
                return nil
            }
        }

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
