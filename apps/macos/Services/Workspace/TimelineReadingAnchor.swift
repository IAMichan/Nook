import Foundation

/// Keeps the row you read where it is on screen while you read back through an agent's conversation and something
/// above it changes height: a turn that folds into "Worked for …" when the agent finishes, a running command's progress,
/// earlier rows drawn above (`RowWindow`, `growsAbove`). The rows are all drawn in full (`ConversationRows`), so where
/// they say they stand is where they are: in a lazy stack (until 2026-11-27) they reported guessed places, and holding
/// a row by a guess moved the conversation by hundreds of points and back.
/// Without it every such change pushed what you read up or down while the agent worked.
///
/// It holds one row, the first that starts in view, and remembers where on screen you last scrolled it to: your wheel
/// and trackpad steps (`userStep`) move that place, everything else does not. When the row ends up elsewhere (it moved
/// in the conversation, or the scroll view moved by itself), the view scrolls to put it back. In a lazy stack the
/// content size changes on nearly every step of scrolling up (each row that comes into view is measured), so a step of
/// yours always counts, also in a step that measured a row. Adding up how far the row moved instead (as before
/// 2026-11-18) went wrong whenever the scroll view also moved by itself: it goes along with a row above now and then,
/// reports that apart from the size change, and clamps to the end when the content above shrinks by more than you are
/// from the end; counting from there scrolled twice as far, thousands of points in a long session.
///
/// What changes below the held row moves nothing you see. While the view follows the end, finds, or runs a scroll of
/// its own (an animated jump to a mark on the rail), it holds nothing (`holding` false). Foundation only and a plain
/// object, so tests drive it without a view and the steps of a scroll redraw nothing.
@MainActor
final class TimelineReadingAnchor {
    /// Where each drawn row starts, in the stack of rows.
    private var tops: [AnyHashable: Double] = [:]
    /// How tall each drawn row is, where it said so.
    private var heights: [AnyHashable: Double] = [:]
    /// The width of the stack of rows (`width(_:)`).
    private var width: Double?
    /// The view stood this far into the held row (from its top to the view's top), the row this tall, when the width
    /// last changed: a tall row (a long answer) wraps anew at another width, and the line you read moves within it.
    private var rewrap: (inside: Double, height: Double)?
    /// When the width last changed: the held row's height changing well after that is it growing (an agent writing
    /// into it), not wrapping anew.
    private var widthChangedAt = Date.distantPast
    /// Now; tests set the clock.
    var now: () -> Date = { Date() }
    /// How long after a change of the width the held row may still wrap anew.
    static let rewrapTime = 0.5
    /// Where the stack of rows starts in the scroll view's content.
    private var stackTop = 0.0
    /// The row held, and where it starts in the content now.
    private(set) var held: AnyHashable?
    private var heldTop = 0.0
    /// Where the held row should stand in the view (its top minus the offset): where you last scrolled it to. Only
    /// your own moves change it; a row above that changes height, or the scroll view moving by itself, does not.
    private var heldInView = 0.0
    private var offset = 0.0
    private var container = 0.0
    private var holding = false
    /// The room above the content (a toolbar): the view shows the content from under it.
    private var insetTop = 0.0
    /// What your scroll-wheel or trackpad steps since the last move should move the view by (`userStep`), and whether
    /// any came whose size is not known (a mouse wheel's lines).
    private var steps = 0.0
    private var unmeasuredStep = false
    /// How far the held row moved in the content since the scroll view last moved: a move of the view right after one
    /// is the scroll view going along with it by itself (it reports that without any change in size), not yours.
    private var rowMoved = 0.0
    private var flushQueued = false
    /// Scrolls the conversation to this content offset (as the scroll view reports it) at once.
    var scroll: (Double) -> Void = { _ in }
    /// Where the scroll view stands right now, before it reported it (nil: not known).
    var currentOffset: () -> Double? = { nil }
    /// Runs the flush after this turn of the run loop; tests run it at once or never.
    var later: (@escaping @MainActor () -> Void) -> Void = { work in DispatchQueue.main.async { work() } }

    /// Puts the view at content offset `offset` now, in this pass: the frame drawn next already shows it there. A
    /// `ScrollViewProxy.scrollTo` lands a frame later, and the frame in between showed the conversation a chunk away from
    /// where it should be. False when no scroll view is connected yet.
    func jump(to offset: Double) -> Bool {
        guard currentOffset() != nil else { return false }
        scroll(offset)
        return true
    }

