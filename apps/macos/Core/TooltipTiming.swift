import Foundation

/// When a tooltip (`.nookTip`) opens and closes, without any view: the first tip waits a short rest (`openDelay`), so
/// sweeping the pointer over a list stays quiet; once one was shown, the next opens at once and without a fade while the
/// pointer moves on within `warmWindow`, so moving along a row of buttons swaps the tips in one frame. A tip closes the
/// moment the pointer leaves. A click, a scroll or the window losing the keyboard ends the streak (`cancelAll`).
struct TooltipTiming {
    static let openDelay: Duration = .milliseconds(150)
    static let warmWindow: TimeInterval = 0.4

    /// The tip on screen now, if any.
    private(set) var shownID: AnyHashable?
    /// The tip waiting out `openDelay`, if any.
    private(set) var pendingID: AnyHashable?
    /// When the last tip closed by the pointer leaving: within `warmWindow` of it the next tip opens at once.
    private(set) var lastClosedAt: Date?

    enum Decision: Equatable {
        /// Show it now: `animated` is false for a warm swap (no fade).
        case showNow(animated: Bool)
        /// Show it once the pointer rested this long, unless something else happened first (`fire`).
        case showAfter(Duration)
        /// Hide whatever is shown and drop a pending open.
        case hide
        /// Nothing changes: the pointer left a view whose tip is not the current one.
        case keep
    }

    /// The pointer entered the view `id`.
    mutating func enter(_ id: AnyHashable, now: Date) -> Decision {
        if shownID != nil || isWarm(now: now) {
            shownID = id
            pendingID = nil
            return .showNow(animated: false)
        }
        pendingID = id
        return .showAfter(Self.openDelay)
    }

    /// The pending open of `id` is due: true when it should still show (nothing cancelled or replaced it).
    mutating func fire(_ id: AnyHashable) -> Bool {
        guard pendingID == id else { return false }
        pendingID = nil
        shownID = id
        return true
    }

    /// The pointer left the view `id`.
    mutating func exit(_ id: AnyHashable, now: Date) -> Decision {
        if shownID == id {
            shownID = nil
            lastClosedAt = now
            return .hide
        }
        if pendingID == id {
            pendingID = nil
            return .hide
        }
        return .keep
    }

    /// A click, a scroll, a drag, a key or the window resigning: close the tip, drop a pending one, and start cold again.
    mutating func cancelAll(now: Date) {
        shownID = nil
        pendingID = nil
        lastClosedAt = nil
    }

    /// True while a tip is shown or waiting to show.
    var isActive: Bool { shownID != nil || pendingID != nil }

    private func isWarm(now: Date) -> Bool {
        guard let lastClosedAt else { return false }
        let elapsed = now.timeIntervalSince(lastClosedAt)
        return elapsed >= 0 && elapsed <= Self.warmWindow
    }
}
