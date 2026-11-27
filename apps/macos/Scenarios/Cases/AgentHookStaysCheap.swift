import AppKit
import Foundation

/// An agent in a terminal that works while you read a session in the main window costs the main thread little: each
/// hook event it sends (a step, a reply) redraws the views that show that agent, not every view of the app. The agent hub
/// used to pass each change on to `AppModel`, and every view holding `AppModel` drew again: 150-500 ms of the main
/// thread per event in a Debug build, a stutter you felt in whatever you were doing.
final class AgentHookStaysCheap: Scenario {
    /// Main thread time per hook event, beyond what the same wait costs without one, at most: a share of the main
    /// thread time it took to open the session in the same run, so the budget holds on a fast Mac and a slow runner alike.
    static let perEventShare = 0.05
    static let events = 20

    func testAgentHookStaysCheap() throws {
        try scenario("A terminal agent's hook events do not redraw the whole app") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math {}\n"])
            let session = try nook.session(project: project, title: "Short tour", messages: ["Give me a short tour"])
            let openStart = Self.mainThreadSeconds()
            try nook.open(session)
            try expect(screen.text("Give me a short tour").first).toBeVisible()
            screen.settle(1.0)
            let openCPU = Self.mainThreadSeconds() - openStart
            self.log(String(format: "opening the session: %.0f ms main thread", openCPU * 1000))

            // An agent in a terminal, as its hooks report it.
            let hub = nook.app.hub
            let terminal = AgentSession(id: "scenario-terminal", name: "Claude Code", project: "demo", status: .running,
                                        file: "Sources/Math.swift", placeholder: "", steps: [], diff: [],
                                        cwd: project.path, started: Date(), turnStarted: Date())
            hub.sessions.append(terminal)
            screen.settle(1.0)

            // The same waits without an event: what the harness itself costs.
            let idleStart = Self.mainThreadSeconds()
            for _ in 0..<Self.events { screen.settle(0.3) }
            let idleCPU = Self.mainThreadSeconds() - idleStart

            let eventsStart = Self.mainThreadSeconds()
            for step in 0..<Self.events {
                guard let index = hub.sessions.firstIndex(where: { $0.id == terminal.id }) else {
                    throw ScenarioFailure.couldNotRun("the terminal agent left the hub")
                }
                hub.sessions[index].steps.append(AgentStep(mark: .running, text: "Reading part \(step)"))
                hub.sessions[index].lastReply = "Looked at part \(step)"
                screen.settle(0.3)
            }
            let eventsCPU = Self.mainThreadSeconds() - eventsStart
            let perEvent = max(0, eventsCPU - idleCPU) / Double(Self.events)
            self.log(String(format: "%d hook events: %.0f ms main thread, %.0f ms without them, %.1f ms per event",
                            Self.events, eventsCPU * 1000, idleCPU * 1000, perEvent * 1000))
            try expect(screen.text("Give me a short tour").first).toBeVisible()
            try app.screenshot("after-events")

            let budget = openCPU * Self.perEventShare
            if perEvent > budget {
                throw ScenarioFailure.assertion(String(format: "each hook event cost the main thread %.1f ms (budget %.1f ms, %.0f%% of opening the session)",
                                                       perEvent * 1000, budget * 1000, Self.perEventShare * 100))
            }
        }
    }

    /// CPU time the main thread (this test's thread) used so far.
    private static func mainThreadSeconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }
}
