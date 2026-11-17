import Foundation

/// Another account picked in the composer while the agent works: the timeline says the turn stops for it, the turn stops,
/// the session moves to the other account, and it goes on where it stopped there by itself.
final class SwitchAccountWhileWorking: Scenario {
    func testSwitchAccountWhileWorking() throws {
        try scenario("Another account picked while the agent works stops the turn, switches and goes on") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let session = try nook.session(project: project, title: "Long job", messages: ["Do the long job"],
                                           recording: "slow-work", wait: false)
            let workspace = AppModel.shared.workspace
            try nook.open(session)
            try expect(screen.text("Starting on the long job now").first).toBeVisible()
            guard let before = workspace.run(session.id), before.status.isActive else {
                throw ScenarioFailure.couldNotRun("the first turn was not running")
            }
            try app.screenshot("working")

            let result = workspace.applySelection(session.id, provider: .claude, profileID: "claude-work",
                                                  model: before.model, stopIfBusy: true)
            guard result == .switchAfterStop else {
                throw ScenarioFailure.assertion("picking another account while working came to \(result)")
            }

            // It goes on by itself: a new turn on the other account starts.
            let end = Date().addingTimeInterval(30)
            while !(workspace.timeline(session.id).contains { $0.tool == "resume" }) {
                if Date() > end {
                    let run = workspace.run(session.id)
                    let read = workspace.timeline(session.id).map { "\($0.kind):\($0.tool ?? "")" }
                    throw ScenarioFailure.assertion("the session did not go on after the switch (\(run?.status.rawValue ?? "?"), "
                                                    + "\(run?.profileID ?? "?"), pending \(workspace.pendingSwitches[session.id] != nil)): \(read)")
                }
                ScenarioClock.spin(nanoseconds: 100_000_000)
            }
            guard workspace.run(session.id)?.profileID == "claude-work" else {
                throw ScenarioFailure.assertion("the session is still on \(workspace.run(session.id)?.profileID ?? "?")")
            }
            let events = workspace.timeline(session.id)
            let stopping = events.firstIndex { $0.tool == "switch-stop" }
            // The turn ended (Claude Code's own end of a stopped turn; other agents add a "Stopped." line as well).
            let stopped = events.firstIndex { $0.kind == .result }
            let switched = events.firstIndex { $0.tool == "switch" }
            let resumed = events.firstIndex { $0.tool == "resume" }
            guard let stopping, let stopped, let switched, let resumed,
                  stopping < stopped, stopped < switched, switched < resumed else {
                throw ScenarioFailure.assertion("the timeline reads \(events.map { "\($0.kind):\($0.tool ?? "")" })")
            }
            try expect(screen.text(events[stopping].text).first).toBeVisible()
            try expect(screen.text(events[resumed].text).first).toBeVisible()
            try app.screenshot("switched-and-continued")
        }
    }
}
