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

    var shouldFollowEnd: Bool { mode == .following }
    /// `userScrolled()` would change nothing now. A view that reports every frame of a scroll (or every step of a drag
    /// on the rail) checks this first, so it writes its state once instead of drawing the whole conversation again for
    /// each frame, which made scrolling stutter.
    var isFreeAfterUserScroll: Bool { mode == .free && cancelQueuedScrolls }

    mutating func userScrolled() {
        mode = .free
        cancelQueuedScrolls = true
    }

    /// The view moved while its sizes stayed the same: that is you scrolling, also with a mouse wheel, which reports no
    /// scroll phase, and also within the margin `atEnd` allows. Up and off the end stops following at once, so a working
    /// agent's output no longer pulls the view back down under your fingers (it jumped up and down while you scrolled);
    /// down to the end (within `ScrollFrame.endMargin`) follows again. A move caused by a size change (the reply growing, a row measured) is left
    /// to the end-keeping, as is a scroll the view animates itself.
    ///
    /// Only says what to do (`apply`), and nothing when nothing changes: the view calls this for every frame of a scroll,
    /// and writing its scroll state each time would draw the whole conversation again for each frame.
    func reaction(movedFrom old: ScrollFrame, to new: ScrollFrame) -> Reaction? {
        guard !new.resized(from: old) else { return nil }
        let fromEnd = new.maxOffset - new.offset
        if new.offset < old.offset - 0.5, fromEnd > 4 {
            return isFreeAfterUserScroll ? nil : .userScrolled
        }
        if new.offset > old.offset, fromEnd <= ScrollFrame.endMargin, mode == .free, !isFinding {
            return .reachedEnd
        }
        return nil
    }

    /// What a move of the view means for following (`reaction(movedFrom:to:)`).
    enum Reaction: Equatable, Sendable {
        case userScrolled
        case reachedEnd
    }

    mutating func apply(_ reaction: Reaction) {
        switch reaction {
        case .userScrolled: userScrolled()
        case .reachedEnd: reachedEnd()
        }
    }

    mutating func findStarted() {
        isFinding = true
        mode = .free
        cancelQueuedScrolls = true
    }

    mutating func findEnded() { isFinding = false }

    mutating func jumpedToEnd() {
        mode = .following
        cancelQueuedScrolls = false
    }

    /// The reader scrolled back to the end: following resumes, except while finding (the find owns the position).
    mutating func reachedEnd() {
        if mode == .free, !isFinding { mode = .following }
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
    static func blank(rows: Int, drawn: some Collection<Span>, top: Double, height: Double) -> Bool {
        guard rows > 0, height > margin * 2 else { return false }
        let bottom = top + height
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

    /// How far the view may stand from its end and still count as there (`nearEnd`).
    static let endMargin = 48.0

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
