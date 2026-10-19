import XCTest

final class NookLookTests: XCTestCase {
    func testStoredLookRoundTrips() {
        for preset in NookLook.presets {
            XCTAssertEqual(NookLook(stored: preset.look.stored), preset.look)
        }
        let custom = NookLook(eyes: .dots, mouth: .expressive, gloss: true, glow: false, cheeks: true)
        XCTAssertEqual(NookLook(stored: custom.stored), custom)
    }

    func testMissingOrBrokenValueFallsBackToClassic() {
        XCTAssertEqual(NookLook(stored: nil), .classic)
        XCTAssertEqual(NookLook(stored: ""), .classic)
        XCTAssertEqual(NookLook(stored: "not json"), .classic)
    }

    func testUnknownOptionKeepsTheOthers() {
        let look = NookLook(stored: #"{"eyes":"stars","mouth":"line","gloss":false}"#)
        XCTAssertEqual(look.eyes, NookLook.classic.eyes)
        XCTAssertEqual(look.mouth, .line)
        XCTAssertFalse(look.gloss)
        XCTAssertEqual(look.glow, NookLook.classic.glow)
    }

    func testVisemesFollowTheLetters() {
        XCTAssertEqual(NookViseme("a"), .open)
        XCTAssertEqual(NookViseme("É"), .wide)
        XCTAssertEqual(NookViseme("o"), .round)
        XCTAssertEqual(NookViseme("m"), .closed)
        XCTAssertEqual(NookViseme("v"), .teeth)
        XCTAssertEqual(NookViseme("k"), .consonant)
        XCTAssertEqual(NookViseme(" "), .rest)
        XCTAssertEqual(NookViseme("!"), .rest)
    }

    func testVisemeDuringAWord() {
        XCTAssertEqual(NookViseme.during("mama", elapsed: 0), .closed)
        XCTAssertEqual(NookViseme.during("mama", elapsed: 0.08), .open)
        XCTAssertNil(NookViseme.during("mama", elapsed: 1))
        XCTAssertNil(NookViseme.during("mama", elapsed: -0.1))
    }
}
