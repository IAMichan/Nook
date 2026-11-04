import XCTest

final class DiffDisplayTests: XCTestCase {
    // MARK: Test files

    func testTestFilesByFolder() {
        XCTAssertTrue(DiffFileFilter.isTest("test/helpers.js"))
        XCTAssertTrue(DiffFileFilter.isTest("pkg/tests/fixtures.py"))
        XCTAssertTrue(DiffFileFilter.isTest("apps/macos/Tests/NookTests/GitServiceTests.swift"))
        XCTAssertTrue(DiffFileFilter.isTest("src/__tests__/Button.tsx"))
    }

    func testTestFilesByName() {
        XCTAssertTrue(DiffFileFilter.isTest("Sources/App/AppTests.swift"))
        XCTAssertTrue(DiffFileFilter.isTest("internal/server_test.go"))
        XCTAssertTrue(DiffFileFilter.isTest("src/button.test.ts"))
        XCTAssertTrue(DiffFileFilter.isTest("src/button.spec.js"))
    }

    func testOrdinaryFilesAreNoTests() {
        XCTAssertFalse(DiffFileFilter.isTest("src/latest/news.swift"))
        XCTAssertFalse(DiffFileFilter.isTest("src/testing.swift"), "a name that only starts with test")
        XCTAssertFalse(DiffFileFilter.isTest("contest/entry.ts"))
        XCTAssertFalse(DiffFileFilter.isTest("README.md"))
        XCTAssertFalse(DiffFileFilter.isTest("test"), "a file named test at the root is no folder")
    }

    // MARK: Whitespace-only hunks

    private let twoHunks = """
    diff --git a/a.swift b/a.swift
    index 1..2 100644
    --- a/a.swift
    +++ b/a.swift
    @@ -1,3 +1,3 @@
     func a() {
    -  return 1
    +    return 1
     }
    @@ -10,2 +10,2 @@
    -let x = 1
    +let x = 2
    """

    func testDropsAHunkThatOnlyChangesIndentation() {
        let filtered = UnifiedDiffFilter.droppingWhitespaceOnlyHunks(twoHunks)
        XCTAssertFalse(filtered.contains("@@ -1,3 +1,3 @@"))
        XCTAssertTrue(filtered.contains("@@ -10,2 +10,2 @@"))
        XCTAssertTrue(filtered.contains("+let x = 2"))
        XCTAssertTrue(filtered.hasPrefix("diff --git a/a.swift b/a.swift"))
    }

    func testDropsAFileWhoseEveryHunkIsWhitespace() {
        let diff = """
        diff --git a/a.swift b/a.swift
        @@ -1 +1 @@
        -let a = 1\u{20}\u{20}
        +let a = 1
        diff --git a/b.swift b/b.swift
        @@ -1 +1 @@
        -let b = 1
        +let b = 2
        """
        let filtered = UnifiedDiffFilter.droppingWhitespaceOnlyHunks(diff)
        XCTAssertFalse(filtered.contains("a.swift"))
        XCTAssertTrue(filtered.contains("b.swift"))
    }

    func testALineSplitInTwoIsWhitespace() {
        XCTAssertTrue(UnifiedDiffFilter.isWhitespaceOnly(["@@ -1 +1,2 @@", "-call(a, b)", "+call(a,", "+     b)"]))
        XCTAssertFalse(UnifiedDiffFilter.isWhitespaceOnly(["@@ -1 +1 @@", "-call(a)", "+call(b)"]))
        XCTAssertFalse(UnifiedDiffFilter.isWhitespaceOnly(["@@ -1 +1 @@", " context only"]), "nothing changed is no whitespace change")
    }

    func testKeepsADiffWithoutHunks() {
        let binary = "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ"
        XCTAssertEqual(UnifiedDiffFilter.droppingWhitespaceOnlyHunks(binary), binary)
        XCTAssertEqual(UnifiedDiffFilter.droppingWhitespaceOnlyHunks(""), "")
    }