    /// Until when the next growth of the content is all above what you read (`growsAbove`).
    private var growsAboveUntil: Date?

    /// The next growth of the content comes all above what you read: a page of older messages drawn above the oldest
    /// one. Said right before that page is drawn; the scroll view's probe (`readingScroller`) then moves the view down by
    /// the growth in the same pass of layout (`takesGrowthAbove`, `shifted(by:)`), so no frame shows the older messages
    /// pushing what you read down. Putting it back a frame later (a `scrollTo` after the page was drawn) showed the chat
    /// jumping down and up again each time a page came in. Holds for `seconds`: a page that drew nothing leaves no
    /// promise behind for a picture that loads later.
    func growsAbove(for seconds: Double = 0.5) {
        growsAboveUntil = now().addingTimeInterval(seconds)
    }

    /// Whether the growth the content just made is the one `growsAbove` announced; it is taken, so the next is not.
    func takesGrowthAbove() -> Bool {
        guard let until = growsAboveUntil else { return false }
        growsAboveUntil = nil
        return now() <= until
    }

    /// The view was moved down by `delta` along with content that grew above everything in view (`growsAbove`), so
    /// its report that follows is no move of yours. The held row tells where it went itself (`place`), before or after
    /// this in the same pass: moving it here as well moved the view down twice as far.
    func shifted(by delta: Double) {
        offset += delta
    }

    /// Where a row starts in the stack (and how tall it is, when known), or nil once it is no longer drawn.
    func place(_ id: AnyHashable, top: Double?, height: Double? = nil) {
        guard let top else {
            tops[id] = nil
            heights[id] = nil
            if id == held { holdRowAbove() }
            return
        }
        tops[id] = top
        if let height { heights[id] = height }
        guard id == held else { return }
        // The held row wrapped anew at another width: the line you read stays in view, as t3code holds the line of
        // text at the top rather than the top of its row. As far into the row as before, in parts of its height: the
        // text above that line wraps to as many more (or fewer) lines as the rest of it.
        if rewrap != nil, now().timeIntervalSince(widthChangedAt) > Self.rewrapTime { rewrap = nil }
        if let rewrap, let height, rewrap.height > 0, abs(height - rewrap.height) > 0.5 {
            heldInView = insetTop - rewrap.inside * height / rewrap.height
        }
        rowMoved += stackTop + top - heldTop
        heldTop = stackTop + top
        queueFlush()
    }

    /// The stack of rows is `width` wide now (the side panel or the window was resized): the held row may wrap anew.
    func width(_ width: Double) {
        defer { self.width = width }
        guard let old = self.width, abs(old - width) > 0.5, holding, let held, let height = heights[held] else { return }
        // Measured from where the view stood at the first change of a drag, not each step's: the steps add up.
        if rewrap != nil, now().timeIntervalSince(widthChangedAt) > Self.rewrapTime { rewrap = nil }
        widthChangedAt = now()
        if rewrap == nil {
            let inside = insetTop - heldInView
            rewrap = inside > 0.5 && inside < height ? (inside, height) : nil
        }
    }

    /// The stack of rows moved within the content (a row above it came or went).
    func stack(at top: Double) {
        let moved = top - stackTop
        stackTop = top
        guard held != nil else { return }
        heldTop += moved
        rowMoved += moved
        queueFlush()
    }

    /// A scroll-wheel or trackpad step of yours over the conversation, before the view moves by it: `deltaY` as AppKit
    /// gives it (above zero toward the start), `precise` when it is in points (a trackpad, a Magic Mouse).
    func userStep(deltaY: Double, precise: Bool) {
        rewrap = nil
        if precise { steps -= deltaY } else { unmeasuredStep = true }
    }

    /// The conversation's scroll view moved or changed size. `holding`: you read back (not following the end, not
    /// finding, no scroll of the view's own on its way).
    func moved(offset: Double, container: Double, insetTop: Double = 0, holding: Bool) {
        // A report the view has already moved on from (the anchor's own scroll right after it, or a step of yours):
        // taking it for a move scrolled the view back to where it was. The report of where it stands now comes next.
        if holding, self.holding, let current = currentOffset(), abs(current - offset) > 0.5 {
            self.container = container
            self.insetTop = insetTop
            return
        }
        let change = offset - self.offset
        let yours = yourPart(of: change)
        self.offset = offset
        self.container = container
        self.insetTop = insetTop
        let started = holding && !self.holding
        self.holding = holding
        guard holding else {
            held = nil
            rewrap = nil
            clearSteps()
            return
        }
        guard !started, held != nil else {
            pick(at: offset)
            return
        }
        // Your move carries the held row along on screen; one the scroll view made by itself does not. It moves along
        // with a row above the view that changed now and then, and it clamps to the end of content that got shorter
        // above the view (a lazy stack measuring rows it had guessed): counting from where the view stood after that
        // scrolled twice as far, thousands of points in a long session.
        heldInView -= yours
        // Where the view should stand: the held row where you left it.
        let intended = heldTop - heldInView
        // The held row left the view (you scrolled on): the first row in view there is held instead.
        if heldInView < insetTop - 0.5 || heldInView > insetTop + container { pick(at: intended) }
        if abs(intended - offset) > 0.5 { queueFlush() }
    }

