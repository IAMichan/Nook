import AppKit
import Foundation

/// Dragging the side panel's line wider and narrower beside a working agent's conversation, at its end: the drag lays
/// every row out again at a new width on every frame of the screen. The conversation stays at its end, during the drag
/// and after it, and keeps following the agent from there; you never have to scroll back down to go on.
final class SidePanelDragStaysAtEnd: Scenario {
    /// How far the view may stand from its end and still count as there (`ScrollFrame.endMargin`).
    static let endMargin = 40.0

    func testSidePanelDragStaysAtEnd() throws {
        try scenario("Dragging the side panel beside a working agent keeps the conversation at its end") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math { static func sum(a: Int) -> Int { a + 1 } }\n"])
            let prompts = (1...6).map { "Check and fix part \($0) of the project" }
            let session = try nook.session(project: project, title: "Wrapping work", messages: prompts, recording: "wrapping-work")
            try nook.open(session)
            try expect(screen.text(prompts[5])).toBeVisible()
            screen.settle(1.0)
            try nook.send(session, "Now the long job", wait: false)
            screen.settle(3.0)

            let model = nook.app.viewModel
            model.toggleSidePanel()
            screen.settle(1.5)
            guard let scrollView = Self.conversation(in: screen.window?.contentView) else {
                throw ScenarioFailure.couldNotRun("the conversation's scroll view was not found")
            }
            log(String(format: "side panel open: %.0f pt from the end", Self.fromEnd(scrollView)))

            var problems: [String] = []
            // Sweeps of a drag, one width per frame of the screen, as a hand drags the line: wider, narrower, and back.
            for sweep in 0..<20 {
                let from = sweep % 2 == 0 ? 320.0 : 600.0
                let to = sweep % 2 == 0 ? 600.0 : 320.0
                var worst = 0.0
                for frame in 0...45 {
                    let width = (from + (to - from) * Double(frame) / 45).rounded()
                    model.setSessionPanelWidth(width, for: model.selectedAgentID)
                    RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60))
                    worst = max(worst, Self.fromEnd(scrollView))
                }
                // Hands off: the agent keeps working, and the view must follow it at the end.
                screen.settle(1.5)
                let away = Self.fromEnd(scrollView)
                log(String(format: "sweep %d: at most %.0f pt from the end while dragging, %.0f pt after", sweep, worst, away))
                if away > Self.endMargin {
                    problems.append(String(format: "after drag %d the view stayed %.0f pt above its end", sweep, away))
                    break
                }
            }
            try app.screenshot("after-drags")
            if !problems.isEmpty { throw ScenarioFailure.assertion(problems.joined(separator: "; ")) }
        }
    }

    /// How far the view stands above the end of its content.
    private static func fromEnd(_ scrollView: NSScrollView) -> Double {
        let clip = scrollView.contentView
        let end = Double(scrollView.documentView?.frame.height ?? 0) + Double(clip.contentInsets.bottom) - Double(clip.bounds.height)
        return max(0, end - Double(clip.bounds.origin.y))
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
}
