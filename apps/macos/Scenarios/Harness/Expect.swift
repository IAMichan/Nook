import Foundation

/// Why a scenario stopped. Only `assertion` shows the behavior under test is broken; `couldNotRun` says the scenario
/// itself did not get there (an element to press was missing, setup failed, a guard refused something).
enum ScenarioFailure: Error, CustomStringConvertible {
    case assertion(String)
    case couldNotRun(String)

    var message: String {
        switch self {
        case .assertion(let message), .couldNotRun(let message): return message
        }
    }

    var code: String {
        switch self {
        case .assertion: return "ASSERTION_FAILED"
        case .couldNotRun: return "COULD_NOT_RUN"
        }
    }

    var description: String { "\(code): \(message)" }
}

/// `expect(locator)`: waits for the screen to show what the scenario says, up to a timeout.
@MainActor
struct Expectation {
    let locator: Locator

    /// The element is on screen within `timeout` seconds.
    func toBeVisible(timeout: TimeInterval = 15) throws {
        try wait("toBeVisible", timeout: timeout, failure: "\(locator.description) is not visible") {
            locator.resolve() != nil
        }
    }

    /// The element is gone (or was never there) within `timeout` seconds.
    func toBeHidden(timeout: TimeInterval = 15) throws {
        try wait("toBeHidden", timeout: timeout, failure: "\(locator.description) is still visible") {
            locator.resolve() == nil
        }
    }

    /// Exactly `count` matching elements are on screen within `timeout` seconds.
    func toHaveCount(_ count: Int, timeout: TimeInterval = 15) throws {
        try wait("toHaveCount \(count)", timeout: timeout, failure: "\(locator.description) is not on screen \(count) times") {
            locator.count() == count
        }
    }

    private func wait(_ name: String, timeout: TimeInterval, failure: String, _ holds: @escaping @MainActor () -> Bool) throws {
        let screen = locator.screen
        try screen.scenario.step("expect", "\(locator.description) \(name)") {
            let end = Date().addingTimeInterval(timeout)
            while true {
                screen.refresh()
                if holds() { return }
                if Date() > end { throw ScenarioFailure.assertion("\(failure) after \(Int(timeout)) s") }
                ScenarioClock.spin(nanoseconds: 100_000_000)
            }
        }
    }
}

@MainActor
func expect(_ locator: Locator) -> Expectation {
    Expectation(locator: locator)
}
