import XCTest

/// Dragging the open notch's sides and bottom corners: how big it gets, and that it never gets unusable.
final class NotchResizeTests: XCTestCase {
    private let maximum = CGSize(width: 1240, height: 860)

    func testExtraIsAddedToTheTabsOwnSize() {
        let size = NotchResize.size(base: CGSize(width: 860, height: 480), extra: CGSize(width: 120, height: 60), maximum: maximum)
        XCTAssertEqual(size, CGSize(width: 980, height: 540))
    }

    func testNeverSmallerThanTheMinimumNorLargerThanTheRoom() {
        let base = CGSize(width: 860, height: 480)
        XCTAssertEqual(NotchResize.size(base: base, extra: CGSize(width: -900, height: -900), maximum: maximum), NotchResize.minimum)
        XCTAssertEqual(NotchResize.size(base: base, extra: CGSize(width: 900, height: 900), maximum: maximum), maximum)
    }

    func testATabOutsideTheLimitsKeepsItsOwnSize() {
        // The shelf starts smaller than the minimum; a sheet can start at the full height.
        let small = CGSize(width: 640, height: 250)
        XCTAssertEqual(NotchResize.size(base: small, extra: .zero, maximum: maximum), small)
        let tall = CGSize(width: 1040, height: 900)
        XCTAssertEqual(NotchResize.size(base: tall, extra: .zero, maximum: maximum), tall)
    }

    func testASideMovesBothSidesSoTheEdgeFollowsThePointer() {
        let start = CGSize(width: 40, height: 10)
        XCTAssertEqual(NotchResize.dragged(.right, from: start, translation: CGSize(width: 15, height: 30)), CGSize(width: 70, height: 10))
        XCTAssertEqual(NotchResize.dragged(.left, from: start, translation: CGSize(width: 15, height: 0)), CGSize(width: 10, height: 10),
                       "the left side dragged to the right makes it narrower")
        XCTAssertEqual(NotchResize.dragged(.bottom, from: start, translation: CGSize(width: 50, height: 25)), CGSize(width: 40, height: 35))
        XCTAssertEqual(NotchResize.dragged(.bottomLeft, from: start, translation: CGSize(width: -10, height: 20)), CGSize(width: 60, height: 30))
    }

    func testClampedExtraRespondsAtOnceWhenDraggedBack() {
        let base = CGSize(width: 860, height: 480)
        let extra = NotchResize.clamped(CGSize(width: 5000, height: -5000), base: base, maximum: maximum)
        XCTAssertEqual(extra, CGSize(width: maximum.width - base.width, height: NotchResize.minimum.height - base.height))
    }

    func testRemembered() {
        let defaults = UserDefaults(suiteName: "NotchResizeTests")!
        defaults.removePersistentDomain(forName: "NotchResizeTests")
        XCTAssertEqual(NotchResize.load(defaults), .zero)
        NotchResize.save(CGSize(width: 120, height: -40), defaults)
        XCTAssertEqual(NotchResize.load(defaults), CGSize(width: 120, height: -40))
    }
}
