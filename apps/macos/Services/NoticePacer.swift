import Foundation

/// What kind of interruption something is, for the shared budget (`InterruptionBudget`).
enum InterruptionClass: String, Codable, CaseIterable, Sendable {
    /// Something that happened and that you asked to hear about: an agent that finished, a chat message.
    case notice
    /// A Think Along offer about what is on your screen.
    case suggestion
    /// One of Nook's own moments: a good morning, a break, a milestone.
    case moment
}

/// One day's budget for what Nook starts by himself without being asked: Think Along's offers and the moments share it,
/// so the two together stay rare. Notices (agents, chats) are what you asked to hear about: they are paced
/// (`NoticePacer`), not counted here. What waits on you is never counted. Kept between launches; a new day starts fresh.
/// Pure and `Codable`; tested in NoticePacerTests.
struct InterruptionBudget: Codable, Equatable, Sendable {
    /// Offers and moments together per day.
    static let dailyLimit = 6
    /// Never two unasked interruptions (an offer, a moment) closer together than this, whatever their kind.
    static let unaskedGap: TimeInterval = 10 * 60

    /// At most this many of one class per day; nil for no limit of its own.
    static func limit(_ kind: InterruptionClass) -> Int? {
        switch kind {
        case .notice: return nil
        case .suggestion: return 4
        case .moment: return 4
        }
    }

    /// The least time between two of one class.
    static func gap(_ kind: InterruptionClass) -> TimeInterval {
        switch kind {
        case .notice: return 0
        // Think Along adds its own, longer gap after offers left unanswered (`ThinkAlongBackoff`).
        case .suggestion: return 15 * 60
        case .moment: return 20 * 60
        }
    }

    static let storageKey = "attention.budget.v1"

    /// The day the counts are for (`BuddyActivity.dayKey`).
    private(set) var day = ""
    /// What was spent that day, by class.
    private(set) var spent: [InterruptionClass: Int] = [:]
    /// When each class last interrupted (across days: a gap does not end at midnight).
    private(set) var last: [InterruptionClass: Date] = [:]

    init() {}

    init(stored: Data?) {
        self = stored.flatMap { try? JSONDecoder().decode(InterruptionBudget.self, from: $0) } ?? InterruptionBudget()
    }

    var stored: Data? { try? JSONEncoder().encode(self) }

    /// How many of `kind` went out on `now`'s day.
    func spent(_ kind: InterruptionClass, now: Date, calendar: Calendar = .current) -> Int {
        day == BuddyActivity.dayKey(now, calendar: calendar) ? spent[kind] ?? 0 : 0
    }

    /// Whether one more of `kind` may interrupt now. `extraGap`: a longer gap of the caller's own for this class (Think
    /// Along's backoff). `gapFactor`: how much longer the gaps are for what you keep turning away (`AttentionFeedback`).
    func allows(_ kind: InterruptionClass, now: Date, extraGap: TimeInterval = 0, gapFactor: Double = 1,
                calendar: Calendar = .current) -> Bool {
        guard kind != .notice else { return true }
        if let limit = Self.limit(kind), spent(kind, now: now, calendar: calendar) >= limit { return false }
        let unasked = spent(.suggestion, now: now, calendar: calendar) + spent(.moment, now: now, calendar: calendar)
        guard unasked < Self.dailyLimit else { return false }
        let factor = max(1, gapFactor)
        if let previous = last[kind], now.timeIntervalSince(previous) < max(Self.gap(kind), extraGap) * factor { return false }
        let lastUnasked = [last[.suggestion], last[.moment]].compactMap { $0 }.max()
        if let lastUnasked, now.timeIntervalSince(lastUnasked) < Self.unaskedGap * factor { return false }
        return true
    }

    /// Counts one of `kind` that went out now.
    mutating func spend(_ kind: InterruptionClass, now: Date, calendar: Calendar = .current) {
        let today = BuddyActivity.dayKey(now, calendar: calendar)
        if today != day {
            day = today
            spent = [:]
        }
        spent[kind, default: 0] += 1
        last[kind] = now
    }
}

