import XCTest

/// With the notch off, Double Tap opens on the screen of the window you work in: which screen that is.
final class ScreenPickTests: XCTestCase {
    /// A laptop with a taller display to its right, bottoms aligned, and one above it.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let display = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    private let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
    private var screens: [CGRect] { [laptop, display, above] }

    func testAWindowOnTheLaptopPicksTheLaptop() {
        // Accessibility y runs down from the top of the primary screen: 100 points below its top.
        XCTAssertEqual(ScreenPick.screen(showing: CGRect(x: 200, y: 100, width: 800, height: 600), in: screens), laptop)
    }

    func testAWindowOnTheDisplayPicksTheDisplay() {
        // The display reaches 458 points above the laptop's top: a negative accessibility y.
        XCTAssertEqual(ScreenPick.screen(showing: CGRect(x: 2000, y: -300, width: 1000, height: 800), in: screens), display)
    }

    func testAWindowOnTheScreenAbovePicksThatScreen() {
        XCTAssertEqual(ScreenPick.screen(showing: CGRect(x: 100, y: -900, width: 800, height: 600), in: screens), above)
    }

    func testAWindowAcrossTwoScreensPicksTheOneShowingMostOfIt() {
        XCTAssertEqual(ScreenPick.screen(showing: CGRect(x: 1312, y: 100, width: 1000, height: 600), in: screens), display)
        XCTAssertEqual(ScreenPick.screen(showing: CGRect(x: 812, y: 100, width: 1000, height: 600), in: screens), laptop)
    }

    func testAWindowOffEveryScreenPicksNone() {
        XCTAssertNil(ScreenPick.screen(showing: CGRect(x: -5000, y: 100, width: 800, height: 600), in: screens))
        XCTAssertNil(ScreenPick.screen(showing: CGRect(x: 0, y: 0, width: 10, height: 10), in: []))
    }
}
