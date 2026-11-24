import AppKit
import Foundation
import ObjectiveC

/// Scrolling back down to the end of a long session while its agent works: the view stays at the end and follows the
/// agent from there. It used to reach the end and then jump back up by a chunk, so you could not stay at the end: each
/// time 16 of the working turn's rows moved into the lazy part of the conversation (`HistoryWindow.lazyRows`), the
/// content shrank and grew back, and the scroll view's clip view kept the offset of the shrink, thousands of points up,
/// without SwiftUI reporting a move.
///
/// It scrolls in trackpad strokes: each step goes through the app's event monitors first (where the conversation
/// learns of your step, `readingScroller`), with the window and the place under the pointer filled in, which an event
/// for a window that is not on screen lacks; then the step moves the clip view, as the scroll view takes no wheel event
/// in a window that is not on screen. A stroke posts the live-scroll notifications around its steps, so the scroll
/// phase is not idle during it, as with fingers on a trackpad.
final class LongSessionStaysAtEnd: Scenario {
    /// How far the view may stand from its end once it got there and still count as at it (`ScrollFrame.endMargin`).
    static let endMargin = 40.0
    static let rounds = 10
    /// Seconds hands off at the end after each round.
    static let hold = 6.0

    func testLongSessionStaysAtEnd() throws {
        try scenario("Scrolling down to the end of a long working session stays at the end") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math { static func sum(a: Int) -> Int { a + 1 } }\n"])
            let prompts = (1...6).map { "Check and fix part \($0) of the project" }
            let session = try nook.session(project: project, title: "Long live work", messages: prompts, recording: "long-live-work")
            try nook.open(session)
            try expect(screen.text(prompts[5])).toBeVisible()
            screen.settle(1.0)
            // The last turn works for about three minutes: hundreds of calls with large outputs.
            try nook.send(session, "Now the long job", wait: false)
            screen.settle(4.0)

            guard let scrollView = Self.conversation(in: screen.window?.contentView) else {
                throw ScenarioFailure.couldNotRun("the conversation's scroll view was not found")
            }
            let wheel = Wheel(window: screen.window, scrollView: scrollView)
            defer { wheel.finish() }
            self.log(String(format: "before scrolling: %.0f pt from the end of %.0f", Self.fromEnd(scrollView), Self.content(scrollView)))

            var worst = 0.0
            var worstWhen = ""
            @MainActor func measure(_ when: @autoclosure () -> String) {
                let away = Self.fromEnd(scrollView)
                if away > worst {
                    worst = away
                    worstWhen = when()
                }
            }
            // Rows move into the lazy part 16 at a time, a few times per round: enough rounds to see the jump every run.
            for round in 1...Self.rounds {
                // Up a long way in a few strokes and a reader's pause, then down in strokes until the end and a stroke
                // past it, as a hand does on a trackpad.
                for _ in 0..<5 { wheel.stroke(steps: 12, deltaY: 40) }
                screen.settle(0.8)
                var reached = false
                var after = 0
                for _ in 0..<60 where after < 2 {
                    wheel.stroke(steps: 12, deltaY: -40) { step in
                        if reached { measure("round \(round), step \(step) of a stroke after reaching the end") }
                        else if Self.fromEnd(scrollView) <= 1 { reached = true }
                    }
                    if reached { after += 1 }
                }
                guard reached else {
                    throw ScenarioFailure.assertion("round \(round): scrolling down never reached the end "
                                                    + String(format: "(%.0f pt from it)", Self.fromEnd(scrollView)))
                }
                // Then hands off while the agent keeps working: the view stays at the end.
                let end = Date().addingTimeInterval(Self.hold)
                while Date() < end {
                    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                    measure(String(format: "round %d, %.1f s after the last stroke", round, Self.hold - end.timeIntervalSinceNow))
                }
                self.log(String(format: "round %d: at most %.0f pt from the end so far", round, worst))
            }
            try app.screenshot("at-end")

            if worst > Self.endMargin {
                throw ScenarioFailure.assertion(String(format: "after scrolling down to the end the view moved %.0f pt back up (%@)",
                                                       worst, worstWhen))
            }
        }
    }

    /// How far the view stands above the end of its content.
    private static func fromEnd(_ scrollView: NSScrollView) -> Double {
        let clip = scrollView.contentView
        let end = content(scrollView) + Double(clip.contentInsets.bottom) - Double(clip.bounds.height)
        return max(0, end - Double(clip.bounds.origin.y))
    }

    private static func content(_ scrollView: NSScrollView) -> Double { Double(scrollView.documentView?.frame.height ?? 0) }

    /// The scroll view with the tallest content: the conversation.
    private static func conversation(in root: NSView?) -> NSScrollView? {
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(visit)
        }
        root.map(visit)
        return best
    }
}

/// Scroll-wheel steps in points (a trackpad's) over the middle of a scroll view in an offscreen window.
@MainActor
private final class Wheel {
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
