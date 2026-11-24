import Foundation

// Timeline scroll behaviour as a state machine without UI. The view reports what
// happened; it reads `shouldFollowEnd` and `cancelQueuedScrolls` back.
//
// A message you send lands at the end, under what came before, and the view follows the reply from there. It used to
// be held near the top with room under it for the reply; the view jumped up when it was sent and again when the room
// gave way, so it no longer is.

struct ScrollModel: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Stick to the end while content grows.
        case following
        /// The reader moved on their own.
        case free
    }

    /// How long the end must be out of view before the "Scroll to end" pill shows.
    static let pillDelay: TimeInterval = 0.15

    private(set) var mode: Mode = .following
    private(set) var isFinding = false
    /// Set by any manual scroll or find: the view must drop scrolls it already queued, or they would yank the reader
    /// back. Cleared by the next programmatic intent (`jumpedToEnd`).
    private(set) var cancelQueuedScrolls = false
    /// Whether the end is in view (within `ScrollFrame.endMargin`), as the view last reported it (`endInView(_:)`).
    private(set) var endIsInView = true
    /// You scrolled down since you last scrolled up: reaching the end now follows it again. Only you heading down does:
    /// the end also comes into view by itself, when the rows above it are measured shorter than the lazy stack guessed
    /// (thousands of points at once in a long session) or fold, and following then pulled the view back down to the end
    /// under your fingers while you scrolled up (measured offscreen on 2026-11-18: every second step up near the end).
    private(set) var headingForEnd = false

    var shouldFollowEnd: Bool { mode == .following }
    /// `userScrolled()` would change nothing now. A view that reports every frame of a scroll (or every step of a drag
    /// on the rail) checks this first, so it writes its state once instead of drawing the whole conversation again for
    /// each frame, which made scrolling stutter.
    var isFreeAfterUserScroll: Bool { mode == .free && cancelQueuedScrolls && !headingForEnd }

    /// You moved the conversation yourself (a step up, a mark on the rail, earlier messages): following stops.
    mutating func userScrolled() {
        mode = .free
        cancelQueuedScrolls = true
        headingForEnd = false
    }

    /// You scrolled down (a wheel or trackpad step down): at the end, following resumes. Only a step tells: the scroll
    /// view also moves down by itself without any size change (a lazy stack placing rows it had guessed), and taking
    /// that for you turned following back on while you scrolled up.
    mutating func userScrolledDown() {
        headingForEnd = true
        if endIsInView { reachedEnd() }
    }

    /// Whether a move of the view while its sizes stayed the same, up and away from the end, is you scrolling: the
    /// keyboard and anything else that sends no scroll-wheel step. A move caused by a size change (the reply growing, a
    /// row measured) never is, nor is a move down: only a step of yours up lets go of the end, never where the view
    /// happens to stand (as in t3code, where the end leaves the view for a frame with every streamed chunk).
    ///
    /// Nothing when nothing changes: the view calls this for every frame of a scroll, and writing its scroll state
    /// each time would draw the whole conversation again for each frame.
    func releases(movedFrom old: ScrollFrame, to new: ScrollFrame) -> Bool {
        guard !new.resized(from: old), !isFreeAfterUserScroll, !Self.movedBySelf(from: old, to: new) else { return false }
        return new.offset < old.offset - 0.5 && new.maxOffset - new.offset > 4
    }

    /// Whether a move of the view up while its sizes stayed the same was the scroll view's own: more than a page at
    /// once, which no step of yours makes (the wheel and trackpad let go before the view moves, and Page Up moves less
    /// than a page). A lazy stack that measures a row anew guesses the height of everything above it again, by thousands
    /// of points; the scroll view keeps its end there in one report and then puts back its old offset in the next, with
    /// no size change (measured offscreen on 2026-11-21). Taken for you, that stopped following and left the view
    /// thousands of points up, a while after you had scrolled down to the end of a finished session.
    static func movedBySelf(from old: ScrollFrame, to new: ScrollFrame) -> Bool {
        !new.resized(from: old) && old.offset - new.offset > max(new.container, 1)
    }

    /// Whether a view that follows the end must be put back at its end after the move from `old` to `new`: its sizes
    /// changed and it is off its end, or the scroll view put back an old offset by itself (`movedBySelf`). Not during a
    /// scroll of the view's own (`animating`: a jump to a mark, the pill), and not while finding (the find owns the
    /// position).
    ///
    /// Also while a scroll of yours runs (a trackpad stroke, its momentum): you only follow while you head for the end
    /// (a step up lets go before the view moves by it), and the end is where that scroll goes. Waiting for the scroll to
    /// come to rest left the view a chunk above the end: a working agent's rows move into the lazy part of the
    /// conversation 16 at a time (`HistoryWindow.lazyRows`), the lazy stack guesses their height again, and the content
    /// above the view changed by thousands of points just as you arrived at the end (measured offscreen on 2026-11-24:
    /// 1763 pt up, in `LongSessionStaysAtEnd`).
    func keepsEnd(movedFrom old: ScrollFrame, to new: ScrollFrame, animating: Bool) -> Bool {
        guard shouldFollowEnd, !isFinding, !animating else { return false }
        return Self.lostEnd(from: old, to: new)
    }

    /// Whether the move from `old` to `new` took a view that follows the end away from it without you: its sizes
    /// changed and it is off its end, or it went up by more than a page at once (`movedBySelf`).
    static func lostEnd(from old: ScrollFrame, to new: ScrollFrame) -> Bool {
        if movedBySelf(from: old, to: new) { return true }
        return new.resized(from: old) && new.maxOffset - new.offset > 0.5
    }

    /// Whether a scroll-wheel or trackpad step of yours over the conversation, before the view moves by it, lets go of
    /// the end: `deltaY` as AppKit gives it (above zero toward the start). Up does, at once, also within the margin of
    /// the end; down never does (`returns(wheel:)`). While an agent works the sizes change on nearly every frame, so
    /// the step itself is the only clear sign of you scrolling.
    func releases(wheel deltaY: Double) -> Bool {
        deltaY > 0.5 && !isFreeAfterUserScroll
    }

    /// Whether a scroll-wheel or trackpad step down heads back to the end (`userScrolledDown`); nothing when it would
    /// change nothing.
    func returns(wheel deltaY: Double) -> Bool {
        deltaY < -0.5 && mode == .free && !headingForEnd
    }

    /// The end came into view or left it (the view reports each change). Coming back to it follows again only when
    /// you scrolled down to it (`userScrolledDown`), never when it came into view by itself, and not while a find owns
    /// the position.
    mutating func endInView(_ inView: Bool) {
        endIsInView = inView
        if inView, headingForEnd { reachedEnd() }
    }

    mutating func findStarted() {
        isFinding = true
        headingForEnd = false
        mode = .free
        cancelQueuedScrolls = true
    }

    mutating func findEnded() { isFinding = false }

    mutating func jumpedToEnd() {
        mode = .following
        headingForEnd = false
        cancelQueuedScrolls = false
    }

    /// The reader is back at the end: following resumes, except while finding (the find owns the position).
    mutating func reachedEnd() {
        guard mode == .free, !isFinding else { return }
        mode = .following
        headingForEnd = false
    }

    /// The "Scroll to end" pill shows only once you scrolled away yourself and the end is out of view; not while you are
    /// at the end: there it showed over a conversation that was already at its last line.
    func showsToEndPill(atEnd: Bool) -> Bool {
        mode == .free && !isFinding && !atEnd
    }

    func jumpPill(awayFor: TimeInterval) -> Bool {
        mode == .free && !isFinding && awayFor >= Self.pillDelay
    }
}

