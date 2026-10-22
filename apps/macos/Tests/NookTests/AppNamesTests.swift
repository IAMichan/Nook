import XCTest

/// Apps by any name they go by, on a Mac in any language.
final class AppNamesTests: XCTestCase {
    /// A Dutch Mac: apps show their Dutch names, their bundles on disk keep the English ones.
    private let dutch: [AppNames.Candidate] = [
        .init(names: AppNames.names(shown: "Systeeminstellingen", bundlePath: "/System/Applications/System Settings.app",
                                    plistNames: ["System Settings", nil]), bundleID: "com.apple.systempreferences"),
        .init(names: AppNames.names(shown: "Bedieningspaneel", bundlePath: "/System/Library/CoreServices/ControlCenter.app",
                                    plistNames: ["ControlCenter"]), bundleID: "com.apple.controlcenter"),
        .init(names: AppNames.names(shown: "Agenda", bundlePath: "/System/Applications/Calendar.app", plistNames: []),
              bundleID: "com.apple.iCal"),
        .init(names: ["Safari"], bundleID: "com.apple.Safari"),
        .init(names: ["Spotify"], bundleID: "com.spotify.client")
    ]

    func testFindsAnAppByItsEnglishNameOnALocalizedMac() {
        XCTAssertEqual(AppNames.index(of: "System Settings", in: dutch), 0, "the name on disk")
        XCTAssertEqual(AppNames.index(of: "Systeeminstellingen", in: dutch), 0, "the shown name")
        XCTAssertEqual(AppNames.index(of: "System Preferences", in: dutch), 0, "the name before Ventura")
        XCTAssertEqual(AppNames.index(of: "Control Center", in: dutch), 1)
        XCTAssertEqual(AppNames.index(of: "bedieningspaneel", in: dutch), 1)
        XCTAssertEqual(AppNames.index(of: "Calendar", in: dutch), 2)
        XCTAssertEqual(AppNames.index(of: "Agenda", in: dutch), 2)
        XCTAssertEqual(AppNames.index(of: "com.apple.Safari", in: dutch), 3, "a bundle identifier")
        XCTAssertEqual(AppNames.index(of: "spotfy", in: dutch), 4, "a typo")
    }

    func testDoesNotGuess() {
        XCTAssertNil(AppNames.index(of: "", in: dutch))
        XCTAssertNil(AppNames.index(of: "Mail", in: dutch))
        XCTAssertNil(AppNames.index(of: "Control Center", in: [.init(names: ["Safari"], bundleID: "com.apple.Safari")]))
    }

    func testNamesLeaveOutEmptyOnesAndRepeats() {
        XCTAssertEqual(AppNames.names(shown: "Safari", bundlePath: "/Applications/Safari.app", plistNames: ["safari", "", nil]),
                       ["Safari"])
    }
}
