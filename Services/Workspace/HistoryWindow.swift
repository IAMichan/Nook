import Foundation

// Bounded history: a cold open renders only the tail
// of the timeline and "Load earlier turns" widens it. A window always starts at a user message so no turn is cut in
// half, except when one single turn alone exceeds the item cap: the hard cap wins then.

enum HistoryWindow {
    struct Window: Equatable, Sendable {
        var startIndex: Int
        var hasMore: Bool

        func loadedRange(count: Int) -> Range<Int> { min(startIndex, count)..<count }
    }

    static let maxBytes = 1_048_576

    static func initial(events: [RunEvent], maxUserTurns: Int = 10, maxItems: Int = 75,
                        maxBytes: Int = HistoryWindow.maxBytes) -> Window {
        let count = events.count
        guard count > 0 else { return Window(startIndex: 0, hasMore: false) }
        let users = events.indices.filter { events[$0].kind == .user }
        var start = users.count > max(1, maxUserTurns) ? users[users.count - max(1, maxUserTurns)] : 0

        let itemFloor = count - max(1, maxItems)
        if start < itemFloor {
            start = users.first(where: { $0 >= itemFloor }) ?? itemFloor
        }

        var bytes = bytesEstimate(events, in: Window(startIndex: start, hasMore: false))
        while bytes > maxBytes, let next = users.first(where: { $0 > start }) {
            bytes -= bytesEstimate(events, in: Window(startIndex: start, hasMore: false), upTo: next)
            start = next
        }
        return Window(startIndex: start, hasMore: start > 0)
    }

    /// Widens a window by `userTurns` more user turns (no item cap: the reader asked for them).
    static func earlier(events: [RunEvent], from startIndex: Int, userTurns: Int = 20) -> Window {
        let from = min(max(0, startIndex), events.count)
        let before = (0..<from).filter { events[$0].kind == .user }
        let n = max(1, userTurns)
        let start = before.count > n ? before[before.count - n] : 0
        return Window(startIndex: start, hasMore: start > 0)
    }

    private static func size(_ e: RunEvent) -> Int {
        64 + e.text.utf8.count + (e.detail?.utf8.count ?? 0) + (e.output?.utf8.count ?? 0)
    }

    /// Rough memory/wire size of a window, to keep it under `maxBytes`.
    static func bytesEstimate(_ events: [RunEvent], in window: Window) -> Int {
        bytesEstimate(events, in: window, upTo: events.count)
    }

    private static func bytesEstimate(_ events: [RunEvent], in window: Window, upTo end: Int) -> Int {
        let lo = min(window.startIndex, events.count), hi = min(end, events.count)
        guard lo < hi else { return 0 }
        return events[lo..<hi].reduce(0) { $0 + size($1) }
    }
}
