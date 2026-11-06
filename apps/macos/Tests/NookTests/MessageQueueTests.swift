import XCTest

final class MessageQueueTests: XCTestCase {
    private func queue(_ texts: String...) -> MessageQueue {
        var q = MessageQueue()
        for t in texts { q.enqueue(t) }
        return q
    }

    func testEnqueueTrimsIgnoresEmptyAndCaps() {
        var q = MessageQueue()
        XCTAssertNil(q.enqueue("   \n"))
        XCTAssertEqual(q.enqueue("  hi ")?.text, "hi")
        for i in 0..<60 { q.enqueue("m\(i)") }
        XCTAssertEqual(q.count, MessageQueue.limit)
        XCTAssertNil(q.enqueue("one more"))
    }

    func testEditMarksEditedAndRefusesEmpty() {
        var q = queue("a")
        let id = q.messages[0].id
        XCTAssertTrue(q.edit(id, text: "a"))
        XCTAssertFalse(q.messages[0].edited)
        XCTAssertTrue(q.edit(id, text: " b "))
        XCTAssertEqual(q.messages[0].text, "b")
        XCTAssertTrue(q.messages[0].edited)
        XCTAssertFalse(q.edit(id, text: " "))
        XCTAssertFalse(q.edit(UUID(), text: "x"))
    }

    func testRemove() {
        var q = queue("a", "b")
        let id = q.messages[0].id
        XCTAssertTrue(q.remove(id))
        XCTAssertFalse(q.remove(id))
        XCTAssertEqual(q.messages.map(\.text), ["b"])
    }

