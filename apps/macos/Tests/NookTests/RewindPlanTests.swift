import XCTest

final class RewindPlanTests: XCTestCase {
    func testScopesOfferWhatTheSessionCanDoFullestFirst() {
        XCTAssertEqual(RewindPlan.scopes(canRestoreFiles: true, canRollBackConversation: true), [.everything, .files, .conversation])
        XCTAssertEqual(RewindPlan.scopes(canRestoreFiles: true, canRollBackConversation: false), [.files])
        XCTAssertEqual(RewindPlan.scopes(canRestoreFiles: false, canRollBackConversation: true), [.conversation])
        XCTAssertEqual(RewindPlan.scopes(canRestoreFiles: false, canRollBackConversation: false), [])
    }

    func testNoteQuotesTheVisibleMessageOnOneLine() {
        let message = ContextRefs.project("Fix the login\nand the [Login.swift](nook-context://v1/file/Login.swift) tests")
        let note = RewindPlan.note(before: message)
        XCTAssertFalse(note.contains("<nook_context>"))
        XCTAssertFalse(note.contains("\n"))
        XCTAssertTrue(note.contains("Fix the login"))
    }

    func testNoteStaysOutOfYourBubble() {
        let note = RewindPlan.note(before: "Add a dark mode")
        let plain = RewindPlan.attach(note, to: "Try it another way")
        XCTAssertEqual(ContextRefs.visible(plain), "Try it another way")
        XCTAssertTrue(plain.contains("<mode id=\"\(RewindPlan.noteID)\">"))

        let withRefs = ContextRefs.project("Look at [Login.swift](nook-context://v1/file/Login.swift)")
        let both = RewindPlan.attach(note, to: MainThread.attach(MainThread.note, to: withRefs))
        XCTAssertEqual(both.components(separatedBy: "<nook_context>").count, 2, "one envelope")
        XCTAssertEqual(ContextRefs.visible(both), ContextRefs.visible(withRefs))
        XCTAssertTrue(both.contains("<mode id=\"main-thread\">"))
        XCTAssertTrue(both.contains("<mode id=\"\(RewindPlan.noteID)\">"))
    }
}
