import Foundation

// When you last looked at each session's conversation and the folds you had open, so coming back lands at the end
// with a line above what is new since. Stored, so decoding is tolerant (older visits also hold where you were reading).

struct TimelineVisit: Codable, Equatable, Sendable {
    /// Folds, groups and thoughts you had open.
    var open: Set<String>
    /// When you left the conversation.
    var lastViewedAt: Date

    init(open: Set<String>, lastViewedAt: Date) {
        self.open = open
        self.lastViewedAt = lastViewedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        open = try c.decodeIfPresent(Set<String>.self, forKey: .open) ?? []
        lastViewedAt = try c.decodeIfPresent(Date.self, forKey: .lastViewedAt) ?? Date(timeIntervalSince1970: 0)
    }
    enum CodingKeys: String, CodingKey { case open, lastViewedAt }
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

/// A conversation always opens at its very end (the latest results, not the latest prompt); what came in since your
/// last visit gets a line above it to scroll back to.
enum TimelineLanding {
    /// A conversation's rows in order, each with its time (nil: a row without one of its own).
    typealias Row = (id: String, date: Date?)

    /// The first row newer than `since`, when something older comes before it (there is nothing to set it apart from
    /// otherwise).
    static func firstNew(_ rows: [Row], since: Date) -> String? {
        guard let index = rows.firstIndex(where: { ($0.date ?? .distantPast) > since }), index > 0 else { return nil }
        return rows[index].id
    }
}

extension TranscriptRow {
    /// When the row happened, for "new since your last visit": a message's time, a fold's first message's.
    var visitDate: Date? {
        switch self {
        case .user(let message), .thinking(let message), .notice(let message), .assistant(let message, _): return message.date
        case .fold(_, _, let rows), .continued(_, _, let rows), .superseded(_, let rows): return rows.lazy.compactMap(\.visitDate).first
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
        case .fold(_, _, let blocks, _), .superseded(_, let blocks): return blocks.lazy.compactMap(\.visitDate).first
        }
    }
}
