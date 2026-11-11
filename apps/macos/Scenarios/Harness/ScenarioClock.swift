import Foundation

/// How a scenario waits: by turning the main run loop, outside of any Swift task.
///
/// Scenarios are synchronous on purpose. The app's own work (its tasks on the main actor, the agent's output, SwiftUI's
/// updates) runs while the run loop turns, and the accessibility tree a scenario reads can turn it too. Inside an async
/// test that nesting ran other main-actor work in the middle of the test's own task and crashed the test process
/// ("freed pointer was not the last allocation"); from plain synchronous code it is ordinary run loop work.
@MainActor
enum ScenarioClock {
    /// Lets the app run for a while.
    static func spin(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.02)))
        }
    }

    static func spin(nanoseconds: UInt64) {
        spin(seconds: Double(nanoseconds) / 1_000_000_000)
    }

    /// Runs async app code (such as `WorkspaceManager.start`) to its end, turning the run loop meanwhile.
    static func run<T>(timeout: TimeInterval = 60, _ work: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task { @MainActor in
            do { result = .success(try await work()) } catch { result = .failure(error) }
        }
        let end = Date().addingTimeInterval(timeout)
        while result == nil {
            if Date() > end { throw ScenarioFailure.couldNotRun("the app did not answer within \(Int(timeout)) s") }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return try result!.get()
    }
}
