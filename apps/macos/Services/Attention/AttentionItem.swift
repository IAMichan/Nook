import Foundation

/// Something that may need you, from any source, reduced to what ranking needs: what it is about, what it asks of you,
/// how urgent it is and how long it waited. Today, the starter suggestions, the menu bar and the phone's home all rank
/// these with the same `AttentionScorer`, so they agree on what comes first. Foundation only; tested in
/// AttentionScorerTests.
struct AttentionItem: Equatable, Identifiable, Sendable {
    /// What it asks of you, most pressing first.
    enum NeedsYou: Int, Comparable, CaseIterable, Sendable {
        /// Something waits for your yes or no (an agent's permission request).
        case approval
        /// Someone asked you something (an agent's question).
        case question
        /// Someone waits for your answer (a chat you owe a reply).
        case reply
        /// Something waits for you to look at it (a pull request to review).
        case review
        /// Something broke (a failed session or build, a connector that stopped).
        case failure
        /// Good to know (an event coming up, a birthday, an open loop).
        case info

        static func < (lhs: NeedsYou, rhs: NeedsYou) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where it comes from, as `AttentionFeedback` and `NoticeSource` name it ("agents", "chats", "calendar", "github").
    var source: String
    /// Stable id within everything ranked together.
    var id: String
    /// The app or connector within the source ("codex", "whatsapp"); empty when none.
    var app: String = ""
    /// What it is about (a session, a chat, a pull request), for the feedback on that one thing.
    var subject: String = ""
    /// The person it is about, when there is one.
    var person: String?
    var needsYou: NeedsYou
    /// When it is due or starts (a meeting, a birthday's day); nil when it has no time.
    var deadline: Date?
    /// Since when it waits on you; nil when unknown.
    var since: Date?
    /// You can act on it right here (answer, allow, open the review), not only look.
    var actionable = true
}

/// Ranks attention items: a few plain rules (what it asks, how soon it is due, how long it waited) and what you did with
/// such items before (`AttentionFeedback`). Higher is more important.
struct AttentionScorer: Sendable {
    var feedback: AttentionFeedback
    var now: Date

    init(feedback: AttentionFeedback = AttentionFeedback(), now: Date = Date()) {
        self.feedback = feedback
        self.now = now
    }

    /// The base of each kind of need: an approval comes before a question, a question before a reply, and so on.
    static func base(_ need: AttentionItem.NeedsYou) -> Double {
        switch need {
        case .approval: return 100
        case .question: return 90
        case .failure: return 70
        case .reply: return 60
        case .review: return 55
        case .info: return 30
        }
    }

    /// How much a single item counts. Rules: its need, then a deadline close by (up to +25 within the hour, less further
    /// away, +20 when it already passed and still is open), waiting longer (up to +10 after a day), and being actionable
    /// here (+5). Feedback moves it at most ±10.
    func score(_ item: AttentionItem) -> Double {
        var score = Self.base(item.needsYou)
        if let deadline = item.deadline {
            let ahead = deadline.timeIntervalSince(now)
            if ahead < 0 {
                score += item.needsYou == .info ? 0 : 20
            } else if ahead <= 3600 {
                score += 25
            } else if ahead <= 3 * 3600 {
                score += 15
            } else if ahead <= 24 * 3600 {
                score += 5
            }
        }
        if let since = item.since {
            let hours = max(0, now.timeIntervalSince(since)) / 3600
            score += min(10, log2(1 + hours) * 2)
        }
        if item.actionable { score += 5 }
        score += 10 * feedback.weight(source: item.source, app: item.app, subject: item.subject.isEmpty ? nil : item.subject, at: now)
        return score
    }

    /// The items, most important first; equal scores keep their order.
    func rank(_ items: [AttentionItem]) -> [AttentionItem] {
        items.enumerated()
            .map { (offset: $0.offset, item: $0.element, score: score($0.element)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.item)
    }

    /// The order of anything that carries an item, most important first; equal scores keep their order.
    func rank<T>(_ values: [T], by item: (T) -> AttentionItem) -> [T] {
        values.enumerated()
            .map { (offset: $0.offset, value: $0.element, score: score(item($0.element))) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
            .map(\.value)
    }

    /// The first item that truly waits on you (an approval, a question, a reply, a review or a failure), if any.
    func topNeed(_ items: [AttentionItem]) -> AttentionItem? {
        rank(items.filter { $0.needsYou != .info }).first
    }
}

extension AttentionItem {
    /// An agent session's item from its state in the Agents list (`AgentAttention`): an approval or a question waits on
    /// you, a failure or a usage limit broke it; anything else asks nothing (nil).
    static func agent(id: String, app: String, attention: AgentAttention, since: Date? = nil) -> AttentionItem? {
        let need: NeedsYou
        switch attention {
        case .approval: need = .approval
        case .input: need = .question
        case .failed, .limited: need = .failure
        default: return nil
        }
        return AttentionItem(source: NoticeSource.agents.rawValue, id: "agent-" + id, app: app, subject: id, needsYou: need, since: since)
    }

    /// A chat whose last word is theirs and that waited (`ChatFollowUps.owed`): a reply you owe. A person who asked
    /// something is still a reply, never above an agent's question; it waited, so it climbs with its age.
    static func owed(_ turn: ChatFollowUpTurn) -> AttentionItem {
        AttentionItem(source: NoticeSource.chats.rawValue, id: "owed-" + turn.chat, app: turn.app, subject: turn.chat,
                      person: turn.name, needsYou: .reply, since: turn.date)
    }

    /// Someone's birthday today (`ChatPersonNotes.birthdays(on:)`): good to know, until the day ends.
    static func birthday(person: String, name: String, on day: Date, calendar: Calendar = .current) -> AttentionItem {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        return AttentionItem(source: "people", id: "birthday-" + person, subject: person, person: name, needsYou: .info,
                             deadline: end, actionable: true)
    }
}
