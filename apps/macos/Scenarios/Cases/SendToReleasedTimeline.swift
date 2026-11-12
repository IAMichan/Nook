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

            try nook.send(session, "And once more, please", wait: false)
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
            try nook.open(session)
            try expect(screen.text("And once more, please").first).toBeVisible()
            try app.screenshot("second-turn")
        }
    }
}
