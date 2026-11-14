import XCTest

final class HistoryWindowTests: XCTestCase {
    func testAShortConversationShowsEverything() {
        XCTAssertEqual(HistoryWindow.initialStart(rowsPerTurn: []), 0)
        XCTAssertEqual(HistoryWindow.initialStart(rowsPerTurn: [3, 3, 3]), 0)
        XCTAssertEqual(HistoryWindow.initialStart(rowsPerTurn: Array(repeating: 3, count: HistoryWindow.initialTurns)), 0)
    }

    func testALongConversationOpensWithItsLatestTurns() {
        let turns = Array(repeating: 3, count: 500)
        let start = HistoryWindow.initialStart(rowsPerTurn: turns)
        XCTAssertEqual(start, 500 - HistoryWindow.initialTurns)
        XCTAssertEqual(HistoryWindow.firstRow(rowsPerTurn: turns, start: start), start * 3)
    }

    func testLongTurnsOpenWithFewerOfThemButNeverNone() {
        XCTAssertEqual(HistoryWindow.initialStart(rowsPerTurn: [50, 50, 50, 50], turns: 20, maxRows: 120), 2,
                       "two turns fit in 120 rows, a third does not")
        XCTAssertEqual(HistoryWindow.initialStart(rowsPerTurn: [5, 900], maxRows: 400), 1,
                       "a turn longer than the cap still shows")
    }

    func testShowEarlierAddsAPageUntilTheStart() {
        XCTAssertEqual(HistoryWindow.earlier(from: 480), 480 - HistoryWindow.pageTurns)
        XCTAssertEqual(HistoryWindow.earlier(from: 5), 0)
        XCTAssertEqual(HistoryWindow.earlier(from: 0), 0)
    }

    func testRevealingAnEarlierTurnOnlyWidens() {
        XCTAssertEqual(HistoryWindow.revealing(12, from: 40), 12, "find or a mark in a hidden turn widens the window")
        XCTAssertEqual(HistoryWindow.revealing(45, from: 40), 40, "a turn already drawn changes nothing")
        XCTAssertEqual(HistoryWindow.revealing(nil, from: 40), 40)
    }

    func testTheEndOfAConversationIsDrawnInFull() {
        XCTAssertEqual(HistoryWindow.eagerRows(rowsPerTurn: [], start: 0), 0)
        XCTAssertEqual(HistoryWindow.eagerRows(rowsPerTurn: [3, 4], start: 0), 7, "a short conversation is drawn in full")
        XCTAssertEqual(HistoryWindow.eagerRows(rowsPerTurn: [10, 10, 10, 10, 10], start: 0), 20, "its last two turns")
        XCTAssertEqual(HistoryWindow.eagerRows(rowsPerTurn: Array(repeating: 2, count: 30), start: 0), HistoryWindow.eagerMinRows,
                       "short turns: enough rows to fill a view")
        XCTAssertEqual(HistoryWindow.eagerRows(rowsPerTurn: [5, 300], start: 0), HistoryWindow.eagerMaxRows,
                       "a turn at work with hundreds of rows stays bounded")
        XCTAssertEqual(HistoryWindow.eagerRows(rowsPerTurn: [40, 40, 2, 3], start: 3), 3, "never more than the window shows")
    }

    func testRowsMoveIntoTheLazyStackInSteps() {
        XCTAssertEqual(HistoryWindow.lazyRows(count: 20, eager: 12), 0, "fewer than a step: all drawn in full")
        XCTAssertEqual(HistoryWindow.lazyRows(count: 100, eager: 48), 48)
        // A working agent adds rows one by one: the split between the parts stays where it is for a while.
        let splits = (100...115).map { HistoryWindow.lazyRows(count: $0, eager: 48) }
        XCTAssertEqual(Set(splits).count, 2, "moves once in sixteen new rows, not with every one")
        for count in 0...300 {
            let lazy = HistoryWindow.lazyRows(count: count, eager: 48)
            XCTAssertGreaterThanOrEqual(count - lazy, min(count, 48), "the last rows are always drawn in full")
            XCTAssertLessThan(count - lazy, 48 + HistoryWindow.lazyStep)
        }
        XCTAssertEqual(HistoryWindow.lazyRows(count: 5, eager: 9), 0)
    }