/// The height the end of a conversation keeps while you follow a working agent: never less than it already was.
///
/// While the agent works, its last rows shrink as often as they grow: its thinking after a command is a row of its own
/// until the next command ends, and then folds into the group "Ran 3 commands"; a single command's row becomes that
/// group. The view holds its end in place, so each time the rows above the end came down by what folded away, and the
/// conversation bounced up and down while you only watched. Held at its tallest, a fold leaves room under the rows
/// instead, which the next output fills.
///
/// Let go (back to the rows' own height) when you stop following, when the agent is done, and when `key` changes: a new
/// turn, a block you opened or closed, rows moving into the lazy part above it. Per width, as a layout asks for more
/// than one.
struct HeldHeight: Equatable, Sendable {
    private var key: Int?
    private var tallest: [Double: Double] = [:]

    /// The height to take for rows `natural` high at `width`.
    mutating func height(natural: Double, width: Double, key: Int, holds: Bool) -> Double {
        if !holds || key != self.key {
            self.key = key
            tallest = [:]
        }
        guard holds else { return natural }
        // A layout asks at a few widths (its ideal, zero, the real one); more than that is a resize.
        if tallest[width] == nil, tallest.count >= 8 { tallest = [:] }
        let held = max(natural, tallest[width] ?? 0)
        tallest[width] = held
        return held
    }
}

/// Whether a lazy conversation shows any of its rows, from where the drawn rows stand and what the scroll view shows,
/// both in the conversation's own coordinates. A lazy stack's own reports are not enough for this: the rows it reports
/// in view go stale after a jump, and a row it keeps drawn just outside the view counts as drawn. Where the rows and
/// the view really stand is what the user sees.
enum RowsInView {
    /// The top and bottom of a drawn row.
    struct Span: Equatable, Sendable {
        var top: Double
        var bottom: Double
    }

