import Foundation

// Bounded history, as t3code opens a long thread from its latest segments: a conversation opens with only its latest
// turns drawn, and "Show earlier messages" at the top widens that by a page of turns. The window always starts at a turn
// (a message of yours), so no turn is cut in half. A few long turns open with fewer of them (`maxRows`), but always with
// at least the last one.
//
// The window is kept as the index of its first turn, counted from the start of the conversation: new turns at the end
// leave it where it is, so what you read does not move while the agent works. Find (⌘F), a mark on the rail or a jump to
// an earlier event reveal the turn they need (`revealing`).
//
// Both conversation views use it: `AgentRunPanel` over its blocks per turn, `TranscriptConversation` over its rows per
// turn. Foundation only, so the tests drive it without a view.

enum HistoryWindow {
    /// Turns drawn when a conversation opens.
    static let initialTurns = 20
    /// Turns added by each "Show earlier messages".
    static let pageTurns = 20
    /// Rows at most when a conversation opens (folded turns are a few rows each; a turn still at work can be hundreds).
    static let maxRows = 400

    /// The first turn drawn when a conversation opens, of `rowsPerTurn` (the rows of each turn, oldest first).
    static func initialStart(rowsPerTurn: [Int], turns: Int = initialTurns, maxRows: Int = maxRows) -> Int {
        let count = rowsPerTurn.count
        guard count > 0 else { return 0 }
        var start = count - 1
        var rows = rowsPerTurn[start]
        while start > 0, count - start < max(1, turns), rows + rowsPerTurn[start - 1] <= maxRows {
            start -= 1
            rows += rowsPerTurn[start]
        }
        return start
    }

    /// One page of turns earlier than `start`.
    static func earlier(from start: Int, turns: Int = pageTurns) -> Int {
        max(0, start - max(1, turns))
    }

    /// The window that also holds `turn` (find, a mark on the rail, a jump to an earlier event): never narrower.
    static func revealing(_ turn: Int?, from start: Int) -> Int {
        guard let turn else { return start }
        return min(start, max(0, turn))
    }

    /// `start` within a conversation of `turnCount` turns (one that went back to an earlier message has fewer).
    static func clamped(_ start: Int, turnCount: Int) -> Int {
        min(max(0, start), max(0, turnCount - 1))
    }

    /// The index of the first row drawn: every row of the turns before `start`.
    static func firstRow(rowsPerTurn: [Int], start: Int) -> Int {
        rowsPerTurn.prefix(max(0, start)).reduce(0, +)
    }
}