    /// How much of a move of `change` is yours. The scroll view moves by itself only along with the held row (up to as
    /// far as the row moved since its last move), so yours lies between `change` and `change` less the row's move: the
    /// wheel or trackpad steps you made, kept within that (steps the view could not follow, at the end of the content,
    /// are not carried into a later move), or as near to none as that allows (the keyboard sends no step, and moves
    /// only the view). Neither a change in size nor its absence tells: the scroll view reports the move it makes along
    /// with a row above apart from the size change, and a size change in the same report as your step.
    private func yourPart(of change: Double) -> Double {
        guard abs(change) > 0.5 else { return 0 }
        let yours: Double
        if unmeasuredStep {
            yours = change
        } else {
            let low = min(change, change - rowMoved)
            let high = max(change, change - rowMoved)
            yours = min(max(steps, low), high)
        }
        clearSteps()
        // What the scroll view moved by itself went along with the row; the rest of the row's move may still come.
        let own = change - yours
        if rowMoved != 0, own != 0, (own < 0) == (rowMoved < 0) {
            rowMoved = abs(own) >= abs(rowMoved) ? 0 : rowMoved - own
        }
        return yours
    }

    private func clearSteps() {
        steps = 0
        unmeasuredStep = false
    }

    /// Moves the view so the held row stands where you left it, once this pass of layout is done (`later`): in one
    /// pass the rows report where they stand before the scroll view reports where it is, so a step of yours in that
    /// pass is only known after both; and a scroll asked for within the pass was put back by the scroll view as the
    /// pass ended.
    private func queueFlush() {
        guard holding, held != nil, !flushQueued else { return }
        flushQueued = true
        later { [weak self] in
            self?.flushQueued = false
            self?.flush()
        }
    }

    private func flush() {
        guard holding, held != nil else { return }
        // The view moved since it last reported (a wheel step of yours, handled before this ran): scrolling from the
        // old place would take that step back. Its report comes next and settles where the held row should be.
        if let current = currentOffset(), abs(current - offset) > 0.5 { return }
        let target = heldTop - heldInView
        // The view did not move since: steps that moved nothing (at the top already) are not carried to a later move.
        rowMoved = 0
        clearSteps()
        guard abs(target - offset) > 0.5 else { return }
        offset = target
        scroll(target)
    }

    /// The held row is no longer drawn: it went into a fold (a finished turn folds its steps under its first one) or
    /// was replaced. The row that starts right above it is held instead, so what takes its place stays where it was.
    private func holdRowAbove() {
        let above = tops.map { (id: $0.key, top: stackTop + $0.value) }
            .filter { $0.top <= heldTop + 0.5 }
            .max { $0.top < $1.top }
        hold(above, at: heldTop - heldInView)
    }

    /// Holds the first row that starts in view with the view at `base` (else none: the view stands inside one tall row).
    private func pick(at base: Double) {
        let viewTop = base + insetTop
        let first = tops.map { (id: $0.key, top: stackTop + $0.value) }
            .filter { $0.top >= viewTop - 0.5 && $0.top <= viewTop + container }
            .min { $0.top < $1.top }
        // Inside a single tall row (a long answer) the row that runs through the view is held.
        let through = first ?? tops.map { (id: $0.key, top: stackTop + $0.value) }
            .filter { $0.top < viewTop }
            .max { $0.top < $1.top }
        hold(through, at: base)
    }

    /// Holds `row` where it stands in the view with the view at `base`.
    private func hold(_ row: (id: AnyHashable, top: Double)?, at base: Double) {
        if row?.id != held { rewrap = nil }
        held = row?.id
        heldTop = row?.top ?? 0
        heldInView = heldTop - base
        rowMoved = 0
    }
}
