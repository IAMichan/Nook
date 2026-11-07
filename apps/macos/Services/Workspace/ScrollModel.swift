import Foundation

// Timeline scroll behaviour as a state machine without UI. The view reports what
// happened; it reads `shouldFollowEnd`, `anchorMessageID` and `cancelQueuedScrolls` back.

struct ScrollModel: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Stick to the end while content grows.
        case following
        /// A message was just sent: it sits near the top and the reply streams below it.
        case anchoringNewTurn
        /// The reader moved on their own.
        case free
    }

    /// Distance between the top edge and the anchored message.
    let anchorOffset: Double = 24
    /// How long the end must be out of view before the "Scroll to end" pill shows.
    static let pillDelay: TimeInterval = 0.15

    private(set) var mode: Mode = .following
    private(set) var anchorMessageID: UUID?
    private(set) var isFinding = false
    /// Set by any manual scroll or find: the view must drop scrolls it already queued, or they would yank the reader
    /// back. Cleared by the next programmatic intent (`sent`, `jumpedToEnd`).
    private(set) var cancelQueuedScrolls = false

    var shouldFollowEnd: Bool { mode == .following }
    /// `userScrolled()` would change nothing now. A view that reports every frame of a scroll (or every step of a drag
    /// on the rail) checks this first, so it writes its state once instead of drawing the whole conversation again for
    /// each frame, which made scrolling stutter.
    var isFreeAfterUserScroll: Bool { mode == .free && anchorMessageID == nil && cancelQueuedScrolls }

    mutating func userScrolled() {
        mode = .free
        anchorMessageID = nil
        cancelQueuedScrolls = true
    }

    mutating func sent(messageID: UUID) {
        mode = .anchoringNewTurn
        anchorMessageID = messageID
        cancelQueuedScrolls = false
    }

    /// Once the agent starts working with tools and the content no longer fits, the anchor gives way to following.
    mutating func contentGrew(toolActivityStarted: Bool, overflows: Bool) {
        if mode == .anchoringNewTurn, toolActivityStarted, overflows {
            mode = .following
            anchorMessageID = nil
        }
    }

    mutating func findStarted() {
        isFinding = true
        mode = .free
        anchorMessageID = nil
        cancelQueuedScrolls = true
    }

    mutating func findEnded() { isFinding = false }

    mutating func jumpedToEnd() {
        mode = .following
        anchorMessageID = nil
        cancelQueuedScrolls = false
    }

    /// The reader scrolled back to the end: following resumes, except while finding (the find owns the position).
    mutating func reachedEnd() {
        if mode == .free, !isFinding { mode = .following }
    }

    /// The "Scroll to end" pill shows only once you scrolled away yourself and the end is out of view. Not while a
    /// message you sent is held near the top (the reply grows under it and following takes over by itself), and not
    /// while you are at the end: there it showed over a conversation that was already at its last line.
    func showsToEndPill(atEnd: Bool) -> Bool {
        mode == .free && !isFinding && !atEnd
    }

    func jumpPill(awayFor: TimeInterval) -> Bool {
        mode == .free && !isFinding && awayFor >= Self.pillDelay
    }
}

/// A message you just sent, held near the top of the view while the reply grows under it. The end of a conversation can
/// only reach the top of the view with room under the reply; as the reply grows it takes that room over, so what you
/// read stands still and no blank end stays behind.
struct TurnPin: Equatable, Sendable {
    /// How far down the content the message starts: measured once it is laid out, its height from before it came in
    /// until then.
    let messageTop: Double
    /// Distance between the top edge and the message.
    var anchorOffset = 24.0

    /// The room under the reply that brings the message to `anchorOffset`, in `frame`, which holds `current` of it now.
    /// The container has already given up the composer's height (a safe area inset), so that does not count again;
    /// checked on a real scroll view, where counting it left the message that much lower.
    ///
    /// A long conversation's height is an estimate that drops as rows are measured, so `messageTop` can end up past the
    /// end. That says nothing about how much room is needed: taken at face value it left a blank end many screens tall,
    /// and "Scroll to end" landed in it.
    func room(in frame: ScrollFrame, current: Double) -> Double {
        let below = frame.content - current - messageTop
        guard below >= 0 else { return 0 }
        return max(0, frame.container - anchorOffset - below)
    }
}

/// Where a scroll view stands, for a rail that takes the place of its scroll bar: the part in view as a thumb, and the
/// offset a point on the rail scrolls to. Places on the rail run from 0 (the top of the content) to 1 (its end), as the
/// marks of your messages do (`PromptMark.position`), so dragging over a mark brings that message to the top.
struct ScrollFrame: Equatable, Sendable {
    var offset = 0.0
    var content = 0.0
    var container = 0.0
    /// The space above and below the content (a composer the conversation scrolls on behind).
    var insetTop = 0.0
    var insetBottom = 0.0

    var minOffset: Double { -insetTop }
    var maxOffset: Double { max(minOffset, content + insetBottom - container) }

    /// The part in view, from 0 to 1: where it starts and how much of the content it covers.
    var thumb: (start: Double, length: Double) {
        guard content > 0 else { return (0, 1) }
        let length = min(1, max(0, container / content))
        let start = min(1 - length, max(0, (offset - minOffset) / content))
        return (start, length)
    }

    /// The offset that puts the place `fraction` along the content at the top, as far as the content can scroll.
    func offset(at fraction: Double) -> Double {
        min(maxOffset, max(minOffset, minOffset + min(1, max(0, fraction)) * content))
    }

    /// `offset(at:)` for a drag on the rail, over the content's height as it was when the drag began (`start`). The
    /// conversation lays out only what is on screen, so its height changes as the drag passes rows it had not measured
    /// yet; mapping the rail onto that moving height made the conversation jump back and forth under the pointer. The
    /// end of the rail is still the end, also when the content grew during the drag.
    func offset(at fraction: Double, over start: ScrollFrame) -> Double {
        let target = start.offset(at: fraction)
        if target >= start.maxOffset { return maxOffset }
        return min(maxOffset, max(minOffset, target))
    }

    /// This frame measured over `start`'s content height: the thumb a drag that began at `start` shows, so it stays
    /// under the pointer.
    func measured(over start: ScrollFrame) -> ScrollFrame {
        var frame = self
        frame.content = start.content
        return frame
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
