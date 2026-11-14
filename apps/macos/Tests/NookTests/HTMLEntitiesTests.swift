import XCTest

final class HTMLEntitiesTests: XCTestCase {
    func testDecodesNamedAndNumericReferences() {
        XCTAssertEqual(HTMLEntities.decode("Tom &amp; Jerry &lt;3 &quot;hi&quot; &#39;x&#39; caf&#233; caf&#xE9; a&nbsp;b"),
                       "Tom & Jerry <3 \"hi\" 'x' café café a b")
        XCTAssertEqual(HTMLEntities.decode("Fix &mdash; done&hellip;"), "Fix — done…")
    }

    /// Each reference is decoded once: an escaped one is meant as text.
    func testAnEscapedReferenceStaysText() {
        XCTAssertEqual(HTMLEntities.decode("&amp;lt;b&amp;gt;"), "&lt;b&gt;")
        XCTAssertEqual(HTMLEntities.decode("&amp;quot;"), "&quot;")
        XCTAssertEqual(HTMLEntities.decode("&amp;#233;"), "&#233;")
    }

    func testLeavesUnknownAndBrokenReferencesAlone() {
        XCTAssertEqual(HTMLEntities.decode("R&D &bogus; &#xZZ; & ;"), "R&D &bogus; &#xZZ; & ;")
        XCTAssertEqual(HTMLEntities.decode("no references"), "no references")
        XCTAssertEqual(HTMLEntities.decode("&#1114112;"), "&#1114112;", "past the last code point")
    }
}
