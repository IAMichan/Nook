import XCTest

final class ComposerCaretTests: XCTestCase {
    private let file = ContextRefs.link(ContextRef(kind: .file, id: "Sources/Login.swift", label: "Login.swift"))
    private let pr = ContextRefs.link(ContextRef(kind: .pullRequest, id: "me/app#12", label: "12"))
    private let mark = String(ComposerChips.mark)

    func testTriggerAtTheCaretInTheMiddle() throws {
        let text = "look at @Lo and more"
        let caret = "look at @Lo".utf16.count
        let trigger = try XCTUnwrap(ComposerTrigger.detect(in: text, caret: caret))
        XCTAssertEqual(trigger.kind, .mention)
        XCTAssertEqual(trigger.query, "Lo")
        XCTAssertEqual(trigger.range, 8..<11)
        let done = trigger.inserting("[Login.swift](x)", in: text)
        XCTAssertEqual(done.text, "look at [Login.swift](x) and more")
        XCTAssertEqual(done.caret, "look at [Login.swift](x) ".utf16.count, "the caret goes past the space that was there")
        // No trigger right before the caret, even with one at the end.
        XCTAssertNil(ComposerTrigger.detect(in: "fix it @Lo", caret: 3))
        // Without a caret, or at the end, the end counts as before.
        XCTAssertEqual(ComposerTrigger.detect(in: "see #1", caret: nil)?.kind, .pullRequest)
        XCTAssertEqual(ComposerTrigger.detect(in: "see #1", caret: 6)?.range, 4..<6)
    }

    func testInsertingBeforeAWordAddsASpaceAndStaleTextIsLeftAlone() throws {
        let text = "@foo"
        let trigger = try XCTUnwrap(ComposerTrigger.detect(in: text + "bar", caret: 4))
        XCTAssertEqual(trigger.inserting("X", in: text + "bar").text, "X bar")
        XCTAssertEqual(trigger.inserting("X", in: text + "bar").caret, 2)
        XCTAssertNil(trigger.inserting("X", in: "changed").caret)
        XCTAssertEqual(trigger.inserting("X", in: "changed").text, "changed")
        // At the end, as before: the insertion and a space.
        let command = try XCTUnwrap(ComposerTrigger.detect(in: "/pl", caret: 3))
        XCTAssertEqual(command.inserting("/plan", in: "/pl").text, "/plan ")
        XCTAssertEqual(command.removing(from: "/pl").text, "")
        let middle = try XCTUnwrap(ComposerTrigger.detect(in: "/pl rest", caret: 3))
        XCTAssertEqual(middle.removing(from: "/pl rest").text, " rest")
        XCTAssertEqual(middle.removing(from: "/pl rest").caret, 0)
    }

    func testDisplayAndDraftOffsetsAroundChips() {
        let draft = "a \(file) b \(pr)"
        // Display: "a ￼ b ￼"
        XCTAssertEqual(ComposerChips.display(draft), "a \(mark) b \(mark)")
        XCTAssertEqual(ComposerChips.draftOffset(display: 0, in: draft), 0)
        XCTAssertEqual(ComposerChips.draftOffset(display: 2, in: draft), 2, "before the chip is before its link")
        XCTAssertEqual(ComposerChips.draftOffset(display: 3, in: draft), 2 + file.utf16.count, "after it, after the link")
        XCTAssertEqual(ComposerChips.draftOffset(display: 7, in: draft), draft.utf16.count)
        XCTAssertEqual(ComposerChips.displayOffset(draft: 2 + file.utf16.count + 3, in: draft), 6)
        XCTAssertEqual(ComposerChips.displayOffset(draft: 5, in: draft), 3, "inside a link counts as after its chip")
        XCTAssertEqual(ComposerChips.draftSlice(display: 2..<5, in: draft), file + " b")
        XCTAssertEqual(ComposerChips.draftRange(display: 0..<1, in: draft), 0..<1)
        // A stray mark in the draft takes no room in the field.
        let stray = "x\(mark)y"
        XCTAssertEqual(ComposerChips.draftOffset(display: 1, in: stray), 1)
        XCTAssertEqual(ComposerChips.draftOffset(display: 2, in: stray), 3)
        XCTAssertEqual(ComposerChips.displayOffset(draft: 3, in: stray), 2)
    }

    func testPastedChipsKeepTheirOrder() {
        let cut = ComposerChips.applying(display: "", to: file + pr)
        XCTAssertEqual(cut.removed, [file, pr])
        let pasted = ComposerChips.applying(display: "\(mark) \(mark)", to: "", spares: ["older"] + cut.removed)
        XCTAssertEqual(pasted.text, "\(file) \(pr)")
        XCTAssertEqual(pasted.usedSpares, 2)
    }
}

final class ComposerClipboardTests: XCTestCase {
    func testReadableMarkdownHasALinkPerChip() {
        let draft = "fix " + ContextRefs.link(ContextRef(kind: .file, id: "Sources/My File.swift", label: "My File.swift"))
            + " like " + ContextRefs.link(ContextRef(kind: .pullRequest, id: "me/app#12", label: "12"))
            + " with " + ContextRefs.link(ContextRef(kind: .skill, id: "lint", label: "lint"))
        XCTAssertEqual(ComposerClipboard.readable(draft),
                       "fix [My File.swift](Sources/My%20File.swift) like [#12](https://github.com/me/app/pull/12) with $lint")
        let id = "6f1c2d3e-0000-4000-8000-000000000001"
        let session = ContextRefs.link(ContextRef(kind: .session, id: id, label: "Login bug"))
        XCTAssertTrue(ComposerClipboard.readable(session).hasPrefix("[Login bug](nook://"), ComposerClipboard.readable(session))
        XCTAssertEqual(ComposerClipboard.readable("plain words"), "plain words")
        XCTAssertFalse(ComposerClipboard.readable(draft).contains("nook-context:"))
    }