    func testSettleNewsDropsWhatIsSolvedAndKeepsTheRest() throws {
        let url = "https://github.com/o/r/pull/1"
        let failed = PullRequestNews.Line(text: "CI failed: build.", subject: .failedChecks)
        let comment = PullRequestNews.Line(text: "Comment from @cy: typo", subject: .note)
        func enqueue(_ q: inout MessageQueue, _ lines: [PullRequestNews.Line], url: String) -> QueuedMessage? {
            q.enqueue(PullRequestNews.message(url: url, lines: lines.map(\.text)), pullRequest: PullRequestNotice(url: url, lines: lines))
        }
        let green = PullRequestSnapshot(state: "open", checks: "success", failedChecks: [], reviews: [], comments: [])

        var q = queue("mine")
        let solved = enqueue(&q, [failed], url: url)
        let mixed = enqueue(&q, [failed, comment], url: url)
        let other = enqueue(&q, [failed], url: "https://github.com/o/r/pull/2")
        let edited = try XCTUnwrap(enqueue(&q, [failed], url: url))
        q.edit(edited.id, text: "Fix the build, but keep the flag")
        let editing = try XCTUnwrap(enqueue(&q, [failed], url: url))
        _ = q.beginEdit(editing.id, currentDraft: "")

        q.settleNews(url: url, with: green)

        XCTAssertEqual(q.messages.map(\.id), [q.messages[0].id, mixed?.id, other?.id, edited.id, editing.id].compactMap { $0 })
        XCTAssertFalse(q.messages.contains { $0.id == solved?.id })
        XCTAssertEqual(q.messages[0].text, "mine")
        XCTAssertEqual(q.messages[1].text, PullRequestNews.message(url: url, lines: [comment.text]))
        XCTAssertEqual(q.messages[1].pullRequest?.lines, [comment])
        XCTAssertFalse(q.messages[1].edited)
        XCTAssertEqual(q.messages[2].pullRequest?.lines, [failed], "another pull request is not touched")
        XCTAssertEqual(q.messages[3].text, "Fix the build, but keep the flag", "a message you edited is yours")
        XCTAssertEqual(q.messages[4].pullRequest?.lines, [failed], "and so is one you are editing")

        let saved = try JSONDecoder().decode(MessageQueue.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(saved.messages.map(\.pullRequest), q.messages.map(\.pullRequest), "kept across a restart")
    }

    func testRequeueFirstGoesInFrontEvenWhenFull() {
        var q = queue("a")
        q.requeueFirst(" back ")
        q.requeueFirst("  ")
        XCTAssertEqual(q.messages.map(\.text), ["back", "a"])
        for i in 0..<60 { q.enqueue("m\(i)") }
        q.requeueFirst("first")
        XCTAssertEqual(q.messages.first?.text, "first")
        XCTAssertEqual(q.count, MessageQueue.limit + 1)
    }

    func testMoveClampsAndReverses() {
        var q = queue("a", "b", "c")
        let a = q.messages[0].id
        XCTAssertTrue(q.move(a, toIndex: 99))
        XCTAssertEqual(q.messages.map(\.text), ["b", "c", "a"])
        XCTAssertTrue(q.move(a, toIndex: -5))
        XCTAssertEqual(q.messages.map(\.text), ["a", "b", "c"])
        XCTAssertTrue(q.move(a, toIndex: 0))
        XCTAssertFalse(q.move(UUID(), toIndex: 0))
        XCTAssertEqual(q.messages.map(\.text), ["a", "b", "c"])
    }

    func testPromoteTwiceFindsNothing() {
        var q = queue("a", "b")
        let id = q.messages[1].id
        XCTAssertEqual(q.promoteToSteer(id), "b")
        XCTAssertNil(q.promoteToSteer(id))
        XCTAssertEqual(q.count, 1)
    }

    func testHeldQueueSendsNothingUntilResumed() {
        var q = queue("a", "b")
        q.hold()
        XCTAssertTrue(q.isHeld)
        XCTAssertNil(q.next())
        q.resume()
        XCTAssertEqual(q.next()?.text, "a")
        XCTAssertNil(q.next(held: true))
        XCTAssertEqual(q.next()?.text, "b")
        XCTAssertNil(q.next())
    }

    func testEditSessionRestoresDraft() {
        var q = queue("a", "b")
        let id = q.messages[0].id
        XCTAssertEqual(q.beginEdit(id, currentDraft: "my draft"), "a")
        // The edited message is not sent meanwhile.
        XCTAssertEqual(q.next()?.text, "b")
        XCTAssertEqual(q.endEdit(save: true, text: "a2"), "my draft")
        XCTAssertEqual(q.messages[0].text, "a2")
        XCTAssertNil(q.endEdit(save: false))
    }

    func testEditSessionCancelAndSecondBeginKeepsFirstDraft() {
        var q = queue("a", "b")
        let a = q.messages[0].id, b = q.messages[1].id
        _ = q.beginEdit(a, currentDraft: "draft")
        _ = q.beginEdit(b, currentDraft: "a")
        XCTAssertEqual(q.endEdit(save: false), "draft")
        XCTAssertEqual(q.messages.map(\.text), ["a", "b"])
        XCTAssertNil(q.beginEdit(UUID(), currentDraft: "x"))
    }

    func testEditedMessageThatWasRemovedIsNotBroughtBack() {
        var q = queue("a")
        let id = q.messages[0].id
        _ = q.beginEdit(id, currentDraft: "d")
        q.remove(id)
        XCTAssertNil(q.endEdit(save: true, text: "x"))
        XCTAssertTrue(q.isEmpty)
    }

    func testCodableToleratesMissingAndUnknownFields() throws {
        var q = queue("a")
        q.hold()
        let back = try JSONDecoder().decode(MessageQueue.self, from: JSONEncoder().encode(q))
        XCTAssertEqual(back.messages, q.messages)
        XCTAssertTrue(back.isHeld)
        let old = #"{"messages":[{"text":"x","future":1}],"other":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(MessageQueue.self, from: old)
        XCTAssertEqual(decoded.messages.first?.text, "x")
        XCTAssertFalse(decoded.isHeld)
        XCTAssertTrue(try JSONDecoder().decode(MessageQueue.self, from: Data("{}".utf8)).isEmpty)
    }
}
