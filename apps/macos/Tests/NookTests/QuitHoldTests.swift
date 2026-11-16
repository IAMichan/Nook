import XCTest

/// Hold ⌘Q to quit, timed without real key events: what a quick tap, a hold with key repeat, a hold with key repeat off,
/// and a let-go without a key-up each do.
final class QuitHoldTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testAQuickTapShowsTheHintAndNeverQuits() {
        var hold = QuitHold()
        let press = hold.handle(.pressed, at: at(0))
        XCTAssertEqual(press.hint, .hold)
        XCTAssertFalse(press.quit)
        XCTAssertEqual(press.checkAt, at(QuitHold.holdDuration))
        let release = hold.handle(.released, at: at(0.15))
        XCTAssertEqual(release.hint, .hidden)
        XCTAssertFalse(release.quit)
        XCTAssertTrue(hold.isIdle)
        // The check that was asked for comes anyway: nothing happens.
        XCTAssertEqual(hold.handle(.check(keyDown: false), at: at(1)), QuitHold.Output())
    }

    func testHoldingWithKeyRepeatQuitsOnRelease() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        // macOS repeats after its delay, then every 0.083 s.
        var time = 0.5
        var output = QuitHold.Output()
        while time < QuitHold.holdDuration {
            output = hold.handle(.repeated, at: at(time))
            XCTAssertFalse(output.quit)
            XCTAssertNil(output.hint, "still the hold hint at \(time)")
            time += 0.083
        }
        output = hold.handle(.repeated, at: at(time))
        XCTAssertEqual(output.hint, .release, "held long enough")
        XCTAssertFalse(output.quit, "never while the key is still down: its repeats would reach the next app")
        // More repeats while it is still down: still waiting.
        XCTAssertFalse(hold.handle(.repeated, at: at(time + 0.083)).quit)
        XCTAssertTrue(hold.handle(.released, at: at(time + 0.1)).quit)
        XCTAssertTrue(hold.isIdle)
    }

    func testReleasedWithoutAKeyUpQuitsAfterTheQuietPeriod() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        _ = hold.handle(.repeated, at: at(0.5))
        let armed = hold.handle(.repeated, at: at(1.05))
        XCTAssertEqual(armed.hint, .release)
        let quiet = QuitHold.quietPeriod(cadence: 0.55)
        XCTAssertEqual(quiet, 1.1, accuracy: 0.001, "a slow repeat waits two of its intervals")
        // macOS sent no key-up for Q while ⌘ was down. Too early: wait on.
        let early = hold.handle(.check(keyDown: nil), at: at(1.5))
        XCTAssertFalse(early.quit)
        XCTAssertEqual(try XCTUnwrap(early.checkAt).timeIntervalSince(at(1.05)), quiet, accuracy: 0.001)
        XCTAssertTrue(hold.handle(.check(keyDown: false), at: at(1.05 + quiet)).quit)
    }

    func testHoldingWithKeyRepeatOffIsProvenByTheKeyState() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        // No repeats at all: at the deadline the key is still down.
        let armed = hold.handle(.check(keyDown: true), at: at(QuitHold.holdDuration))
        XCTAssertEqual(armed.hint, .release)
        XCTAssertFalse(armed.quit)
        // Still held a long while later: no quit while it is down.
        let still = hold.handle(.check(keyDown: true), at: at(5))
        XCTAssertFalse(still.quit)
        XCTAssertNotNil(still.checkAt)
        XCTAssertTrue(hold.handle(.check(keyDown: false), at: at(6)).quit)
    }

    func testLetGoBeforeTheDeadlineWithoutAKeyUpDoesNotQuit() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        let check = hold.handle(.check(keyDown: false), at: at(QuitHold.holdDuration))
        XCTAssertEqual(check.hint, .hidden)
        XCTAssertFalse(check.quit)
        XCTAssertTrue(hold.isIdle)
        // Without the key state and without repeats there is no proof of a hold either.
        _ = hold.handle(.pressed, at: at(10))
        XCTAssertFalse(hold.handle(.check(keyDown: nil), at: at(11)).quit)
        XCTAssertTrue(hold.isIdle)
    }

    func testAnEarlyCheckAsksAgainAtTheDeadline() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        let early = hold.handle(.check(keyDown: true), at: at(0.4))
        XCTAssertFalse(early.quit)
        XCTAssertNil(early.hint)
        XCTAssertEqual(early.checkAt, at(QuitHold.holdDuration))
    }

    func testAnotherKeyCancelsAHoldButNotAnArmedOne() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        XCTAssertEqual(hold.handle(.otherKey, at: at(0.3)).hint, .hidden)
        XCTAssertTrue(hold.isIdle)

        _ = hold.handle(.pressed, at: at(5))
        _ = hold.handle(.check(keyDown: true), at: at(6))
        XCTAssertFalse(hold.handle(.otherKey, at: at(6.1)).quit)
        XCTAssertFalse(hold.isIdle)
        XCTAssertTrue(hold.handle(.released, at: at(6.2)).quit)
    }

    func testAFreshPressStartsTheHoldOver() {
        var hold = QuitHold()
        _ = hold.handle(.pressed, at: at(0))
        // Its key-up never came; a new press a while later times from itself.
        let again = hold.handle(.pressed, at: at(3))
        XCTAssertEqual(again.checkAt, at(3 + QuitHold.holdDuration))
        XCTAssertNil(hold.handle(.repeated, at: at(3.5)).hint)
        XCTAssertFalse(hold.handle(.released, at: at(3.6)).quit)
    }

    func testRepeatsAndReleasesWhileIdleDoNothing() {
        var hold = QuitHold()
        XCTAssertEqual(hold.handle(.repeated, at: at(0)), QuitHold.Output())
        XCTAssertEqual(hold.handle(.released, at: at(0)), QuitHold.Output())
        XCTAssertEqual(hold.handle(.otherKey, at: at(0)), QuitHold.Output())
        XCTAssertTrue(hold.isIdle)
    }
}
