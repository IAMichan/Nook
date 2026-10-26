import XCTest

final class KeepAwakePolicyTests: XCTestCase {
    private func decide(_ mode: KeepAwakePolicy.Mode, busy: Bool = false, phone: Bool = false, power: Bool = true,
                        battery: Int? = nil) -> KeepAwakePolicy.Decision {
        KeepAwakePolicy.decide(mode: mode, busy: busy, phoneConnected: phone, onPower: power, battery: battery)
    }

    func testOffHoldsNothing() {
        XCTAssertEqual(decide(.off, busy: true, phone: true), .none)
    }

    func testWhileWorkingFollowsWorkAndThePhone() {
        XCTAssertEqual(decide(.whileWorking), .none)
        XCTAssertEqual(decide(.whileWorking, busy: true), .init(hold: .system, reason: .working))
        XCTAssertEqual(decide(.whileWorking, phone: true), .init(hold: .system, reason: .phone))
    }

    func testAlwaysOnPowerEvenWhenIdle() {
        XCTAssertEqual(decide(.always), .init(hold: .system, reason: .always))
    }

    func testBatteryOnlyForWorkAndNeverWhenLow() {
        XCTAssertEqual(decide(.always, power: false, battery: 80), .none, "an idle Mac on battery may sleep")
        XCTAssertEqual(decide(.always, busy: true, power: false, battery: 80), .init(hold: .idle, reason: .working))
        XCTAssertEqual(decide(.whileWorking, phone: true, power: false, battery: 50), .init(hold: .idle, reason: .phone))
        XCTAssertEqual(decide(.whileWorking, busy: true, power: false, battery: 10), .none)
    }

    func testBusySessions() {
        XCTAssertTrue(KeepAwakePolicy.isBusy(attention: "working", waiting: false))
        XCTAssertTrue(KeepAwakePolicy.isBusy(attention: "approval", waiting: false))
        XCTAssertTrue(KeepAwakePolicy.isBusy(attention: "idle", waiting: true))
        XCTAssertFalse(KeepAwakePolicy.isBusy(attention: "finished", waiting: false))
    }
}
