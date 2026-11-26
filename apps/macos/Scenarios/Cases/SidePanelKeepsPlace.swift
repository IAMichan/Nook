import AppKit
import Foundation
import OSLog

/// Opening, closing and dragging the side panel beside a long agent conversation: every row gets narrower or wider at
/// once and is laid out again. At its end the conversation stays at its end; read back, what you read stays where it
/// is on screen; and the blank-conversation guard never steps in (it used to take the rows' reflow for a blank view
/// and scrolled the conversation up to its last row and back down).
final class SidePanelKeepsPlace: Scenario {
    func testSidePanelKeepsPlace() throws {
        try scenario("Opening and dragging the side panel moves nothing in the conversation") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let prompts = (1...24).map { "Prompt number \($0) of the long session" }
            let long = try nook.session(project: project, title: "Long session", messages: prompts, recording: "long-turns")
            try nook.open(long)
            try expect(screen.text(prompts[23])).toBeVisible()
            screen.settle(1.0)

            guard let scrollView = Self.conversation(in: screen.window?.contentView) else {
                throw ScenarioFailure.couldNotRun("the conversation's scroll view was not found")
            }
            let model = nook.app.viewModel
            let started = Date()
            var problems: [String] = []

            // At the end: open, drag wider and narrower, close. It stays at its end each time.
            for step in 0..<8 {
                switch step {
                case 0, 7: model.toggleSidePanel()
                default: model.setSessionPanelWidth(Double(380 + (step % 3) * 90), for: model.selectedAgentID)
                }
                screen.settle(0.8)
                let away = Self.fromEnd(scrollView)
                log("end step \(step): \(Int(away)) pt from the end")
                if away > 2 { problems.append("at the end, step \(step) left the view \(Int(away)) pt from its end") }
            }
            try app.screenshot("at-end")

            // Read back, well above the end, with wheel steps: moving the clip view alone is no scroll of yours, and
            // the conversation would go straight back to its end.
            let wheel = Wheel(window: screen.window, scrollView: scrollView)
            defer { wheel.finish() }
            for _ in 0..<50 { wheel.step(deltaY: 30) }
            screen.settle(1.0)
            for step in 0..<8 {
                guard let (prompt, before) = Self.topPrompt(prompts, screen) else {
                    throw ScenarioFailure.couldNotRun("no prompt in view while reading back")
                }
                switch step {
                case 0, 7: model.toggleSidePanel()
                default: model.setSessionPanelWidth(Double(380 + (step % 3) * 90), for: model.selectedAgentID)
                }
                screen.settle(0.8)
                let after = Self.bubble(prompt, screen).map { $0.minY }
                let moved = after.map { abs($0 - before) } ?? .infinity
                log("reading step \(step): \"\(prompt)\" moved \(moved.isFinite ? String(Int(moved)) : "out of view") pt, "
                    + "\(Int(Self.fromEnd(scrollView))) pt from the end")
                if moved > 40 { problems.append("reading back, step \(step) moved what you read by \(moved.isFinite ? "\(Int(moved)) pt" : "out of view")") }
            }
            try app.screenshot("reading")

            let recoveries = try Self.blankRecoveries(since: started)
            if !recoveries.isEmpty { problems.append("the conversation counted as blank \(recoveries.count) time(s); first: \(recoveries[0])") }
            if !problems.isEmpty { throw ScenarioFailure.assertion(problems.joined(separator: "; ")) }
        }
    }

    /// How far the conversation's view stands above its end.
    private static func fromEnd(_ scrollView: NSScrollView) -> Double {
        let clip = scrollView.contentView
        let end = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
        return Double(end - clip.bounds.origin.y)
    }

    /// The prompt in the middle part of the window, with where its bubble stands (screen coordinates: higher is up).
    private static func topPrompt(_ prompts: [String], _ screen: Screen) -> (String, CGFloat)? {
        guard let window = screen.window else { return nil }
        return prompts.compactMap { prompt -> (String, CGFloat)? in
            guard let frame = bubble(prompt, screen), frame.maxY < window.frame.maxY - 120,
                  frame.minY > window.frame.minY + 200 else { return nil }
            return (prompt, frame.minY)
        }
        .max { $0.1 < $1.1 }
    }

    /// Where the message bubble saying `prompt` stands; not the rail's mark for it (a narrow tick on the leading edge).
    private static func bubble(_ prompt: String, _ screen: Screen) -> NSRect? {
        screen.refresh()
        return screen.elements()
            .first { $0.texts.contains(prompt) && $0.frame.width > 120 && screen.isOnScreen($0) }?
            .frame
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

    /// The blank guard's "recovering" lines this process logged since `date`, checked per line (see `ScrollBackStaysPut`).
    private static func blankRecoveries(since date: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        return try store.getEntries(at: store.position(date: date))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= date && $0.subsystem == "nl.imdigital.nook"
                      && $0.composedMessage.contains("Blank conversation, recovering") }
            .map(\.composedMessage)
    }
}