    func testAPasteOfTheReadableFormGetsItsChipsBack() throws {
        let draft = "see " + ContextRefs.link(ContextRef(kind: .file, id: "a.swift", label: "a.swift"))
        let readable = ComposerClipboard.readable(draft)
        let text = "hello " + readable + " bye"
        let caret = ("hello " + readable).utf16.count
        let restored = try XCTUnwrap(ComposerClipboard.restoringChips(in: text, caret: caret, readable: readable, draft: draft))
        XCTAssertEqual(restored.text, "hello " + draft + " bye")
        XCTAssertEqual(restored.caret, ("hello " + draft).utf16.count)
        XCTAssertNil(ComposerClipboard.restoringChips(in: text, caret: caret - 1, readable: readable, draft: draft))
        XCTAssertNil(ComposerClipboard.restoringChips(in: "x", caret: 1, readable: "x", draft: "x"), "plain text needs nothing")
    }
}

final class ComposerUndoTests: XCTestCase {
    private let chip = ContextRefs.link(ContextRef(kind: .file, id: "a.swift", label: "a.swift"))

    func testTypingCoalescesAndUndoRedoWalkBack() throws {
        var undo = ComposerUndo()
        undo.record(old: "", new: "h")
        undo.record(old: "h", new: "hi")
        undo.record(old: "hi", new: "hi!")
        XCTAssertEqual(undo.undos, [""], "one run of typing is one step")
        let back = try XCTUnwrap(undo.undo(current: "hi!"))
        XCTAssertEqual(back.text, "")
        XCTAssertEqual(back.caret, 0)
        let again = try XCTUnwrap(undo.redo(current: ""))
        XCTAssertEqual(again.text, "hi!")
        XCTAssertEqual(again.caret, 3)
        XCTAssertFalse(undo.canRedo)
    }

    func testDeletedChipComesBackWhole() throws {
        var undo = ComposerUndo()
        let before = "see \(chip) now"
        let after = "see  now"
        undo.record(old: before, new: after)
        let back = try XCTUnwrap(undo.undo(current: after))
        XCTAssertEqual(back.text, before)
        XCTAssertEqual(back.caret, ("see " + chip).utf16.count, "the caret goes after the chip that came back")
        let forward = try XCTUnwrap(undo.redo(current: before))
        XCTAssertEqual(forward.text, after)
        XCTAssertEqual(forward.caret, 4)
    }

    func testInsertedChipIsItsOwnStepAndANewChangeDropsRedo() throws {
        var undo = ComposerUndo()
        undo.record(old: "", new: "a")
        undo.record(old: "a", new: "a" + chip + " ", separate: true)
        undo.record(old: "a" + chip + " ", new: "a" + chip + " b")
        XCTAssertEqual(undo.undos, ["", "a", "a" + chip + " "])
        XCTAssertEqual(try XCTUnwrap(undo.undo(current: "a" + chip + " b")).text, "a" + chip + " ")
        XCTAssertEqual(try XCTUnwrap(undo.undo(current: "a" + chip + " ")).text, "a")
        undo.record(old: "a", new: "ab")
        XCTAssertFalse(undo.canRedo)
    }

    func testBackspaceRunCoalescesButTypingElsewhereDoesNot() {
        var undo = ComposerUndo()
        undo.record(old: "abcd", new: "abc")
        undo.record(old: "abc", new: "ab")
        XCTAssertEqual(undo.undos, ["abcd"])
        undo.record(old: "ab", new: "Xab")
        undo.record(old: "Xab", new: "Xabc")
        XCTAssertEqual(undo.undos, ["abcd", "ab", "Xab"], "typing in another place starts a new step")
        undo.endRun()
        undo.record(old: "Xabc", new: "Xabcd")
        XCTAssertEqual(undo.undos.count, 4)
    }
}

final class ComposerDictationCaretTests: XCTestCase {
    func testWordsLandAtTheCaretOrInPlaceOfTheSelection() {
        var d = ComposerDictation()
        d.begin(body: "hello world", selection: 5..<5)
        XCTAssertEqual(d.text(with: "big"), "hello big world")
        XCTAssertEqual(d.caret(with: "big"), "hello big".utf16.count)
        let landed = d.land("big")
        XCTAssertEqual(landed.text, "hello big world")
        XCTAssertEqual(landed.caret, 9)

        d.begin(body: "hello world", selection: 6..<11)
        XCTAssertEqual(d.text(with: "there"), "hello there")
        XCTAssertEqual(d.text(with: ""), "hello world", "nothing heard yet leaves the draft")
        XCTAssertEqual(d.discard(), "hello world")

        d.begin(body: "ab", selection: 1..<1)
        XCTAssertEqual(d.text(with: "x"), "a x b")
        _ = d.discard()

        d.begin(body: "end", selection: nil)
        XCTAssertEqual(d.text(with: "more"), "end more", "no caret: at the end, as before")
        _ = d.discard()

        d.begin(body: "end", selection: 2..<9)
        XCTAssertEqual(d.text(with: "x"), "end x", "a stale selection falls back to the end")
    }

    func testPunctuationAfterTheCaretNeedsNoSpace() {
        XCTAssertEqual(ComposerDictation.insert("there", into: "hi.", at: 2..<2).text, "hi there.")
    }
}
