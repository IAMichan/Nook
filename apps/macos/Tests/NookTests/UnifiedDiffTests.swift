import XCTest

final class UnifiedDiffTests: XCTestCase {
    func testLineNumbersOnBothSides() {
        let diff = "diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -10,3 +12,4 @@ func run()\n keep\n-gone\n+new\n+newer\n end\n"
        let rows = UnifiedDiff.rows(diff)
        XCTAssertEqual(rows.map(\.kind), [.hunk, .context, .remove, .add, .add, .context])
        XCTAssertEqual(rows.map(\.old), [10, 10, 11, nil, nil, 12])
        XCTAssertEqual(rows.map(\.new), [12, 12, nil, 13, 14, 15])
        XCTAssertEqual(rows[0].text, "func run()")
        XCTAssertEqual(rows[2].text, "gone")
        XCTAssertEqual(rows[3].raw, "+new")
        // Review comments key on the new-side number, as before.
        let lines = Array(diff.components(separatedBy: "\n").dropLast())
        XCTAssertEqual(Array(ReviewComments.newLineNumbers(lines).suffix(5)), rows.suffix(5).map(\.new))
    }

    func testFileRowsOnlyForSeveralFiles() {
        let one = UnifiedDiff.rows("diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-a\n+b")
        XCTAssertFalse(one.contains { $0.kind == .file })
        let two = UnifiedDiff.rows("diff --git a/a.txt b/a.txt\n@@ -1 +1 @@\n-a\n+b\ndiff --git a/c/d.txt b/c/d.txt\nnew file mode 100644\n@@ -0,0 +1 @@\n+d")
        XCTAssertEqual(two.filter { $0.kind == .file }.map(\.text), ["a.txt", "c/d.txt"])
        XCTAssertTrue(two.contains { $0.kind == .note && $0.text == "new file mode 100644" })
        XCTAssertEqual(two.last?.new, 1)
    }

    func testChangedPartOfAnEditedLine() {
        let rows = UnifiedDiff.rows("@@ -1,2 +1,2 @@\n-let total = price * 2\n+let total = price * 3\n\\ No newline at end of file")
        XCTAssertEqual(rows[1].changed, 20..<21)
        XCTAssertEqual(rows[2].changed, 20..<21)
        XCTAssertEqual(rows[3].kind, .note)
        // Lines that share almost nothing are simply replaced.
        XCTAssertEqual(UnifiedDiff.changedRanges("alpha beta gamma", "x").0, nil)
    }

    func testHunkHeader() {
        XCTAssertEqual(UnifiedDiff.hunk("@@ -90,7 +91,8 @@ <section>").old, 90)
        XCTAssertEqual(UnifiedDiff.hunk("@@ -90,7 +91,8 @@ <section>").new, 91)
        XCTAssertEqual(UnifiedDiff.hunk("@@ -1 +1 @@").section, "")
        XCTAssertEqual(UnifiedDiff.hunkLabel("@@ -1 +1 @@ func x"), "@@ -1 +1 @@")
    }
}
