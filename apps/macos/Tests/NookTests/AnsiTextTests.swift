import XCTest

final class AnsiTextTests: XCTestCase {
    func testPlainTextIsOneSpan() {
        XCTAssertEqual(AnsiText.spans("hello"), [AnsiText.Span(text: "hello")])
        XCTAssertEqual(AnsiText.spans(""), [])
    }

    func testColorsAndReset() {
        let spans = AnsiText.spans("\u{1B}[31mFAIL\u{1B}[0m ok \u{1B}[1;32mPASS\u{1B}[39m done")
        XCTAssertEqual(spans, [
            AnsiText.Span(text: "FAIL", color: .palette(1)),
            AnsiText.Span(text: " ok "),
            AnsiText.Span(text: "PASS", color: .palette(2), bold: true),
            AnsiText.Span(text: " done", bold: true),
        ])
    }

    func testBrightExtendedAndRGB() {
        XCTAssertEqual(AnsiText.spans("\u{1B}[91mx").first?.color, .palette(9))
        XCTAssertEqual(AnsiText.spans("\u{1B}[38;5;208mx").first?.color, .palette(208))
        XCTAssertEqual(AnsiText.spans("\u{1B}[38;2;10;20;30mx").first?.color, .rgb(10, 20, 30))
        // A background with its arguments does not turn into a foreground color.
        XCTAssertNil(AnsiText.spans("\u{1B}[48;5;31mx").first?.color)
    }

    func testOtherCodesAndProgressBarsGo() {
        XCTAssertEqual(AnsiText.plain("\u{1B}[2K\u{1B}[1Gloading 10%\rloading 100%\ndone"), "loading 100%\ndone")
        XCTAssertEqual(AnsiText.plain("\u{1B}]0;title\u{07}text"), "text")
        XCTAssertEqual(AnsiText.plain("a\r\nb"), "a\nb")
    }
}
