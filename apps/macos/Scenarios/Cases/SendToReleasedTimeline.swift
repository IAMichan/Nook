import Foundation

/// A session whose timeline left memory (released while idle, or not opened since launch) takes a message: the timeline is
/// read back off the main thread, the turn starts once it is here, and nothing of the conversation is lost or doubled.
final class SendToReleasedTimeline: Scenario {
    func testSendToReleasedTimeline() throws {
        try scenario("A message to a session whose timeline left memory reads it back and runs the turn") { nook, screen, app in
            let project = try nook.project("demo", files: [
                "Sources/Math.swift": "enum Math {\n    static func sum(_ a: Int, _ b: Int) -> Int {\n        a + b\n    }\n}\n",
            ])
            let session = try nook.session(project: project, title: "Short tour", messages: ["Give me a short tour"])
            let workspace = AppModel.shared.workspace
            // `evictTimelines` releases only a timeline with nothing left to save: the save after a turn waits 5 s.
            ScenarioClock.spin(nanoseconds: 6_000_000_000)
            let before = workspace.timeline(session.id)
            // Released, as `evictTimelines` releases an idle session's timeline.
            workspace.events[session.id] = nil

            guard workspace.send(session.id, text: "And once more, please") else {
                throw ScenarioFailure.assertion("the session did not take the message")
            }
            // A hidden message (Nook's own summary, a recovery) meanwhile is refused, as while a turn runs, so its caller
            // cleans up; it is not queued behind yours.
            guard workspace.events[session.id] == nil, !workspace.sendHidden(session.id, text: "/compact") else {
                throw ScenarioFailure.assertion("a hidden message was taken while the timeline was read back for yours")
            }
            // The turn starts once the timeline is back: its prompt shows in it then.
            let end = Date().addingTimeInterval(20)
            while (workspace.events[session.id] ?? []).filter({ $0.kind == .user }).count < 2 {
                if Date() > end { throw ScenarioFailure.assertion("the turn did not start after the timeline was read back") }
                ScenarioClock.spin(nanoseconds: 50_000_000)
            }
            try nook.waitForTurn(session)

            let after = workspace.timeline(session.id)
            guard Array(after.prefix(before.count)).map(\.id) == before.map(\.id) else {
                throw ScenarioFailure.assertion("the first turn changed when the timeline was read back")
            }
            guard Set(after.map(\.id)).count == after.count else {
                throw ScenarioFailure.assertion("an event is in the timeline twice")
            }
            let prompts = after.filter { $0.kind == .user }.map(\.text)
            guard prompts == ["Give me a short tour", "And once more, please"] else {
                throw ScenarioFailure.assertion("the prompts read \(prompts)")
            }
            guard (workspace.queued[session.id]?.isEmpty ?? true) else {
                throw ScenarioFailure.assertion("the refused hidden message was queued")
            }
            try nook.open(session)
            try expect(screen.text("And once more, please").first).toBeVisible()
            try app.screenshot("second-turn")

            // A hidden message to a released timeline reads it on the spot, as before: its turn starts at once, or its
            // caller hears false right away.
            ScenarioClock.spin(nanoseconds: 6_000_000_000)
            workspace.events[session.id] = nil
            guard workspace.sendHidden(session.id, text: "Look once more"), workspace.events[session.id] != nil else {
                throw ScenarioFailure.assertion("a hidden message did not read the released timeline at once")
            }
            try nook.waitForTurn(session)
            let shown = workspace.timeline(session.id).filter { $0.kind == .user }.map(\.text)
            guard shown == prompts else { throw ScenarioFailure.assertion("the hidden message shows as \(shown)") }
        }
    }
}
