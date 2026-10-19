import XCTest

final class TimelineHandlesTests: XCTestCase {
    func testSpillThreshold() {
        XCTAssertFalse(OutputSpill.shouldSpill(output: String(repeating: "a", count: 16_000)))
        XCTAssertTrue(OutputSpill.shouldSpill(output: String(repeating: "a", count: 16_001)))
        XCTAssertTrue(OutputSpill.shouldSpill(output: "abcdef", limit: 5))
        XCTAssertFalse(OutputSpill.shouldSpill(output: ""))
    }

    func testHandle() {
        let big = String(repeating: "é", count: 5_000)
        let h = OutputSpill.makeHandle(id: "o1", output: big)
        XCTAssertEqual(h.byteCount, 10_000)
        XCTAssertEqual(h.previewHead.count, 2_000)
        XCTAssertTrue(h.truncatedHead)
        let small = OutputSpill.makeHandle(id: "o2", output: "hi")
        XCTAssertFalse(small.truncatedHead)
        XCTAssertEqual(small.previewHead, "hi")
    }

    func testClipDetail() {
        XCTAssertEqual(OutputSpill.clipDetail("short"), "short")
        let clipped = OutputSpill.clipDetail(String(repeating: "a", count: 40_000))
        XCTAssertEqual(clipped.utf8.count, 32 * 1024 + "\n…".utf8.count)
        // multibyte characters are never cut in half
        let emoji = OutputSpill.clipDetail(String(repeating: "😀", count: 10), limit: 10)
        XCTAssertEqual(emoji, "😀😀\n…")
    }

    func testTitle() {
        XCTAssertEqual(PlanPreview.title(from: "intro\n## The Plan \nbody"), "The Plan")
        XCTAssertNil(PlanPreview.title(from: "no heading"))
        XCTAssertNil(PlanPreview.title(from: "#\n"))
    }

    func testNeedsExpand() {
        XCTAssertFalse(PlanPreview.needsExpand(String(repeating: "a", count: 900)))
        XCTAssertTrue(PlanPreview.needsExpand(String(repeating: "a", count: 901)))
        XCTAssertFalse(PlanPreview.needsExpand(Array(repeating: "l", count: 20).joined(separator: "\n")))
        XCTAssertTrue(PlanPreview.needsExpand(Array(repeating: "l", count: 21).joined(separator: "\n")))
    }

    func testPreview() {
        let text = (1...25).map { "line \($0)" }.joined(separator: "\n")
        let p = PlanPreview.preview(text)
        XCTAssertEqual(p.split(separator: "\n", omittingEmptySubsequences: false).count, 12)
        XCTAssertTrue(p.hasSuffix("line 10\n\n..."))
        XCTAssertEqual(PlanPreview.preview("a\nb"), "a\nb")
        XCTAssertEqual(PlanPreview.preview("a  \n\n\n"), "a")
        XCTAssertEqual(PlanPreview.preview(""), "")
        XCTAssertEqual(PlanPreview.preview(text, lines: 2), "line 1\nline 2\n\n...")
    }

    func testFileName() {
        XCTAssertEqual(PlanPreview.fileName(forTitle: "Add the `Agents` tab, fast!"), "add-the-agents-tab-fast.md")
        XCTAssertEqual(PlanPreview.fileName(forTitle: "  "), "plan.md")
        XCTAssertEqual(PlanPreview.fileName(forTitle: "日本語"), "plan.md")
    }

    func testContextLevels() {
        XCTAssertEqual(ContextMeter.level(0.5), .normal)
        XCTAssertEqual(ContextMeter.level(0.749), .normal)
        XCTAssertEqual(ContextMeter.level(0.75), .warning)
        XCTAssertEqual(ContextMeter.level(0.9), .warning)
        XCTAssertEqual(ContextMeter.level(0.901), .critical)
    }

    func testPercentText() {
        XCTAssertEqual(ContextMeter.percentText(0.042), "4.2%")
        XCTAssertEqual(ContextMeter.percentText(0), "0.0%")
        XCTAssertEqual(ContextMeter.percentText(0.42), "42%")
        XCTAssertEqual(ContextMeter.percentText(0.1), "10%")
        XCTAssertEqual(ContextMeter.percentText(1.5), "100%")
        XCTAssertEqual(ContextMeter.percentText(-1), "0.0%")
    }

    func testTokensText() {
        XCTAssertEqual(ContextMeter.tokensText(used: 84_000, window: 200_000), "84k/200k")
        XCTAssertEqual(ContextMeter.tokensText(used: 850, window: 200_000), "850/200k")
        XCTAssertEqual(ContextMeter.tokensText(used: 500_000, window: 1_000_000), "500k/1m")
        XCTAssertEqual(ContextMeter.tokensText(used: 0, window: 1_500_000), "0/1.5m")
    }
}
