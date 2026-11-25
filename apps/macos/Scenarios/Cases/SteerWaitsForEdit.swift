import Foundation

/// A message sent with ⌘Return while the agent writes a file: it shows at once as sent but not taken in yet, reaches the
/// agent only once the file is written (a steer never cuts a change off halfway), and then reads as steered.
final class SteerWaitsForEdit: Scenario {
    func testSteerWaitsForEdit() throws {
        try scenario("A steer sent while the agent writes a file waits until the file is written") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let session = try nook.session(project: project, title: "New module", messages: ["Add a shapes module"],
                                           recording: "slow-edit", wait: false)
            let workspace = AppModel.shared.workspace
            try nook.open(session)
            try expect(screen.text("Writing the new module now").first).toBeVisible()

            // Wait until the Write call runs.
            let end = Date().addingTimeInterval(20)
            while !(workspace.timeline(session.id).contains { $0.kind == .tool && $0.tool == "Write" && $0.state == .running }) {
                if Date() > end { throw ScenarioFailure.couldNotRun("the Write call never started") }
                ScenarioClock.spin(nanoseconds: 50_000_000)
            }

            // ⌘Return in the composer while it works (`AgentRunPanel.composer`: `sendNow`).
            let steer = "Also add a circle"
            guard workspace.sendNow(session.id, text: steer) else {
                throw ScenarioFailure.couldNotRun("the steer did not go out")
            }
            try expect(screen.text(steer).first).toBeVisible()
            try expect(screen.text(tr("agents.message.steerWaiting")).first).toBeVisible()
            try app.screenshot("steer-waiting")

            // It reaches the agent, and only after the file was written.
            let received = nook.paths.replayState.appendingPathComponent("received.log")
            let arrived = Date().addingTimeInterval(20)
            var line: String?
            while line == nil {
                let text = (try? String(contentsOf: received, encoding: .utf8)) ?? ""
                line = text.split(separator: "\n").map(String.init).first { $0.hasSuffix("text=" + steer) }
                if line == nil, Date() > arrived { throw ScenarioFailure.couldNotRun("the steer never reached the agent") }
                if line == nil { ScenarioClock.spin(nanoseconds: 50_000_000) }
            }
            guard line?.contains("during=-") == true else {
                throw ScenarioFailure.assertion("the steer reached the agent while it wrote the file: \(line ?? "")")
            }

            // Taken in now: the bubble reads as a steer, no longer waiting.
            try expect(screen.text(tr("agents.message.steerWaiting"))).toBeHidden()
            try app.screenshot("steer-taken-in")
        }
    }
}
