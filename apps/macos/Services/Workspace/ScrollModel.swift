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

    func jumpPill(awayFor: TimeInterval) -> Bool {
        mode == .free && !isFinding && awayFor >= Self.pillDelay
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
