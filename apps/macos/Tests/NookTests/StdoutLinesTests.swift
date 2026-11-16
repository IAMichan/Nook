import XCTest

/// How an agent's stdout becomes lines (`StdoutLines`), with the cap on one line.
final class StdoutLinesTests: XCTestCase {
    func testLinesAcrossChunks() {
        var lines = StdoutLines()
        let first = lines.take(Data("{\"a\":1}\n{\"b\"".utf8))
        XCTAssertEqual(first.lines, ["{\"a\":1}"])
        XCTAssertEqual(first.consumed, 8)
        let second = lines.take(Data(":2}\n\n".utf8))
        XCTAssertEqual(second.lines, ["{\"b\":2}"])
        XCTAssertEqual(second.consumed, 9, "the blank line counts as done with")
        XCTAssertNil(lines.remainder())
    }

    func testTheLastLineWithoutANewline() {
        var lines = StdoutLines()
        _ = lines.take(Data("done".utf8))
        XCTAssertEqual(lines.remainder(), "done")
        XCTAssertNil(lines.remainder())
    }

    /// A line past the cap is skipped up to its newline, never held whole; the lines after it come through, and every
    /// skipped byte counts as done with, so a kept agent's offset stays right.
    func testALineTooLongIsSkippedToItsEnd() {
        var lines = StdoutLines(maxLine: 8)
        var total = 0
        let a = lines.take(Data("ok\n0123456789".utf8))
        XCTAssertEqual(a.lines, ["ok"])
        XCTAssertEqual(lines.dropped, 1)
        total += a.consumed
        let b = lines.take(Data("still the long line".utf8))
        XCTAssertEqual(b.lines, [])
        total += b.consumed
        let c = lines.take(Data(" end\nnext\n".utf8))
        XCTAssertEqual(c.lines, ["next"])
        total += c.consumed
        XCTAssertEqual(total, "ok\n0123456789still the long line end\nnext\n".utf8.count)
        XCTAssertEqual(lines.dropped, 1)
    }

    func testARemainderBeingSkippedIsNotALine() {
        var lines = StdoutLines(maxLine: 4)
        _ = lines.take(Data("0123456789".utf8))
        XCTAssertNil(lines.remainder())
    }
}
