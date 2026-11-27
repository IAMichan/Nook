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

    /// Turns at the end of a conversation that are always drawn when it opens.
    static let eagerTurns = 2
    /// Rows at least drawn at the end (a few short turns would not fill a view).
    static let eagerMinRows = 12
    /// Rows at most counted as the last turns' (`eagerRows`); the drawn rows (`drawnStart`) are at least these.
    static let eagerMaxRows = 48

    /// How many of the last rows of the window starting at turn `start` must be drawn: the last `eagerTurns` turns, at
    /// least `eagerMinRows` rows, at most `eagerMaxRows`.
    static func eagerRows(rowsPerTurn: [Int], start: Int, minRows: Int = eagerMinRows, maxRows: Int = eagerMaxRows) -> Int {
        let shown = rowsPerTurn.dropFirst(max(0, start))
        let total = shown.reduce(0, +)
        let lastTurns = shown.suffix(eagerTurns).reduce(0, +)
        return min(total, min(maxRows, max(minRows, lastTurns)))
    }

    // MARK: Drawn rows
    //
    // A conversation draws its rows in full, never in a lazy stack. A lazy stack only guesses the height of the rows it
    // has not laid out, and corrects the guess as they come into view: everything above what you read moved by hundreds
    // of points at once on a step of the wheel, and every fix on top of it (holding the row you read, putting the end
    // back) worked from those guesses and moved the conversation the wrong way in turn, so it bounced up and down under
    // you while an agent worked (measured in `ReadingBackWhileWorking` on 2026-11-27: the row held while reading moved
    // 511 pt by a guess, then back). Rows drawn in full stand where they are. To keep a long conversation cheap, only its
    // last `drawnRows` are drawn when it opens, and `drawnPage` more each time you scroll near the top of what is drawn,
    // put in above what you read in the same pass of layout (`TimelineReadingAnchor.growsAbove`), as a chat's history.

    /// Rows drawn when a conversation opens (or the last turns, when those are more).
    static let drawnRows = 60
    /// Rows drawn above the drawn ones each time you scroll near their top.
    static let drawnPage = 40
    /// How near the top of the drawn rows the view may come, in view heights, before more are drawn above.
    static let drawnAhead = 2.0

    /// The index of the first drawn row of `count` rows: where the row `first` stands now; while it is gone (folded
    /// into another, or undone), as far from the end as it was (`fromEnd`); else the last `max(drawnRows, minimum)`.
    static func drawnStart(count: Int, first: Int?, fromEnd: Int?, minimum: Int, rows: Int = drawnRows) -> Int {
        if let first { return min(max(0, first), max(0, count - minimum)) }
        if let fromEnd { return min(max(0, count - fromEnd), max(0, count - minimum)) }
        return max(0, count - max(rows, minimum))
    }

    /// The first drawn row once a page more is drawn above `start`.
    static func earlierDrawn(from start: Int, page: Int = drawnPage) -> Int {
        max(0, start - max(1, page))
    }

    /// Whether a view standing `fromTop` points under the top of its content, `container` high, is near enough the top
    /// of what is drawn to draw more above.
    static func nearDrawnTop(fromTop: Double, container: Double, ahead: Double = drawnAhead) -> Bool {
        container > 0 && fromTop < container * ahead
    }

    /// The index of the first row drawn: every row of the turns before `start`.
    static func firstRow(rowsPerTurn: [Int], start: Int) -> Int {
        rowsPerTurn.prefix(max(0, start)).reduce(0, +)
    }
}
