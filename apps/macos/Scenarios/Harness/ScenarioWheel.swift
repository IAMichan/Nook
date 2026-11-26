import AppKit
import Foundation
import ObjectiveC

/// Scroll-wheel steps in points (a trackpad's) over the middle of a scroll view in an offscreen window, as a hand
/// scrolls: each step goes through the app's event monitors first (where a conversation learns of your step,
/// `readingScroller`, and stops following its end), with the window and the place under the pointer filled in, which an
/// event for a window that is not on screen lacks; then the step moves the clip view, as the scroll view takes no wheel
/// event in a window that is not on screen. Moving the clip view alone is no scroll of yours: a conversation that follows
/// its end goes straight back to it. Call `finish()` when done.
@MainActor
final class Wheel {
    private let scrollView: NSScrollView

    init(window: NSWindow?, scrollView: NSScrollView) {
        self.scrollView = scrollView
        WheelTarget.window = window
        WheelTarget.point = scrollView.convert(NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: nil)
        WheelTarget.swapped(true)
    }

    /// One step of `deltaY` (above zero toward the start), then a frame for the view to move by it.
    func step(deltaY: Double) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        guard let event = NSEvent(cgEvent: cg) else { return }
        // The app's local monitors see it first, as for any event (`readingScroller` learns of your step there).
        NSApp.sendEvent(event)
        // Then the view moves by it. The scroll view takes no wheel event in a window that is not on screen, so the
        // step moves its clip view, as a trackpad step does (a flipped document: down is a larger offset).
        let clip = scrollView.contentView
        let top = -Double(clip.contentInsets.top)
        let end = max(top, Double(scrollView.documentView?.frame.height ?? 0) + Double(clip.contentInsets.bottom) - Double(clip.bounds.height))
        let y = min(max(top, Double(clip.bounds.origin.y) - deltaY), end)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
    }

    /// A stroke of `steps` steps, as one movement of fingers on a trackpad: the scroll view scrolls live from its start
    /// to its end (its scroll phase is not idle in between), and `each` runs after every step.
    func stroke(steps: Int, deltaY: Double, each: @MainActor (Int) -> Void = { _ in }) {
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        for index in 0..<steps {
            step(deltaY: deltaY)
            center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
            each(index + 1)
        }
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    func finish() {
        WheelTarget.swapped(false)
        WheelTarget.window = nil
    }
}

/// Fills in the window and the place under the pointer of a scroll-wheel event while a `Wheel` runs.
@MainActor
private enum WheelTarget {
    static weak var window: NSWindow?
    static var point = NSPoint.zero
    private static var isSwapped = false

    static func swapped(_ on: Bool) {
        guard on != isSwapped else { return }
        isSwapped = on
        for (original, replacement) in [(#selector(getter: NSEvent.window), #selector(getter: NSEvent.scenario_wheelWindow)),
                                         (#selector(getter: NSEvent.locationInWindow), #selector(getter: NSEvent.scenario_wheelLocation))] {
            if let a = class_getInstanceMethod(NSEvent.self, original), let b = class_getInstanceMethod(NSEvent.self, replacement) {
                method_exchangeImplementations(a, b)
            }
        }
    }
}

extension NSEvent {
    /// After the swap these call the original getters.
    @objc fileprivate var scenario_wheelWindow: NSWindow? {
        type == .scrollWheel ? MainActor.assumeIsolated { WheelTarget.window } ?? scenario_wheelWindow : scenario_wheelWindow
    }

    @objc fileprivate var scenario_wheelLocation: NSPoint {
        type == .scrollWheel ? MainActor.assumeIsolated { WheelTarget.point } : scenario_wheelLocation
    }
}
