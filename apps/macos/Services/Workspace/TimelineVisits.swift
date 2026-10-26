import Foundation

// Where you left each session's conversation and when you last looked at it, so coming back lands where you were (or
// at what is new since) instead of always at the end. Stored, so decoding is tolerant.

struct TimelineVisit: Codable, Equatable, Sendable {
    /// The row at the top of the conversation when you left it; nil when unknown.
    var anchorID: String?
    /// Folds, groups and thoughts you had open.
    var open: Set<String>
    /// You were at the newest message: you come back to the end (or to what is new since).
    var atEnd: Bool
    /// When you left the conversation.
    var lastViewedAt: Date

    init(anchorID: String?, open: Set<String>, atEnd: Bool, lastViewedAt: Date) {
        self.anchorID = anchorID
        self.open = open
        self.atEnd = atEnd
        self.lastViewedAt = lastViewedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchorID = try c.decodeIfPresent(String.self, forKey: .anchorID)
        open = try c.decodeIfPresent(Set<String>.self, forKey: .open) ?? []
        atEnd = try c.decodeIfPresent(Bool.self, forKey: .atEnd) ?? true
        lastViewedAt = try c.decodeIfPresent(Date.self, forKey: .lastViewedAt) ?? Date(timeIntervalSince1970: 0)
    }
    enum CodingKeys: String, CodingKey { case anchorID, open, atEnd, lastViewedAt }
}

/// The visits per session id; bounded, the least recently viewed go first.
struct TimelineVisits: Codable, Equatable, Sendable {
    static let limit = 200
    /// Open folds kept per session: a reader opens a few, not hundreds.
    static let openLimit = 200

    private(set) var visits: [String: TimelineVisit] = [:]

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        visits = try c.decodeIfPresent([String: TimelineVisit].self, forKey: .visits) ?? [:]
    }
    enum CodingKeys: String, CodingKey { case visits }

    func visit(for sessionID: String) -> TimelineVisit? { visits[sessionID] }

    mutating func remember(sessionID: String, visit: TimelineVisit) {
        var visit = visit
        if visit.open.count > Self.openLimit { visit.open = Set(visit.open.sorted().prefix(Self.openLimit)) }
        visits[sessionID] = visit
        while visits.count > Self.limit {
            guard let oldest = visits.min(by: { ($0.value.lastViewedAt, $0.key) < ($1.value.lastViewedAt, $1.key) }) else { break }
            visits[oldest.key] = nil
        }
    }

    mutating func forget(sessionID: String) { visits[sessionID] = nil }
}

/// Where a conversation opens when you come back to it.
enum TimelineLanding: Equatable, Sendable {
    /// The newest message, following what comes in.
    case end
    /// The "New since your last visit" line, right above the row with this id.
    case newSince(String)
    /// The row that was at the top when you left.
    case row(String)

    /// A conversation's rows in order, each with its time (nil: a row without one of its own).
    typealias Row = (id: String, date: Date?)

    /// The first row newer than `since`, when something older comes before it (there is nothing to set it apart from
    /// otherwise).
    static func firstNew(_ rows: [Row], since: Date) -> String? {
        guard let index = rows.firstIndex(where: { ($0.date ?? .distantPast) > since }), index > 0 else { return nil }
        return rows[index].id
    }

    /// Never seen: the end. Left at the end: what came in since, else the end. Left higher up: that row, while it is
    /// still there.
    static func decide(_ rows: [Row], visit: TimelineVisit?) -> TimelineLanding {
        guard let visit else { return .end }
        if visit.atEnd {
            return firstNew(rows, since: visit.lastViewedAt).map(TimelineLanding.newSince) ?? .end
        }
        if let anchor = visit.anchorID, rows.contains(where: { $0.id == anchor }) { return .row(anchor) }
        return .end
    }

    /// The topmost of the rows that are on screen, in the conversation's order.
    static func top(_ rows: [Row], visible: Set<String>) -> String? {
        rows.first { visible.contains($0.id) }?.id
    }
}

extension TranscriptRow {
    /// When the row happened, for "new since your last visit": a message's time, a fold's first message's.
    var visitDate: Date? {
        switch self {
        case .user(let message), .thinking(let message), .assistant(let message, _): return message.date
        case .fold(_, _, let rows): return rows.lazy.compactMap(\.visitDate).first
        case .step, .group, .working, .live, .interrupted: return nil
        }
    }
}

extension TimelineBlock {
    /// When the block happened: its first event's time.
    var visitDate: Date? {
        switch self {
        case .event(let event): return event.date
        case .tools(_, let events, _): return events.first?.date
        case .fold(_, _, let blocks): return blocks.lazy.compactMap(\.visitDate).first
        }
    }
}
