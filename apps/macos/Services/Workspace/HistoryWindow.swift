import Foundation

// Bounded history, opening a long thread from its latest segments: a conversation opens with only its latest
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

    /// Turns at the end of a conversation that are always drawn in full, never by a lazy stack.
    static let eagerTurns = 2
    /// Rows at least drawn in full at the end (a few short turns would not fill a view).
    static let eagerMinRows = 12
    /// Rows at most drawn in full at the end, so a turn still at work with hundreds of rows stays cheap to lay out.
    static let eagerMaxRows = 48

    /// How many of the last rows of the window starting at turn `start` are drawn in full (a plain stack), the rest
    /// lazily. A lazy stack whose rows change height (a turn that folds, an answer that streams, a narrower column) can
    /// come to rest drawing none of its rows where the view stands, even at its very end, and scrolling or making the
    /// scroll view again does not reliably bring them back (seen in the app on 2026-11-13: 68 rows, none drawn, at the
    /// end, through rebuilds; reproduced offscreen with a bare `LazyVStack`). Rows drawn in full are always there, so the
    /// end of a conversation, where you nearly always are, can never be blank, and a recovery that scrolls to it always
    /// lands on rows. The last `eagerTurns` turns, at least `eagerMinRows` rows, at most `eagerMaxRows`.
    static func eagerRows(rowsPerTurn: [Int], start: Int, minRows: Int = eagerMinRows, maxRows: Int = eagerMaxRows) -> Int {
        let shown = rowsPerTurn.dropFirst(max(0, start))
        let total = shown.reduce(0, +)
        let lastTurns = shown.suffix(eagerTurns).reduce(0, +)
        return min(total, min(maxRows, max(minRows, lastTurns)))
    }

    /// Rows move from the part drawn in full into the lazy part this many at a time.
    static let lazyStep = 16

    /// How many of `count` rows go into the lazy stack when the last `eager` must be drawn in full: in steps of
    /// `lazyStep`. A row that moves from one part to the other is made again, and the lazy stack guesses the height of
    /// what it has not measured; moving one row each time a working agent added one made the conversation jump up or
    /// down by a few points for every step. In steps, a little more is drawn in full and it moves only now and then.
    static func lazyRows(count: Int, eager: Int, step: Int = lazyStep) -> Int {
        let lazy = max(0, count - max(0, eager))
        return step > 1 ? lazy / step * step : lazy
    }

    /// The index of the first row drawn: every row of the turns before `start`.
    static func firstRow(rowsPerTurn: [Int], start: Int) -> Int {
        rowsPerTurn.prefix(max(0, start)).reduce(0, +)
    }
}
