import XCTest

final class SidePanelCoreTests: XCTestCase {
    // MARK: Artifact kinds

    func testKindsByExtension() {
        XCTAssertEqual(ArtifactKind.detect(path: "/x/index.HTML"), .html)
        XCTAssertEqual(ArtifactKind.detect(path: "logo.svg"), .svg)
        XCTAssertEqual(ArtifactKind.detect(path: "flow.mmd"), .mermaid)
        XCTAssertEqual(ArtifactKind.detect(path: "README.md"), .markdown)
        XCTAssertEqual(ArtifactKind.detect(path: "run.ipynb"), .notebook)
        XCTAssertEqual(ArtifactKind.detect(path: "shot.png"), .image)
        XCTAssertEqual(ArtifactKind.detect(path: "paper.pdf"), .pdf)
        XCTAssertEqual(ArtifactKind.detect(path: "main.swift"), .code)
        XCTAssertEqual(ArtifactKind.detect(path: "Makefile"), .code)
    }

    func testOnlyOwnPagesOpenOnTheirPreview() {
        XCTAssertFalse(ArtifactKind.html.opensOnPreview(ownPage: false), "a project's own html file opens on its code")
        XCTAssertTrue(ArtifactKind.html.opensOnPreview(ownPage: true))
        XCTAssertTrue(ArtifactKind.image.opensOnPreview(ownPage: false))
        XCTAssertFalse(ArtifactKind.code.opensOnPreview(ownPage: false))
        XCTAssertFalse(ArtifactKind.code.hasPreview)
        XCTAssertFalse(ArtifactKind.pdf.isText)
    }

    func testSvgIsCenteredInAPage() {
        let page = ArtifactKind.svg.sandboxPage(for: "<svg/>")
        XCTAssertTrue(page.contains("<svg/>"))
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertEqual(ArtifactKind.html.sandboxPage(for: "<p>x</p>"), "<p>x</p>")
    }

    // MARK: Versions

    func testRecordingSkipsAnUnchangedText() {
        var history = ArtifactHistory()
        XCTAssertTrue(history.record("a"))
        XCTAssertFalse(history.record("a"))
        XCTAssertTrue(history.record("b"))
        XCTAssertEqual(history.versions.map(\.number), [1, 2])
        XCTAssertEqual(history.previous(of: 2)?.text, "a")
        XCTAssertNil(history.previous(of: 1))
        XCTAssertEqual(history.latest?.text, "b")
    }

    func testOldestVersionsGoFirst() {
        var history = ArtifactHistory()
        for index in 0..<(ArtifactHistory.limit + 5) { history.record("text \(index)") }
        XCTAssertEqual(history.versions.count, ArtifactHistory.limit)
        XCTAssertEqual(history.versions.first?.number, 6)
        XCTAssertEqual(history.latest?.number, ArtifactHistory.limit + 5)
    }

    func testCountsOfAChange() {
        let counts = ArtifactHistory.counts(from: "a\nb\nc\n", to: "a\nB\nc\nd\n")
        XCTAssertEqual(counts.added, 2)
        XCTAssertEqual(counts.removed, 1)
    }

    func testUnifiedDiffOfAChange() {
        let diff = ArtifactHistory.unifiedDiff(from: "a\nb\nc\n", to: "a\nB\nc\n", name: "page.html")
        XCTAssertEqual(diff, """
        diff --git a/page.html b/page.html
        --- a/page.html
        +++ b/page.html
        @@ -1,3 +1,3 @@
         a
        -b
        +B
         c

        """)
        XCTAssertEqual(ArtifactHistory.unifiedDiff(from: "same\n", to: "same\n", name: "x"), "")
    }

    func testUnifiedDiffRowsAreReadByTheDiffViewer() {
        let diff = ArtifactHistory.unifiedDiff(from: "a\nb\n", to: "a\nb\nc\n", name: "x.txt")
        let kinds = UnifiedDiff.rows(diff).map(\.kind)
        XCTAssertEqual(kinds, [.hunk, .context, .context, .add])
    }

