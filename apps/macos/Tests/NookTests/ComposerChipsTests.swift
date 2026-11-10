import XCTest

final class ComposerChipsTests: XCTestCase {
    private let file = ContextRefs.link(ContextRef(kind: .file, id: "Sources/Login.swift", label: "Login.swift"))
    private let pr = ContextRefs.link(ContextRef(kind: .pullRequest, id: "me/app#12", label: "12"))
    private let mark = String(ComposerChips.mark)

    func testDisplayAndRestingForms() {
        let text = "fix \(file) like \(pr) did"
        XCTAssertEqual(ComposerChips.display(text), "fix \(mark) like \(mark) did")
        XCTAssertEqual(ComposerChips.resting(text), "fix @Login.swift like #12 did")
        XCTAssertEqual(ComposerChips.display("plain words"), "plain words")
        XCTAssertEqual(ComposerChips.markOffsets(in: ComposerChips.display(text)), [4, 11])
    }

    func testTypingAroundAChipKeepsIt() {
        let old = "fix \(file)"
        let edit = ComposerChips.applying(display: "please fix \(mark) now", to: old)
        XCTAssertEqual(edit.text, "please fix \(file) now")
        XCTAssertEqual(edit.removed, [])
        XCTAssertEqual(ComposerChips.applying(display: ComposerChips.display(old), to: old).text, old)
    }

    func testBackspaceTakesTheWholeReference() {
        let old = "see \(file) and \(pr)"
        let edit = ComposerChips.applying(display: "see  and \(mark)", to: old)
        XCTAssertEqual(edit.text, "see  and \(pr)")
        XCTAssertEqual(edit.removed, [file])
    }

    func testCaretDecidesWhichOfTwoNeighboursWent() {
        let old = file + pr
        // Backspace right after the first chip: the caret sits at 0, the second chip stays.
        XCTAssertEqual(ComposerChips.applying(display: mark, to: old, caret: 0).text, pr)
        // Without the caret the common-prefix guess keeps the first one.
        XCTAssertEqual(ComposerChips.applying(display: mark, to: old).text, file)
    }

    func testCutAndPasteMovesAChip() {
        let old = "a \(file) b"
        let cut = ComposerChips.applying(display: "a  b", to: old)
        XCTAssertEqual(cut.removed, [file])
        let pasted = ComposerChips.applying(display: "\(mark)a  b", to: cut.text, spares: cut.removed)
        XCTAssertEqual(pasted.text, "\(file)a  b")
        XCTAssertEqual(pasted.usedSpares, 1)
        // A mark without a spare behind it is dropped.
        XCTAssertEqual(ComposerChips.applying(display: "x\(mark)", to: "x").text, "x")
    }

    func testStrayMarkInDraftIsNotShown() {
        let old = "a\(mark)b \(file)"
        XCTAssertEqual(ComposerChips.display(old), "ab \(mark)")
        XCTAssertEqual(ComposerChips.applying(display: "ab \(mark)!", to: old).text, "ab \(file)!")
    }
}

final class ComposerDictationTests: XCTestCase {
    func testWordsLandAfterTheDraft() {
        var d = ComposerDictation()
        XCTAssertTrue(d.begin(body: "fix this"))
        XCTAssertFalse(d.begin(body: "again"))
        XCTAssertTrue(d.isActive)
        XCTAssertEqual(d.text(with: "and that"), "fix this and that")
        XCTAssertTrue(d.finish())
        XCTAssertFalse(d.finish())
        let landed = d.land(" and that ")
        XCTAssertEqual(landed.text, "fix this and that")
        XCTAssertFalse(landed.send)
        XCTAssertFalse(d.isActive)
    }

    func testSendWhileDictatingSendsOnceTheWordsLand() {
        var d = ComposerDictation()
        XCTAssertFalse(d.requestSend(), "nothing records: send as usual")
        d.begin(body: "")
        XCTAssertTrue(d.requestSend(), "the microphone has to stop")
        XCTAssertEqual(d.phase, .finishing)
        XCTAssertFalse(d.requestSend(), "already stopping")
        let landed = d.land("ship it")
        XCTAssertEqual(landed.text, "ship it")
        XCTAssertTrue(landed.send)
    }

    func testDiscardRestoresTheDraftAndDropsTheSend() {
        var d = ComposerDictation()
        XCTAssertNil(d.discard())
        d.begin(body: "keep me ")
        d.requestSend()
        XCTAssertEqual(d.discard(), "keep me ")
        XCTAssertFalse(d.isActive)
        XCTAssertFalse(d.land("late words").send, "a late result after discarding never sends")
    }

    func testJoin() {
        XCTAssertEqual(ComposerDictation.join("a ", "b"), "a b")
        XCTAssertEqual(ComposerDictation.join("a\n", "b"), "a\nb")
        XCTAssertEqual(ComposerDictation.join("a", "  "), "a")
        XCTAssertEqual(ComposerDictation.join("", " b "), "b")
    }
}
