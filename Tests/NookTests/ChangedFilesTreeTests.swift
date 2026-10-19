import XCTest

final class ChangedFilesTreeTests: XCTestCase {
    typealias S = ChangedFilesTree.FileStat

    func testEmpty() {
        let t = ChangedFilesTree.build([])
        XCTAssertTrue(t.isEmpty)
        XCTAssertEqual(t.totals, ChangedFilesTree.Stats())
        XCTAssertEqual(t.flatten(expanded: t.expandAll), [])
    }

    func testSingleChildChainsCollapseAndAggregate() {
        let t = ChangedFilesTree.build([
            S(path: "src/app/a.swift", added: 3, removed: 1),
            S(path: "src/app/b.swift", added: 2, removed: 0),
            S(path: "README.md", added: 1, removed: 1),
        ])
        let rows = t.flatten(expanded: t.expandAll)
        XCTAssertEqual(rows.map(\.name), ["src/app", "a.swift", "b.swift", "README.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 1, 0])
        XCTAssertEqual(rows[0].path, "src/app")
        XCTAssertEqual(rows[0].stats.added, 5)
        XCTAssertEqual(rows[0].stats.removed, 1)
        XCTAssertEqual(t.totals.added, 6)
        XCTAssertEqual(t.totals.fileCount, 3)
    }

    func testDirectoriesFirstThenCaseInsensitive() {
        let t = ChangedFilesTree.build([
            S(path: "b.txt", added: 1, removed: 0), S(path: "Alpha.txt", added: 1, removed: 0),
            S(path: "z/x.txt", added: 1, removed: 0), S(path: "y/x.txt", added: 1, removed: 0),
        ])
        XCTAssertEqual(t.flatten(expanded: []).map(\.name), ["y", "z", "Alpha.txt", "b.txt"])
    }

    func testExpandCollapse() {
        let t = ChangedFilesTree.build([S(path: "a/b.txt", added: 1, removed: 0), S(path: "a/c/d.txt", added: 1, removed: 0)])
        XCTAssertEqual(t.flatten(expanded: t.collapseAll).map(\.path), ["a"])
        XCTAssertEqual(t.flatten(expanded: ["a"]).map(\.path), ["a", "a/c", "a/b.txt"])
        XCTAssertEqual(t.expandAll, ["a", "a/c"])
        XCTAssertEqual(t.flatten(expanded: t.expandAll).count, 4)
    }

    func testBinaryHasNoNumbers() {
        let t = ChangedFilesTree.build([S(path: "img/logo.png", added: nil, removed: nil, kind: .added)])
        let rows = t.flatten(expanded: t.expandAll)
        XCTAssertFalse(rows.last!.stats.hasNumbers)
        XCTAssertFalse(t.totals.hasNumbers)
        let mixed = ChangedFilesTree.build([S(path: "a.png", added: nil, removed: nil), S(path: "b.txt", added: 1, removed: 0)])
        XCTAssertTrue(mixed.totals.hasNumbers)
    }

    func testRenamedAndDeepPaths() {
        let t = ChangedFilesTree.build([S(path: "a/b/c/d/e/new.swift", added: 0, removed: 0, kind: .renamed(from: "old.swift"))])
        let rows = t.flatten(expanded: t.expandAll)
        XCTAssertEqual(rows.map(\.name), ["a/b/c/d/e", "new.swift"])
        XCTAssertEqual(rows[1].kind, .renamed(from: "old.swift"))
        XCTAssertEqual(rows[1].id, "a/b/c/d/e/new.swift")
    }

    func testIDsAreStableAcrossRebuilds() {
        let input = [S(path: "x/y.txt", added: 1, removed: 0)]
        XCTAssertEqual(ChangedFilesTree.build(input), ChangedFilesTree.build(input))
    }
}