/// Keeps the notices Nook gives by himself from piling up on the notch, the same for every source: agents, chats, Nook
/// and Think Along. A notice it holds back still is in the notice history (`logNotice` runs first), it only does
/// not pop up or sound. What waits on you (an agent's question or permission request) always gets through.
/// Offers and moments also spend the day's `budget` (`InterruptionBudget`), shared between them.
/// Pure, so the pacing can be tested without a Mac; `AppModel.deliverNotice` asks it before showing anything.
struct NoticePacer: Sendable {
    /// No two pop-ups closer together than this, from any source.
    static let gap: TimeInterval = 20
    /// One thing (an agent session, a chat) pops up at most once in this time; what follows about it waits in the list.
    static let sameKeyGap: TimeInterval = 120
    /// At most `burstLimit` pop-ups within `burstWindow`; above that, only the list until the window has room again.
    static let burstLimit = 4
    static let burstWindow: TimeInterval = 600

    private var shown: [(date: Date, key: String)] = []
    /// The day's budget for offers and moments.
    var budget: InterruptionBudget

    init(budget: InterruptionBudget = InterruptionBudget()) {
        self.budget = budget
    }

    /// Whether a notice may pop up now. `key` names what it is about ("agent:<id>", "chat:<id>"). `urgent`: it waits on
    /// you, and always may. `calm`: how long the notch must have been free of other pop-ups (a suggestion waits longer).
    /// `gapFactor`: the gaps grow for what you keep turning away (`AttentionFeedback.gapFactor`), never shrink.
    /// `priority`: a chat that asks you something or names you (`ChatNoticePriority`) may pass a full burst; the gaps still
    /// hold.
    func permits(key: String, urgent: Bool = false, priority: Bool = false, calm: TimeInterval = 0, gapFactor: Double = 1,
                 now: Date = Date()) -> Bool {
        if urgent { return true }
        let factor = max(1, gapFactor)
        let recent = shown.filter { now.timeIntervalSince($0.date) < Self.burstWindow }
        if let last = recent.last, now.timeIntervalSince(last.date) < max(Self.gap * factor, calm) { return false }
        if recent.contains(where: { $0.key == key && now.timeIntervalSince($0.date) < Self.sameKeyGap * factor }) { return false }
        return priority || recent.count < Self.burstLimit
    }

    /// `permits`, and for an offer or a moment also the day's budget (`InterruptionBudget.allows`).
    func permits(_ kind: InterruptionClass, key: String, calm: TimeInterval = 0, extraGap: TimeInterval = 0,
                 gapFactor: Double = 1, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        budget.allows(kind, now: now, extraGap: extraGap, gapFactor: gapFactor, calendar: calendar)
            && permits(key: key, calm: calm, gapFactor: gapFactor, now: now)
    }

    /// The first moment `permits` lets a notice about `key` through, from `now` on (`now` itself when it does already).
    /// A chat held back pops up then, if it still has news, instead of only waiting in the list.
    func nextPermitted(key: String, priority: Bool = false, calm: TimeInterval = 0, gapFactor: Double = 1, now: Date = Date()) -> Date {
        let factor = max(1, gapFactor)
        let recent = shown.filter { now.timeIntervalSince($0.date) < Self.burstWindow }
        var at = now
        if let last = recent.last { at = max(at, last.date.addingTimeInterval(max(Self.gap * factor, calm))) }
        if let same = recent.last(where: { $0.key == key }) { at = max(at, same.date.addingTimeInterval(Self.sameKeyGap * factor)) }
        // The burst has room again once enough of it left the window that one more fits.
        if !priority, recent.count >= Self.burstLimit {
            at = max(at, recent[recent.count - Self.burstLimit].date.addingTimeInterval(Self.burstWindow))
        }
        return at
    }

    /// Notes a notice that popped up, so the next ones keep their distance.
    mutating func record(key: String, now: Date = Date()) {
        shown = shown.filter { now.timeIntervalSince($0.date) < Self.burstWindow } + [(now, key)]
    }

    /// Notes an offer or a moment that went out: it keeps the notices' distance and spends the day's budget.
    mutating func record(_ kind: InterruptionClass, key: String, now: Date = Date(), calendar: Calendar = .current) {
        record(key: key, now: now)
        if kind != .notice { budget.spend(kind, now: now, calendar: calendar) }
    }

    /// `permits`, and when it does, `record`.
    mutating func allow(key: String, urgent: Bool = false, priority: Bool = false, calm: TimeInterval = 0, gapFactor: Double = 1,
                        now: Date = Date()) -> Bool {
        guard permits(key: key, urgent: urgent, priority: priority, calm: calm, gapFactor: gapFactor, now: now) else { return false }
        record(key: key, now: now)
        return true
    }
}
