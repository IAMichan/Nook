import XCTest

/// How much Nook does by himself (`EnergyPolicy`): what the Mac's signals and your choice in Settings › General › Energy
/// mean for the background work. All of it pure: the signals come from the test.
final class EnergyPolicyTests: XCTestCase {
    func testAQuietMacOnTheChargerRunsAtFullSpeed() {
        let plan = EnergyPolicy.plan(for: EnergySignals(), mode: .automatic)
        XCTAssertEqual(plan, .fullSpeed)
        XCTAssertEqual(plan.slowdown, 1)
        XCTAssertTrue(plan.readsScreen && plan.thinksAlong)
        XCTAssertEqual(plan.thinkAlongGap, 0)
        XCTAssertNil(plan.mainReason)
    }

    func testTheBatteryMakesTheWorkLighterNotPaused() {
        let plan = EnergyPolicy.plan(for: EnergySignals(onBattery: true), mode: .automatic)
        XCTAssertEqual(plan.pace, .light)
        XCTAssertEqual(plan.reasons, [.battery])
        XCTAssertEqual(plan.slowdown, 2)
        XCTAssertTrue(plan.readsScreen, "the screen is still read, less often")
        XCTAssertEqual(plan.thinkAlongGap, 600)
    }

    func testAHotBusyOrSavingMacPausesTheOptionalWork() {
        for signals in [EnergySignals(lowPowerMode: true), EnergySignals(hot: true), EnergySignals(busy: true)] {
            let plan = EnergyPolicy.plan(for: signals, mode: .automatic)
            XCTAssertEqual(plan.pace, .paused, "\(signals)")
            XCTAssertFalse(plan.readsScreen || plan.thinksAlong)
            XCTAssertEqual(plan.slowdown, 6)
            XCTAssertEqual(plan.thinkAlongGap, .infinity)
        }
    }

    func testAwayAndASleepingDisplayPauseEverythingOptional() {
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(away: true), mode: .full).pace, .paused)
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(displayAsleep: true), mode: .full).pace, .paused)
    }

    func testTheReasonsNameTheStrongestFirst() {
        let plan = EnergyPolicy.plan(for: EnergySignals(hot: true, onBattery: true, displayAsleep: true), mode: .automatic)
        XCTAssertEqual(plan.reasons, [.displayAsleep, .hot, .battery])
        XCTAssertEqual(plan.mainReason, .displayAsleep)
    }

    func testSaverIsAlwaysAtLeastLight() {
        let plan = EnergyPolicy.plan(for: EnergySignals(), mode: .saver)
        XCTAssertEqual(plan.pace, .light)
        XCTAssertEqual(plan.reasons, [.saver])
        // On battery the battery comes first: it is the reason you would expect to see.
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(onBattery: true), mode: .saver).reasons, [.battery, .saver])
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(busy: true), mode: .saver).pace, .paused)
    }

    func testFullPowerIgnoresTheBatteryAndABusyMacButNotHeat() {
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(onBattery: true), mode: .full), .fullSpeed)
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(busy: true), mode: .full), .fullSpeed)
        XCTAssertEqual(EnergyPolicy.plan(for: EnergySignals(hot: true), mode: .full).pace, .paused)
        // Low Power Mode is your own request to macOS: full power still takes it easy for it.
        let lowPower = EnergyPolicy.plan(for: EnergySignals(lowPowerMode: true), mode: .full)
        XCTAssertEqual(lowPower.pace, .light)
        XCTAssertEqual(lowPower.reasons, [.lowPowerMode])
    }

    func testEveryReasonHasAText() {
        // The keys exist in the texts (I18nCoverageTests checks the languages); here only that each reason maps to one.
        XCTAssertEqual(Set(EnergyReason.allCases.map(\.textKey)).count, EnergyReason.allCases.count)
        XCTAssertEqual(EnergyMode.allCases.map(\.rawValue), ["automatic", "saver", "full"])
    }
}
