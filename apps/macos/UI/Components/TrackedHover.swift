import AppKit
import SwiftUI

extension View {
    /// `onHover` that also works in the main window's title bar row. That row has an (empty) toolbar over it, and
    /// SwiftUI's own hover never hears the pointer under it, so a side panel's tabs there never showed their cross.
    /// This reads the pointer from a tracking area of its own, which AppKit reports wherever the view lies; it takes no
    /// clicks.
    func trackedHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(TrackedHoverArea(action: action))
    }
}

private struct TrackedHoverArea: NSViewRepresentable {
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.action = action
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        view.action = action
    }

    final class AreaView: NSView {
        var action: ((Bool) -> Void)?
        private var inside = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // Only what shows of this view (`shownBounds`); `.inVisibleRect` would reach out to the nearest clipping
            // ancestor.
            let shown = shownBounds
            if !shown.isEmpty {
                addTrackingArea(NSTrackingArea(rect: shown, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
            }
            // The view moved (a tab scrolled, closed or opened) under a pointer that did not: ask where the pointer is.
            DispatchQueue.main.async { [weak self] in self?.sync() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { report(false) }
        }

        override func mouseEntered(with event: NSEvent) { report(true) }
        override func mouseExited(with event: NSEvent) { report(false) }

        private func sync() {
            guard let window else { return report(false) }
            report(shownBounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }

        private func report(_ value: Bool) {
            guard value != inside else { return }
            inside = value
            action?(value)
        }
    }
}
