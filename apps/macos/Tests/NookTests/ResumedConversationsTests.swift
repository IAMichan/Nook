import XCTest

/// A chat resumed into new transcript files is still one conversation.
final class ResumedConversationsTests: XCTestCase {
    private func transcript(_ id: String, sessions: Set<String> = [], first: String = "", parent: String = "", last: String = "",
                            prompt: String = "", at: String = "") -> ResumedConversations.Transcript {
        ResumedConversations.Transcript(
            links: ResumedConversations.links(sessionIDs: sessions.union([id]), firstMessage: first, firstParent: parent,
                                              lastMessage: last, firstPrompt: prompt, firstPromptAt: at)
        )
    }

    func testAResumedFileWithCopiedHistoryJoinsTheOriginal() {
        let groups = ResumedConversations.groups([
            transcript("new", sessions: ["old"], first: "m1", last: "m9"),
            transcript("old", first: "m1", last: "m5")
        ])
        XCTAssertEqual(groups, [[0, 1]])
    }

    func testAContinuationJoinsTheFileItPicksUpFrom() {
        let groups = ResumedConversations.groups([
            transcript("b", first: "m6", parent: "m5", last: "m8"),
            transcript("a", first: "m1", last: "m5")
        ])
        XCTAssertEqual(groups, [[0, 1]])
    }

    func testTheSameFirstPromptAtTheSameTimeJoins() {
        let groups = ResumedConversations.groups([
            transcript("b", first: "x1", prompt: "fix the build", at: "2026-10-15T09:00:00.000Z"),
            transcript("a", first: "y1", prompt: "fix the build", at: "2026-10-15T09:00:00.000Z")
        ])
        XCTAssertEqual(groups, [[0, 1]])
    }

    func testAChainOfThreeFilesIsOneConversation() {
        let groups = ResumedConversations.groups([
            transcript("c", sessions: ["b"], first: "m7"),
            transcript("other", first: "z1", prompt: "fix the build", at: "2026-10-15T09:00:00.000Z"),
            transcript("b", first: "m4", parent: "m3"),
            transcript("a", first: "m1", last: "m3", prompt: "fix the build", at: "2026-10-12T09:00:00.000Z")
        ])
        XCTAssertEqual(groups, [[0, 2, 3], [1]])
    }

    func testUnrelatedChatsStaySeparate() {
        let groups = ResumedConversations.groups([
            transcript("a", first: "m1", last: "m2", prompt: "hello", at: "2026-10-15T09:00:00.000Z"),
            transcript("b", first: "n1", last: "n2", prompt: "hello", at: "2026-10-15T10:00:00.000Z")
        ])
        XCTAssertEqual(groups, [[0], [1]])
    }
}