    func testAConversationThatWentBackKeepsAValidStart() {
        XCTAssertEqual(HistoryWindow.clamped(40, turnCount: 10), 9)
        XCTAssertEqual(HistoryWindow.clamped(40, turnCount: 0), 0)
        XCTAssertEqual(HistoryWindow.clamped(-3, turnCount: 10), 0)
    }

    // MARK: The two conversation views

    /// `turns` turns of a session Nook ran, each your message, a few tool calls and an answer that ended well.
    private func session(turns: Int, tools: Int = 6) -> [RunEvent] {
        (0..<turns).flatMap { turn -> [RunEvent] in
            [RunEvent(kind: .user, text: "Question \(turn)")]
                + (0..<tools).map { RunEvent(kind: .tool, text: "Bash · step \($0)", tool: "Bash", callID: "\(turn)-\($0)", state: .done) }
                + [RunEvent(kind: .assistant, text: "Answer \(turn)", state: .done), RunEvent(kind: .result, text: "", state: .done)]
        }
    }

    func testTheRunTimelineWindowFollowsItsTurns() {
        var cache = TimelineBlockCache()
        let events = session(turns: 120)
        let blocks = TimelinePresentation.blocks(events, active: false, cache: &cache)
        let perTurn = cache.turns.map(\.blocks.count)
        XCTAssertEqual(perTurn.count, 120)
        XCTAssertEqual(perTurn.reduce(0, +), blocks.count)
        let start = HistoryWindow.initialStart(rowsPerTurn: perTurn)
        let first = HistoryWindow.firstRow(rowsPerTurn: perTurn, start: start)
        guard case .event(let opening) = blocks[first] else { return XCTFail("a window starts at your message") }
        XCTAssertEqual(opening.text, "Question \(start)")
    }

    func testTheTranscriptWindowFollowsItsTurns() {
        let rows: [TranscriptRow] = [
            .notice(AgentChatMessage(id: "n0", notice: .compacted(tokens: nil), date: nil)),
            .user(AgentChatMessage(id: "u1", kind: .user, text: "one")),
            .assistant(AgentChatMessage(id: "a1", kind: .assistant, text: "1"), isFinal: true),
            .user(AgentChatMessage(id: "u2", kind: .user, text: "two")),
            .assistant(AgentChatMessage(id: "a2", kind: .assistant, text: "2"), isFinal: false),
            .assistant(AgentChatMessage(id: "a3", kind: .assistant, text: "3"), isFinal: true),
        ]
        XCTAssertEqual(TranscriptPresentation.rowsPerTurn(rows), [1, 2, 3])
        XCTAssertEqual(TranscriptPresentation.turn(ofRow: "n0", in: rows), 0)
        XCTAssertEqual(TranscriptPresentation.turn(ofRow: "u2", in: rows), 2)
        XCTAssertEqual(TranscriptPresentation.turn(ofRow: "a3", in: rows), 2)
        XCTAssertNil(TranscriptPresentation.turn(ofRow: "gone", in: rows))
    }

    /// What a long session hands the conversation's lazy stack as it opens, before and after the window: the rows its
    /// `ForEach` diffs on every redraw (each streamed token of a working agent), and the time to pick them.
    func testALongSessionOpensWithFarFewerRows() {
        var cache = TimelineBlockCache()
        let events = session(turns: 2_000)
        let blocks = TimelinePresentation.blocks(events, active: false, cache: &cache)
        let perTurn = cache.turns.map(\.blocks.count)
        let clock = Date()
        let start = HistoryWindow.initialStart(rowsPerTurn: perTurn)
        let shown = blocks.count - HistoryWindow.firstRow(rowsPerTurn: perTurn, start: start)
        let elapsed = Date().timeIntervalSince(clock)
        print("HistoryWindow: \(events.count) events, \(blocks.count) rows before, \(shown) rows after, window picked in \(Int(elapsed * 1_000_000)) µs")
        XCTAssertGreaterThan(blocks.count, 5_000)
        XCTAssertLessThanOrEqual(shown, HistoryWindow.initialTurns * 4, "a folded turn is four rows: message, fold, answer, end")
        XCTAssertLessThan(elapsed, 0.05)
    }
}
