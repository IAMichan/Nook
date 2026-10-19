import XCTest

final class PromptLinkTests: XCTestCase {
    private func parse(_ s: String) -> PromptLink? { URL(string: s).flatMap(PromptLink.parse) }

    func testParsesAllParameters() {
        let link = parse("nook://prompt?text=Fix%20the%20build&project=nook&agent=Claude&model=opus-4.1")
        XCTAssertEqual(link?.text, "Fix the build")
        XCTAssertEqual(link?.project, "nook")
        XCTAssertEqual(link?.agent, "claude")
        XCTAssertEqual(link?.model, "opus-4.1")
        XCTAssertEqual(link?.warnings, [])
    }

    func testTextOnlyAndUnknownParamsIgnored() {
        let link = parse("nook://prompt?text=hi&run=true&permission=bypass&branch=x")
        XCTAssertEqual(link, PromptLink(text: "hi"))
    }

    func testRejectsWrongSchemeHostOrMissingText() {
        XCTAssertNil(parse("https://prompt?text=hi"))
        XCTAssertNil(parse("nook://other?text=hi"))
        XCTAssertNil(parse("nook://prompt"))
        XCTAssertNil(parse("nook://prompt?text="))
        XCTAssertNil(parse("nook://prompt?text=%20%0A%20"))
    }

    func testLengthLimit() {
        XCTAssertNotNil(parse("nook://prompt?text=" + String(repeating: "a", count: 8_000)))
        XCTAssertNil(parse("nook://prompt?text=" + String(repeating: "a", count: 8_001)))
    }

    func testStripsControlAndHiddenCharacters() {
        let link = parse("nook://prompt?text=a%00b%1Bc%E2%80%8Bd%F3%A0%80%81e%C2%ADf%0Ag")
        XCTAssertEqual(link?.text, "abcdef\ng")
        XCTAssertEqual(link?.warnings, [.strippedHiddenCharacters])
        XCTAssertEqual(parse("nook://prompt?text=plain")?.warnings, [])
    }

    func testNewlinesAndCarriageReturnsNormalised() {
        XCTAssertEqual(parse("nook://prompt?text=a%0D%0Ab%0Dc")?.text, "a\nb\nc")
    }

    func testHostileProjectIsDroppedNotTrusted() {
        for bad in ["../secret", "a/../b", "..", "/etc/../passwd", "a%5Cb", "x%00y", String(repeating: "a", count: 513)] {
            let link = parse("nook://prompt?text=hi&project=\(bad)")
            XCTAssertNotNil(link, bad)
            XCTAssertNil(link?.project, bad)
            XCTAssertEqual(link?.warnings, [.droppedProject], bad)
        }
        XCTAssertEqual(parse("nook://prompt?text=hi&project=~/Code/my%20app")?.project, "~/Code/my app")
        XCTAssertEqual(parse("nook://prompt?text=hi&project=a..b")?.project, "a..b", "dots inside a name are fine")
    }

    func testAgentAndModelValidated() {
        let link = parse("nook://prompt?text=hi&agent=a%20b%3Bc&model=%24(rm)")
        XCTAssertNil(link?.agent)
        XCTAssertNil(link?.model)
        XCTAssertEqual(link?.warnings, [.droppedAgent, .droppedModel])
    }

    func testFirstDuplicateWins() {
        XCTAssertEqual(parse("nook://prompt?text=one&text=two")?.text, "one")
    }

    func testPlusIsLiteral() {
        XCTAssertEqual(parse("nook://prompt?text=a+b")?.text, "a+b")
    }

    func testBuildRoundTripsUnicodeAndSymbols() {
        let text = "Fix: 日本語 & emoji 🎉\nline 2 + 100% \"quoted\" #hash ?q=1"
        let url = PromptLink.build(text: text, project: "my project", agent: "codex", model: "gpt-5.5")
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.allSatisfy { $0.isASCII })
        let back = PromptLink.parse(url: url!)
        XCTAssertEqual(back, PromptLink(text: text, project: "my project", agent: "codex", model: "gpt-5.5"))
    }

    func testBuildRefusesEmptyOrOverlong() {
        XCTAssertNil(PromptLink.build(text: "  \n "))
        XCTAssertNil(PromptLink.build(text: String(repeating: "a", count: 8_001)))
        XCTAssertNil(PromptLink.build(text: "\u{200B}"))
    }

    func testBuildSkipsInvalidOptionalParts() {
        let url = PromptLink.build(text: "hi", project: "../x", agent: "bad agent", model: nil)
        XCTAssertEqual(url?.absoluteString, "nook://prompt?text=hi")
    }
}
