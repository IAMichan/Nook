import Foundation

/// Keeps the message you read where it is on screen while something above it changes height: a link's card, a
/// picture, a video's first frame or a sticker that loads as its message comes near view, a message that folds open,
/// a page of older messages drawn above. Without it every such change above the view pushed what you read down, so
/// scrolling back through a chat jumped and never got where you scrolled to.
///
/// It holds one message (the first that starts in view) at its place in the view. A move of the chat with its sizes
/// unchanged is you (or a jump Nook asked for), and moves that place along; a change of size somewhere above that
/// message scrolls the chat by as much, so the message stays put. What changes below it changes nothing you see.
/// A plain object, so the steps of a scroll redraw nothing.
@MainActor
final class TranscriptReadingAnchor {
    /// Each drawn message's frame, in the stack of messages (`TranscriptSelection.space`).
    private var frames: [String: CGRect] = [:]
    /// Where the stack of messages starts in the scroll view's content (under the "Load older messages" button).
    private var stackTop: CGFloat = 0
    /// The message held, and how far below the top of the view it should stay.
    private(set) var held: String?
    private(set) var inView: CGFloat = 0
    private var offset: CGFloat = 0
    private var container: CGFloat = 0
    /// Where the chat was asked to scroll to keep the message: its move that follows is not you.
    private var expected: CGFloat?
    /// Held the last time it was asked: a chat that comes back to holding (it left its newest message, older messages
    /// were drawn) starts from what is in view now, not from a place that went stale meanwhile.
    private var wasHolding = false
    /// Scrolls the chat to this content offset at once.
    var scroll: (CGFloat) -> Void = { _ in }

    /// A message's frame in the stack, or nil once it is no longer drawn.
    func place(_ id: String, at frame: CGRect?, holding: Bool) {
        frames[id] = frame
        guard id == held else { return }
        if frame == nil { held = nil; return }
        if holding, wasHolding { restore() }
    }

    /// The stack of messages moved within the content (the button above it came or went).
    func stack(at top: CGFloat, holding: Bool) {
        stackTop = top
        if holding, wasHolding { restore() }
    }

    /// The chat's scroll geometry changed. `sizesSame`: content and view kept their size, so only the offset moved.
    func moved(from old: CGFloat, to new: CGFloat, container: CGFloat, sizesSame: Bool, holding: Bool) {
        self.container = container
        defer { wasHolding = holding }
        guard holding, wasHolding else {
            // At the newest message (it follows the end) or while older ones are drawn: only noted.
            expected = nil
            offset = new
            pick()
            return
        }
        if let expected, abs(new - expected) < 0.5 {
            self.expected = nil
            offset = new
            return
        }
        // You moved the chat (or a scroll that was asked for): the message moves with it.
        if sizesSame, abs(new - old) > 0.01 {
            expected = nil
            inView -= new - old
        }
        offset = new
        restore()
        // Scrolled out of view: the first message in view now is held instead. Not while a keep is still on its way,
        // which a fresh pick would lose.
        if expected == nil, held == nil || inView < 0 || inView > container { pick() }
    }

    /// Scrolls so the held message is back at its place in the view.
    private func restore() {
        guard let held, let frame = frames[held] else { return }
        let target = stackTop + frame.minY - inView
        guard abs(target - offset) > 0.5 else { return }
        offset = target
        expected = target
        scroll(target)
    }

    /// Holds the first message that starts in view (else the one nearest under it).
    private func pick() {
        var best: (id: String, top: CGFloat)?
        for (id, frame) in frames {
            let top = stackTop + frame.minY
            guard top >= offset - 0.5, best.map({ top < $0.top }) ?? true else { continue }
            best = (id, top)
        }
        held = best?.id
        inView = (best?.top ?? offset) - offset
    }
}
