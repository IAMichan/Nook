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
