import AppKit
import Foundation
import OSLog

/// Reading back through a long agent conversation: rows are on screen the whole way up, so the blank-conversation
/// guard never steps in. It used to: a row that scrolled back into view was the lazy stack's own row again and did not
/// report where it stands, the guard counted the view as blank with rows on it, and pulled it away (back to the row it
/// last saw, then to the end, and made the scroll view again) while you read.
///
/// It scrolls by moving the conversation's clip view, as a trackpad does (an offscreen window gets no wheel events),
/// and pauses now and then as a reader does, long enough for the guard to act.
final class ScrollBackStaysPut: Scenario {
    func testScrollBackStaysPut() throws {
        try scenario("Scrolling back through a long agent conversation never counts it as blank") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let prompts = (1...24).map { "Prompt number \($0) of the long session" }
            let long = try nook.session(project: project, title: "Long session", messages: prompts, recording: "long-turns")
            try nook.open(long)
            try expect(screen.text(prompts[23])).toBeVisible()
            screen.settle(1.0)

            guard let scrollView = Self.conversation(in: screen.window?.contentView) else {
                throw ScenarioFailure.couldNotRun("the conversation's scroll view was not found")
            }
            let started = Date()
            let wheel = Wheel(window: screen.window, scrollView: scrollView)
            defer { wheel.finish() }
            // Up to the start and back down twice, 30 pt a step, with a reader's pause every 20 steps.
            for deltaY in [30.0, -30.0, 30.0, -30.0] {
                for step in 1...400 {
                    let before = scrollView.contentView.bounds.origin.y
                    wheel.step(deltaY: deltaY)
                    if scrollView.contentView.bounds.origin.y == before { break }
                    if step % 20 == 0 { screen.settle(0.6) }
                }
            }
            try app.screenshot("scrolled")

            let recoveries = try Self.blankRecoveries(since: started)
            if !recoveries.isEmpty {
                throw ScenarioFailure.assertion("the conversation counted as blank \(recoveries.count) time(s) while rows were "
                                                + "on screen; first: \(recoveries[0])")
            }
        }
    }

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

    /// The blank guard's "recovering" lines this process logged since `date` (`recoversBlankRows`). The store's position
    /// for a date is only a place to start reading and also hands out earlier lines: those of the scenario before this one
    /// in the same test process (its conversation going away) failed this one on CI, so the date is checked per line.
    private static func blankRecoveries(since date: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: date))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= date && $0.subsystem == "nl.imdigital.nook"
                      && $0.composedMessage.contains("Blank conversation, recovering") }
            .map(\.composedMessage)
    }
}