    /// How far a row must reach into the view to count: a hairline at the edge does not make a conversation readable.
    static let margin = 8.0

    /// `rows` is how many rows the conversation has, `drawn` where the drawn ones stand, `top` and `height` the part
    /// of the conversation in view. Blank: rows to show, and none of them reaches into the view.
    /// `drawnFrom` is where the part drawn in full starts (`ConversationRows`): from there down nothing can be blank, and
    /// what stands under the rows (the live line and its task list, a card, the room held under rows that folded) is
    /// something to see as well. Without it, a view resting on that part counted as blank, and the guard scrolled the
    /// conversation up to its last row and back down (and made it again) while nothing happened.
    static func blank(rows: Int, drawn: some Collection<Span>, top: Double, height: Double, drawnFrom: Double? = nil) -> Bool {
        guard rows > 0, height > margin * 2 else { return false }
        let bottom = top + height
        if let drawnFrom, bottom - margin > drawnFrom { return false }
        return !drawn.contains { $0.bottom - $0.top > 1 && $0.bottom > top + margin && $0.top < bottom - margin }
    }

    /// Whether try `attempt` (0 first) of a blank conversation's recovery makes its scroll view again instead of only
    /// scrolling: from the third try on, every fourth. A lazy stack can get stuck drawing no row at all, even at the end
    /// it was scrolled to (seen on 2026-11-13: 45 rows, none drawn, for minutes of tries); a new scroll view lays its
    /// rows out from scratch, as when the conversation opens.
    static func rebuilds(attempt: Int) -> Bool {
        attempt >= 2 && (attempt - 2) % 4 == 0
    }
}

/// Where a scroll view stands: its offset, the height of its content and of its container, and the room around it.
struct ScrollFrame: Equatable, Sendable {
    var offset = 0.0
    var content = 0.0
    var container = 0.0
    /// The space above and below the content (a composer the conversation scrolls on behind).
    var insetTop = 0.0
    var insetBottom = 0.0

    var minOffset: Double { -insetTop }
    /// The offset at the very end. `container` is the height between the insets already (checked on a real scroll view
    /// with a composer under it and a toolbar above it), so the room under the content does not count again. Counting it
    /// put the end a composer's height further down than the view can go: at its end, a view counted as off its end.
    var maxOffset: Double { max(minOffset, content - container - insetTop) }

    /// How far the view may stand from its end and still count as there (`nearEnd`): t3code's 40 px.
    static let endMargin = 40.0

    /// At its end, or within `endMargin` of it: following goes on from here, and no pill back to the end shows.
    var nearEnd: Bool { maxOffset - offset <= Self.endMargin }

    /// The content, the view, or the room under it changed size since `old`.
    func resized(from old: ScrollFrame) -> Bool {
        content != old.content || container != old.container || insetBottom != old.insetBottom
    }
}

/// Where a session's timeline was left, per session id; bounded so it cannot grow forever.
struct ScrollMemory: Codable, Equatable, Sendable {
    enum Position: Equatable, Sendable {
        case end
        case offset(Double, anchorEventID: UUID?)
    }

    struct Entry: Codable, Equatable, Sendable {
        var sessionID: String
        var position: Position
    }

    static let limit = 100
    /// Oldest first.
    private(set) var entries: [Entry] = []

    init() {}

    mutating func remember(sessionID: String, position: Position) {
        entries.removeAll { $0.sessionID == sessionID }
        entries.append(Entry(sessionID: sessionID, position: position))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func position(for sessionID: String) -> Position? {
        entries.first { $0.sessionID == sessionID }?.position
    }

    mutating func forget(sessionID: String) { entries.removeAll { $0.sessionID == sessionID } }

    private enum CodingKeys: String, CodingKey { case entries }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        entries = Array(decoded.suffix(Self.limit))
    }
}

extension ScrollMemory.Position: Codable {
    private enum CodingKeys: String, CodingKey { case kind, offset, anchor }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(String.self, forKey: .kind)
        if kind == "offset", let offset = try c.decodeIfPresent(Double.self, forKey: .offset) {
            self = .offset(offset, anchorEventID: try c.decodeIfPresent(UUID.self, forKey: .anchor))
        } else {
            self = .end
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .end: try c.encode("end", forKey: .kind)
        case .offset(let offset, let anchor):
            try c.encode("offset", forKey: .kind)
            try c.encode(offset, forKey: .offset)
            try c.encodeIfPresent(anchor, forKey: .anchor)
        }
    }
}