    // MARK: Side by side

    func testSplitPairsRemovedWithAddedLines() {
        let rows = UnifiedDiff.rows("""
        @@ -1,4 +1,4 @@
         one
        -two
        -three
        +TWO
         four
        +five
        """)
        let lines = SplitDiff.lines(rows)
        XCTAssertEqual(lines.first, SplitDiff.Line(full: 0))
        XCTAssertEqual(lines[1], SplitDiff.Line(left: 1, right: 1))
        // "two" faces "TWO", "three" faces nothing.
        XCTAssertEqual(lines[2], SplitDiff.Line(left: 2, right: 4))
        XCTAssertEqual(lines[3], SplitDiff.Line(left: 3, right: nil))
        XCTAssertEqual(lines[4], SplitDiff.Line(left: 5, right: 5))
        XCTAssertEqual(lines[5], SplitDiff.Line(left: nil, right: 6))
        XCTAssertEqual(lines.count, 6)
    }

    // MARK: Find

    func testFindCountsEveryOccurrenceInCodeLines() {
        let rows = UnifiedDiff.rows("""
        @@ -1,2 +1,2 @@ func find
        -let find = find()
        +let Find = other()
         // nothing
        """)
        let matches = DiffFind.matches("find", in: [(path: "a.swift", rows: rows)])
        // The hunk's own words are not searched; case does not count.
        XCTAssertEqual(matches, [
            DiffFind.Match(path: "a.swift", row: 1, occurrence: 0),
            DiffFind.Match(path: "a.swift", row: 1, occurrence: 1),
            DiffFind.Match(path: "a.swift", row: 2, occurrence: 0),
        ])
    }

    func testFindGoesThroughFilesInOrder() {
        let a = UnifiedDiff.rows("@@ -1 +1 @@\n-x\n+needle")
        let b = UnifiedDiff.rows("@@ -1 +1 @@\n-needle\n+y")
        let matches = DiffFind.matches("  needle ", in: [(path: "b", rows: b), (path: "a", rows: a)])
        XCTAssertEqual(matches.map(\.path), ["b", "a"])
        XCTAssertTrue(DiffFind.matches("   ", in: [(path: "a", rows: a)]).isEmpty)
    }

    func testOccurrencesDoNotOverlap() {
        XCTAssertEqual(DiffFind.occurrences(of: "aa", in: "aaaa"), 2)
        XCTAssertEqual(DiffFind.occurrences(of: "é", in: "Cafe café"), 2, "diacritics do not count")
        XCTAssertEqual(DiffFind.occurrences(of: "x", in: ""), 0)
    }

    func testFindStateStepsAroundAndKeepsTheSelectedMatch() {
        let first = DiffFind.Match(path: "a", row: 1, occurrence: 0)
        let second = DiffFind.Match(path: "b", row: 3, occurrence: 0)
        var state = DiffFindState()
        state.update([first, second])
        XCTAssertEqual(state.state, .results)
        XCTAssertEqual(state.currentMatch, first)
        state.step(forward: true)
        XCTAssertEqual(state.currentMatch, second)
        state.step(forward: true)
        XCTAssertEqual(state.currentMatch, first, "wraps around")
        state.step(forward: false)
        XCTAssertEqual(state.currentMatch, second)
        // Searching again keeps the match you were on.
        state.update([DiffFind.Match(path: "0", row: 0, occurrence: 0), first, second])
        XCTAssertEqual(state.currentMatch, second)
        state.update([])
        XCTAssertEqual(state.state, .noResults)
        XCTAssertNil(state.currentMatch)
    }

    func testCacheKeyTellsWhitespaceApart() {
        XCTAssertNotEqual(DiffReadOptions(ignoreWhitespace: true).cacheKey(scope: "s", path: "p"),
                          DiffReadOptions.standard.cacheKey(scope: "s", path: "p"))
    }

    // MARK: Commits

