import AppKit
import Foundation

/// A long session in which the agent read, ran and edited a lot (thousands of calls) stays smooth: a new call costs the
/// main thread little while you watch it work, and opening a finished turn's "Worked for …" does not hang the window.
/// It used to read the whole session again for every call (its pull request links above all), and opening one fold
/// drew every block of the conversation again.
final class LongWorkStaysSmooth: Scenario {
    /// Main thread time per event while the session is open and the agent works, at most (a Debug build).
    static let perEventBudget = 0.004
    /// Main thread time to open a finished turn's fold and draw it, at most.
    static let foldBudget = 0.35

    func testLongWorkStaysSmooth() throws {
        try scenario("A long session of heavy work streams and opens its folds without stalling") { nook, screen, app in
            let project = try nook.project("demo", files: ["Sources/Math.swift": "enum Math { static func sum(a: Int) -> Int { a + 1 } }\n"])
            let prompts = (1...12).map { "Check and fix part \($0) of the project" }
            let session = try nook.session(project: project, title: "Heavy work", messages: prompts, recording: "heavy-work")
            try nook.open(session)
            try expect(screen.text(prompts[11])).toBeVisible()
            screen.settle(1.0)
            let workspace = nook.app.workspace
            let before = workspace.timeline(session.id).count

            // One more turn of 160 calls while you watch it.
            let streamStart = Self.mainThreadSeconds()
            try nook.send(session, "Check and fix the last part", wait: true)
            let streamCPU = Self.mainThreadSeconds() - streamStart
            let added = max(1, workspace.timeline(session.id).count - before)
            let perEvent = streamCPU / Double(added)
            self.log(String(format: "streamed %d events over %d: %.0f ms main thread, %.2f ms per event",
                                     added, before, streamCPU * 1000, perEvent * 1000))
            try expect(screen.text("Every part builds and its tests pass").first).toBeVisible()
            screen.settle(1.0)

            // Open the last finished turn's work.
            let fold = screen.button("Worked for", exact: false).first
            let foldStart = Self.mainThreadSeconds()
            try fold.tap()
            let pressCPU = Self.mainThreadSeconds() - foldStart
            screen.settle(1.0)
            let foldCPU = Self.mainThreadSeconds() - foldStart
            self.log(String(format: "opening a fold: %.0f ms main thread (%.0f ms of it until it showed)", foldCPU * 1000, pressCPU * 1000))
            try expect(screen.text("Now checking part 15 of the work").first).toBeVisible()
            try app.screenshot("fold-open")

            if perEvent > Self.perEventBudget {
                throw ScenarioFailure.assertion(String(format: "each new event cost the main thread %.1f ms (budget %.0f ms)",
                                                       perEvent * 1000, Self.perEventBudget * 1000))
            }
            if foldCPU > Self.foldBudget {
                throw ScenarioFailure.assertion(String(format: "opening a fold cost the main thread %.0f ms (budget %.0f ms)",
                                                       foldCPU * 1000, Self.foldBudget * 1000))
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
