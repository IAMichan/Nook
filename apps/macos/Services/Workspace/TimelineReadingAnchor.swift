import Foundation

/// Keeps the row you read where it is on screen while you read back through an agent's conversation and something
/// above it changes height: the lazy stack measuring rows it had only guessed (each row that scrolls into view from
/// above), a turn that folds into "Worked for …" when the agent finishes, a running command's progress, a row that moves
/// between the lazy and the fully drawn part of the conversation (`HistoryWindow.lazyRows`), earlier turns drawn above.
/// Without it every such change pushed what you read up or down while the agent worked.
///
/// It holds one row, the first that starts in view, and only acts when that row itself moves in the conversation: it
/// then scrolls by exactly as much, so the row stays put. Where the view is scrolled is never undone. The chat's anchor
/// (`TranscriptReadingAnchor`) puts the held message back at the place it remembers; in a lazy stack the content size
/// changes on nearly every step of scrolling up (each row that comes into view is measured), and a step that also
/// changed a size would be taken back, so scrolling up stuck. Here a step of yours always counts, also in a step that
/// measured a row.
///
/// What changes below the held row moves nothing you see. While the view follows the end, finds, or runs a scroll of
/// its own (an animated jump to a mark on the rail), it holds nothing (`holding` false). Foundation only and a plain
/// object, so tests drive it without a view and the steps of a scroll redraw nothing.
@MainActor
final class TimelineReadingAnchor {
    /// Where each drawn row starts, in the stack of rows.
    private var tops: [AnyHashable: Double] = [:]
    /// Where the stack of rows starts in the scroll view's content.
    private var stackTop = 0.0
    /// The row held, and where it started in the content when last seen.
    private(set) var held: AnyHashable?
    private var heldTop = 0.0
    private var offset = 0.0
    private var container = 0.0
    private var holding = false
    /// The room above the content (a toolbar): the view shows the content from under it.
    private var insetTop = 0.0
    /// How far the held row moved that the view has not moved along with yet (`flush`).
    private var pending = 0.0
    /// Where the view stood when the held row began to move (`pending`).
    private var pendingFrom = 0.0
    private var flushQueued = false
    /// Scrolls the conversation to this content offset (as the scroll view reports it) at once.
    var scroll: (Double) -> Void = { _ in }
    /// Runs the flush after this turn of the run loop; tests run it at once or never.
    var later: (@escaping @MainActor () -> Void) -> Void = { work in DispatchQueue.main.async { work() } }

    /// Where a row starts in the stack, or nil once it is no longer drawn.
    func place(_ id: AnyHashable, top: Double?) {
        guard let top else {
            tops[id] = nil
            if id == held { holdRowAbove() }
            return
        }
        tops[id] = top
        guard id == held else { return }
        shift(by: stackTop + top - heldTop)
    }

    /// The stack of rows moved within the content (a row above it came or went).
    func stack(at top: Double) {
        let moved = top - stackTop
        stackTop = top
        if held != nil { shift(by: moved) }
    }

    /// The conversation's scroll view moved or changed size. `holding`: you read back (not following the end, not
    /// finding, no scroll of the view's own on its way).
    func moved(offset: Double, container: Double, insetTop: Double = 0, holding: Bool) {
        self.offset = offset
        self.container = container
        self.insetTop = insetTop
        let started = holding && !self.holding
        self.holding = holding
        guard holding else {
            held = nil
            pending = 0
            return
        }
        // The scroll view itself moved along with the row above the view that changed (it does so now and then, not
        // always): nothing left to do. Moving it again scrolled twice as far.
        if abs(offset - pendingFrom - pending) < 0.5 { pending = 0 }
        // The held row left the view (you scrolled on): the first row in view now is held instead.
        if started || held == nil || heldTop < viewTop - 0.5 || heldTop > viewTop + container { pick() }
    }

    /// Where the view starts in the content: under the room above it.
    private var viewTop: Double { offset + insetTop }

    /// The held row moved by `delta` in the content: the view moves along by as much, from where it stands then. Not
    /// at once, but once this pass of layout is done (`later`): in one pass the rows report where they stand before
    /// the scroll view reports where it is, so a step of yours in that pass was not known yet, and scrolling from the
    /// offset of the pass before undid it (seen offscreen: scrolling up stuck at one place); and a scroll asked for
    /// within the pass was put back by the scroll view as the pass ended.
    private func shift(by delta: Double) {
        heldTop += delta
        guard holding, abs(delta) > 0.5 else { return }
        if pending == 0 { pendingFrom = offset }
        pending += delta
        guard !flushQueued else { return }
        flushQueued = true
        later { [weak self] in
            self?.flushQueued = false
            self?.flush()
        }
    }

    /// Moves the view along with the held row, by what it moved since the last time.
    private func flush() {
        guard holding, abs(pending) > 0.5 else {
            pending = 0
            return
        }
        offset += pending
        pending = 0
        scroll(offset)
    }

    /// The held row is no longer drawn: it went into a fold (a finished turn folds its steps under its first one) or
    /// was replaced. The row that starts right above it is held instead, so what takes its place stays where it was.
    private func holdRowAbove() {
        let above = tops.map { (id: $0.key, top: stackTop + $0.value) }
            .filter { $0.top <= heldTop + 0.5 }
            .max { $0.top < $1.top }
        held = above?.id
        heldTop = above?.top ?? 0
    }

    /// Holds the first row that starts in view (else none: the view stands inside one tall row).
    private func pick() {
        let first = tops.map { (id: $0.key, top: stackTop + $0.value) }
            .filter { $0.top >= viewTop - 0.5 && $0.top <= viewTop + container }
            .min { $0.top < $1.top }
        // Inside a single tall row (a long answer) the row that runs through the view is held.
        let through = first ?? tops.map { (id: $0.key, top: stackTop + $0.value) }
            .filter { $0.top < viewTop }
            .max { $0.top < $1.top }
        held = through?.id
        heldTop = through?.top ?? 0
    }
}