    func testParseLog() {
        let text = "abc123\u{1f}p1 p2\u{1f}Fix the thing\u{1f}Ann\u{1f}1700000000\u{1e}\n"
            + "def456\u{1f}\u{1f}First commit\u{1f}Bob\u{1f}1600000000\u{1e}\n"
        let commits = GitService.parseLog(text)
        XCTAssertEqual(commits.map(\.id), ["abc123", "def456"])
        XCTAssertEqual(commits[0].parent, "p1")
        XCTAssertEqual(commits[0].subject, "Fix the thing")
        XCTAssertEqual(commits[0].author, "Ann")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertNil(commits[1].parent, "the first commit has no parent")
        XCTAssertEqual(commits[0].shortID, "abc123")
    }
}

final class ScratchProjectsTests: XCTestCase {
    private let id = UUID(uuidString: "A1B2C3D4-0000-0000-0000-000000000000")!
    private let date = Date(timeIntervalSince1970: 1_793_750_400) // 2026-11-04 00:00 UTC
    private let utc = TimeZone(identifier: "UTC")!

    func testFolderName() {
        XCTAssertEqual(ScratchProjects.folderName(date: date, prompt: "Fix the login bug in Safari!\nMore words", id: id, timeZone: utc),
                       "2026-11-04-fix-the-login-bug-in-safari-a1b2c3")
        XCTAssertEqual(ScratchProjects.folderName(date: date, prompt: "  ", id: id, timeZone: utc), "2026-11-04-untitled-a1b2c3")
    }

    func testSlugIsShort() {
        XCTAssertLessThanOrEqual(ScratchProjects.slug(String(repeating: "word ", count: 40)).count, 32)
        XCTAssertEqual(ScratchProjects.slug("Één café"), "een-cafe")
        XCTAssertEqual(ScratchProjects.slug("???"), ScratchProjects.untitled)
    }

    func testIsScratch() {
        let root = URL(fileURLWithPath: "/Users/me/.nook/scratch")
        XCTAssertTrue(ScratchProjects.isScratch("/Users/me/.nook/scratch/2026-11-04-x-a1b2c3", root: root))
        XCTAssertTrue(ScratchProjects.isScratch("/Users/me/.nook/scratch/2026-11-04-x-a1b2c3/", root: root))
        XCTAssertFalse(ScratchProjects.isScratch("/Users/me/.nook/scratch/a/b", root: root))
        XCTAssertFalse(ScratchProjects.isScratch("/Users/me/code/app", root: root))
        XCTAssertFalse(ScratchProjects.isScratch("", root: root))
    }

    func testRenamedName() {
        XCTAssertEqual(ScratchProjects.renamedName("/r/2026-11-04-untitled-a1b2c3", prompt: "Write a poem"),
                       "2026-11-04-write-a-poem-a1b2c3")
        XCTAssertNil(ScratchProjects.renamedName("/r/2026-11-04-write-a-poem-a1b2c3", prompt: "Write a poem"))
        XCTAssertNil(ScratchProjects.renamedName("/r/short", prompt: "Write a poem"))
    }

    func testCreateRenameAndDiscard() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scratch-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let made = try ScratchProjects.create(prompt: "", date: date, id: id, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: made))
        // Empty: it takes the prompt's name.
        let renamed = ScratchProjects.rename(made, prompt: "Plan a trip", root: root)
        XCTAssertTrue(renamed.hasSuffix("-plan-a-trip-a1b2c3"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made))
        // Something in it: it keeps its name, and is not discarded.
        try "x".write(toFile: renamed + "/notes.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(ScratchProjects.rename(renamed, prompt: "Other words", root: root), renamed)
        ScratchProjects.discardIfEmpty(renamed, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed))
        // An empty one goes.
        let empty = try ScratchProjects.create(prompt: "x", date: date, id: UUID(), root: root)
        ScratchProjects.discardIfEmpty(empty, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty))
    }
}
