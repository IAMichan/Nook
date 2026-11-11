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

    /// You sent a message: the view goes to its end, except while a message you sent before is still held near the top.
    /// The view stands at its end then already, and the new message takes over the room under it once it shows; going to
    /// the end first released that room, so the conversation dropped down and came back up.
    var goesToEndOnSend: Bool { mode != .anchoringNewTurn }

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
///
/// `below` is measured between two rows that are both laid out (the message and the end of the conversation), never
/// from an offset in the whole conversation: a long conversation's height is an estimate that changes as its rows are
/// measured, and scrolling to an offset worked out from it landed in a stretch where the lazy rows drew nothing, which
/// left the whole conversation blank.
struct TurnPin: Equatable, Sendable {
    /// From the top of the message to the end of the conversation, without the room under it.
    let below: Double
    /// Distance between the top edge and the message.
    var anchorOffset = 24.0

    /// The room under the reply that brings the message to `anchorOffset` once the view is at its end, in a view
    /// `container` tall. The container has already given up the composer's height (a safe area inset), so that does
    /// not count again; checked on a real scroll view, where counting it left the message that much lower.
    func room(container: Double) -> Double {
        guard below >= 0 else { return 0 }
        return max(0, container - anchorOffset - below)
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
    var maxOffset: Double { max(minOffset, content + insetBottom - container) }
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
