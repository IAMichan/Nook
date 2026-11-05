import XCTest

/// Asking a service for the chats that moved: a few at the same time, every answer in its chat's place, and no new asks
/// once the service refused the round.
@MainActor
final class ChatParallelTests: XCTestCase {
    func testChatsAreAskedAFewAtATimeInTheirPlaces() async {
        var running = 0
        var most = 0
        let answers = await ChatParallel.map(Array(0..<10), width: 3) { item -> Int in
            running += 1
            most = max(most, running)
            try? await Task.sleep(for: .milliseconds(20 + (9 - item) * 2))
            running -= 1
            return item * 10
        }
        XCTAssertEqual(most, 3, "at most three at a time, and more than one")
        XCTAssertEqual(answers, (0..<10).map { $0 * 10 }, "every answer in its chat's place, whichever came first")
    }

    func testARefusalEndsTheRound() async {
        var asked: [Int] = []
        let answers = await ChatParallel.ask(Array(0..<8), width: 2) { item -> ChatParallel.Asked<Int> in
            asked.append(item)
            // The first fails soon, the refusal comes later, and the one asked in between answers after it.
            try? await Task.sleep(for: .milliseconds(item == 0 ? 5 : item == 1 ? 40 : 90))
            return await ChatParallel.asking {
                if item == 1 { throw NookError("slow down", kind: .rateLimited) }
                if item == 0 { throw NookError("gone") }
                return item
            }
        }
        XCTAssertEqual(asked, [0, 1, 2], "the one asked when the first answer came still went; none after the refusal")
        guard case .failed? = answers[0] else { return XCTFail("a chat's own failure leaves the others") }
        guard case .refused? = answers[1] else { return XCTFail("a rate limit refuses the round") }
        guard case .answered(2)? = answers[2] else { return XCTFail("one already under way still answers") }
        XCTAssertTrue(answers[3...].allSatisfy { $0 == nil }, "nothing asked after the refusal")
    }

    func testNothingToAsk() async {
        let answers = await ChatParallel.map([Int]()) { $0 }
        XCTAssertTrue(answers.isEmpty)
    }
}
