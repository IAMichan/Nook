import XCTest

/// Names as people say or type them.
final class FuzzyTests: XCTestCase {
    private let apps = ["Spotify", "Safari", "Google Chrome", "Rekenmachine", "Visual Studio Code", "Notities", "Notion"]

    func testFindsTheMeantName() {
        XCTAssertEqual(Fuzzy.best("spotify", in: apps), "Spotify")
        XCTAssertEqual(Fuzzy.best("spotfy", in: apps), "Spotify", "one typo")
        XCTAssertEqual(Fuzzy.best("chrome", in: apps), "Google Chrome", "a word of the name")
        XCTAssertEqual(Fuzzy.best("rekenmachien", in: apps), "Rekenmachine", "two typos in a long name")
        XCTAssertEqual(Fuzzy.best("Spotify.app", in: apps), "Spotify")
        XCTAssertEqual(Fuzzy.best("visualstudio code", in: apps), "Visual Studio Code")
    }

    func testDoesNotGuess() {
        XCTAssertNil(Fuzzy.best("Notie", in: apps), "Notities and Notion are both one away")
        XCTAssertNil(Fuzzy.best("Mail", in: apps))
        XCTAssertNil(Fuzzy.best("saf", in: apps), "too short to guess")
    }

    func testDistance() {
        XCTAssertEqual(Fuzzy.distance("kitten", "sitting"), 3)
        XCTAssertEqual(Fuzzy.distance("", "abc"), 3)
    }
}