    func testFarApartChangesAreTwoHunks() {
        let old = (1...30).map(String.init).joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(of: "\n2\n", with: "\ntwo\n").replacingOccurrences(of: "\n29\n", with: "\ntwenty-nine\n")
        let diff = ArtifactHistory.unifiedDiff(from: old, to: new, name: "n.txt")
        XCTAssertEqual(diff.components(separatedBy: "\n").count(where: { $0.hasPrefix("@@") }), 2)
    }

    // MARK: Hunks

    private let twoHunks = """
    diff --git a/f.txt b/f.txt
    index 1..2 100644
    --- a/f.txt
    +++ b/f.txt
    @@ -1,3 +1,3 @@
     a
    -b
    +B
     c
    @@ -20,2 +20,3 @@
     t
    +u
     v

    """

    func testAHunkBecomesItsOwnPatch() {
        let patch = HunkPatch(diff: twoHunks)
        XCTAssertEqual(patch.count, 2)
        XCTAssertEqual(patch.header.count, 4)
        let second = patch.patch(hunk: 1)
        XCTAssertEqual(second, """
        diff --git a/f.txt b/f.txt
        index 1..2 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -20,2 +20,3 @@
         t
        +u
         v

        """)
        XCTAssertNil(patch.patch(hunk: 2))
    }

    func testOnlyTheFirstFileIsRead() {
        let other = twoHunks + "diff --git a/g.txt b/g.txt\n--- a/g.txt\n+++ b/g.txt\n@@ -1 +1 @@\n-x\n+y\n"
        XCTAssertEqual(HunkPatch(diff: other).count, 2)
    }

    func testABinaryDiffHasNoHunks() {
        XCTAssertEqual(HunkPatch(diff: "diff --git a/i.png b/i.png\nBinary files differ\n").count, 0)
    }

    func testApplyArguments() {
        XCTAssertEqual(HunkPatch.arguments(for: .accept, patchPath: "/p")[0...1], ["apply", "--cached"])
        XCTAssertTrue(HunkPatch.arguments(for: .reject, patchPath: "/p").contains("--reverse"))
    }

    // MARK: Tab order

    func testDraggingATabOntoAnother() {
        let tabs = ["a", "b", "c", "d"]
        XCTAssertEqual(SidePanelTabOrder.moving(tabs, moved: "a", onto: "c", pinned: []), ["b", "c", "a", "d"])
        XCTAssertEqual(SidePanelTabOrder.moving(tabs, moved: "d", onto: "b", pinned: []), ["a", "d", "b", "c"])
        XCTAssertEqual(SidePanelTabOrder.moving(tabs, moved: "a", onto: "a", pinned: []), tabs)
    }

    func testPinnedTabsStayInFront() {
        let tabs = ["a", "b", "c"]
        XCTAssertEqual(SidePanelTabOrder.moving(tabs, moved: "c", onto: "a", pinned: ["a", "b"]), tabs)
        XCTAssertEqual(SidePanelTabOrder.moving(tabs, moved: "a", onto: "b", pinned: ["a", "b"]), ["b", "a", "c"])
        XCTAssertEqual(SidePanelTabOrder.pinnedFirst(["a", "b", "c"], pinned: ["c"]), ["c", "a", "b"])
    }

    func testPinningMovesATabBesideThePinned() {
        let pinned = SidePanelTabOrder.toggling("c", in: ["a", "b", "c"], pinned: ["a"])
        XCTAssertEqual(pinned.tabs, ["a", "c", "b"])
        XCTAssertEqual(pinned.pinned, ["a", "c"])
        let unpinned = SidePanelTabOrder.toggling("a", in: pinned.tabs, pinned: pinned.pinned)
        XCTAssertEqual(unpinned.tabs, ["c", "a", "b"])
        XCTAssertEqual(unpinned.pinned, ["c"])
    }
}
