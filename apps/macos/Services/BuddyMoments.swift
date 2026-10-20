import Foundation

/// The small, friendly moments Nook shares on his own: a good morning, a welcome back, a nudge to take a break.
///
/// A friend knows when to be quiet, so moments are rare by design:
/// - a few a day at most (`dailyBudget`), each kind only once or twice, and never two within `minimumGap`;
/// - never while an event in your calendar is going on, while Nook shows something else, or while you are away;
/// - nothing here ever guilt-trips you about being away. Coming back is only ever welcomed.
///
/// Everything here is pure (it gets the time and the signals, and returns what to say), so it can be tested; the app
/// side (`AppModel+Buddy`) gathers the signals, keeps the ledger and shows the moment.
enum BuddyMomentKind: String, Codable, CaseIterable {
    /// The first time you are at your Mac in the morning.
    case morning
    /// Back after being away for a while.
    case welcomeBack
    /// A long stretch without a break.
    case breakTime
    /// Still at it late at night.
    case lateNight
    /// Friday afternoon: the week is nearly done.
    case fridayWrap
    /// Your birthday.
    case birthday
    /// A round number of agent runs finished.
    case milestone
}

/// One moment to show, with what it needs to be put into words.
struct BuddyMoment: Equatable {
    var kind: BuddyMomentKind
    /// Unique per occurrence ("morning@2026-10-20"), so the same moment is never shown twice.
    var id: String
    /// Events in your calendar today (morning), agents that finished while you were away (welcome back), or the
    /// milestone reached.
    var count = 0
    /// Minutes worked without a break (break time).
    var minutes = 0
}

/// How playful Nook's words are. The moments are the same; only the wording changes.
enum BuddyTone: String, CaseIterable, Codable, Identifiable {
    case calm, warm, playful
    var id: String { rawValue }
}

/// What you have been doing, built up from how long the Mac has been idle, sampled every half minute or so.
struct BuddyActivity: Equatable {
    /// You count as away after this long without touching the keyboard or mouse.
    static let awayAfter: TimeInterval = 5 * 60
    /// Away this long or more and coming back is worth a hello.
    static let longAway: TimeInterval = 45 * 60
    /// How long "just started the day" and "just came back" stay true, so a moment can wait for the notch to be free.
    static let freshFor: TimeInterval = 15 * 60

    /// When you were last active.
    private(set) var lastActive: Date?
    /// When the current stretch of work began (no gap of `awayAfter` or more since).
    private(set) var stretchStart: Date?
    /// Your first activity of the current day.
    private(set) var dayStart: Date?
    /// When you came back after a long time away, and how long that was.
    private(set) var returnedAt: Date?
    private(set) var awayFor: TimeInterval = 0

    /// `idle`: seconds since the last keyboard or mouse input.
    mutating func note(idle: TimeInterval, at now: Date, calendar: Calendar = .current) {
        guard idle < Self.awayAfter else { return }
        let activeAt = now.addingTimeInterval(-max(0, idle))
        guard let last = lastActive else {
            lastActive = activeAt
            stretchStart = activeAt
            dayStart = activeAt
            return
        }
        guard activeAt > last else { return }
        let gap = activeAt.timeIntervalSince(last)
        if gap >= Self.awayAfter { stretchStart = activeAt }
        if gap >= Self.longAway {
            returnedAt = activeAt
            awayFor = gap
        }
        if Self.dayKey(activeAt, calendar: calendar) != Self.dayKey(last, calendar: calendar) { dayStart = activeAt }
        lastActive = activeAt
    }

    /// You were active within the last minute or two.
    func isActive(at now: Date) -> Bool {
        lastActive.map { now.timeIntervalSince($0) < 120 } ?? false
    }

    /// You sat down for the first time today a moment ago.
    func justStartedDay(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let start = dayStart else { return false }
        return now.timeIntervalSince(start) < Self.freshFor && Self.dayKey(start, calendar: calendar) == Self.dayKey(now, calendar: calendar)
    }

    /// You came back a moment ago after a long time away: how long you were gone.
    func justReturned(at now: Date) -> TimeInterval? {
        guard let back = returnedAt, now.timeIntervalSince(back) < Self.freshFor else { return nil }
        return awayFor
    }

    /// How long you have been working without a break.
    func stretch(at now: Date) -> TimeInterval {
        guard let start = stretchStart, isActive(at: now) else { return 0 }
        return now.timeIntervalSince(start)
    }

    /// Starts a new stretch: you took a break, or Nook just suggested one.
    mutating func restartStretch(at now: Date) {
        stretchStart = now
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// What Nook already shared, so he does not repeat himself. Stored between launches.
struct BuddyLedger: Codable, Equatable {
    var day = ""
    var shownToday: [String] = []
    var lastShown: Date?
    /// The late-night moment spans midnight, so it is kept apart from the per-day list.
    var lastLateNight: Date?
    /// Milestones already celebrated, ever.
    var milestones: [Int] = []

    /// Starts a fresh day: the budget is per day.
    mutating func roll(to day: String) {
        guard day != self.day else { return }
        self.day = day
        shownToday = []
    }

    func count(_ kind: BuddyMomentKind) -> Int {
        shownToday.filter { $0.hasPrefix(kind.rawValue + "@") }.count
    }

    mutating func record(_ moment: BuddyMoment, at now: Date) {
        shownToday.append(moment.id)
        lastShown = now
        if moment.kind == .milestone { milestones.append(moment.count) }
        if moment.kind == .lateNight { lastLateNight = now }
    }

    var stored: Data? { try? JSONEncoder().encode(self) }

    init() {}

    init(stored: Data?) {
        self = stored.flatMap { try? JSONDecoder().decode(BuddyLedger.self, from: $0) } ?? BuddyLedger()
    }
}

/// Decides which moment, if any, Nook shares now.
enum BuddyPlanner {
    /// Moments per day, whatever kind.
    static let dailyBudget = 4
    /// Never two moments closer together than this.
    static let minimumGap: TimeInterval = 20 * 60
    /// A break is suggested after this long without one.
    static let breakAfter: TimeInterval = 90 * 60
    /// Round numbers of finished agent runs worth celebrating.
    static let milestones = [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]

    struct Signals {
        var now: Date
        var calendar: Calendar = .current
        /// An event in your calendar is going on: say nothing.
        var inEvent = false
        /// Nook can speak up: nothing else is showing in the notch.
        var notchFree = true
        /// You have been active in the last minute or so.
        var active = true
        /// This sample is your first activity today.
        var firstOfDay = false
        /// You just came back after this long away.
        var returnedAfter: TimeInterval?
        /// How long you have been working without a break.
        var stretch: TimeInterval = 0
        /// Events in your calendar for the rest of today (the morning greeting mentions them).
        var eventsToday = 0
        /// Agent runs that finished while you were away.
        var finishedWhileAway = 0
        /// Agent runs finished, ever.
        var finishedTotal = 0
        var birthday: NookMonthDay?
    }

    static func next(_ s: Signals, ledger: BuddyLedger) -> BuddyMoment? {
        guard s.active, s.notchFree, !s.inEvent else { return nil }
        let day = BuddyActivity.dayKey(s.now, calendar: s.calendar)
        var ledger = ledger
        ledger.roll(to: day)
        guard ledger.shownToday.count < dailyBudget else { return nil }
        if let last = ledger.lastShown, s.now.timeIntervalSince(last) < minimumGap { return nil }

        let parts = s.calendar.dateComponents([.hour, .minute, .weekday], from: s.now)
        let hour = parts.hour ?? 12
        let minutes = hour * 60 + (parts.minute ?? 0)
        func once(_ kind: BuddyMomentKind, limit: Int = 1, suffix: String = "") -> String? {
            ledger.count(kind) < limit ? "\(kind.rawValue)@\(day)\(suffix)" : nil
        }

        // A birthday comes first: once, from the morning on.
        if let birthday = s.birthday, birthday.matches(s.now, calendar: s.calendar), hour >= 7, let id = once(.birthday) {
            return BuddyMoment(kind: .birthday, id: id)
        }
        // Good morning: the first time you sit down, between five and half past eleven.
        if s.firstOfDay, minutes >= 5 * 60, minutes < 11 * 60 + 30, let id = once(.morning) {
            return BuddyMoment(kind: .morning, id: id, count: s.eventsToday)
        }
        // Welcome back, at most twice a day; the morning greeting already says hello the first time.
        if let away = s.returnedAfter, away >= BuddyActivity.longAway, !s.firstOfDay,
           let id = once(.welcomeBack, limit: 2, suffix: "#\(ledger.count(.welcomeBack))") {
            return BuddyMoment(kind: .welcomeBack, id: id, count: s.finishedWhileAway)
        }
        // A round number of finished agent runs, celebrated once ever.
        if let reached = milestones.last(where: { $0 <= s.finishedTotal }), !ledger.milestones.contains(reached),
           s.finishedTotal - reached < 5 {
            return BuddyMoment(kind: .milestone, id: "milestone@\(reached)", count: reached)
        }
        // Late at night, once a night.
        if hour >= 23 || hour < 4, ledger.lastLateNight.map({ s.now.timeIntervalSince($0) > 8 * 3600 }) ?? true {
            return BuddyMoment(kind: .lateNight, id: "lateNight@\(day)")
        }
        // A break, at most twice a day, during the day.
        if s.stretch >= breakAfter, (8..<22).contains(hour), let id = once(.breakTime, limit: 2, suffix: "#\(ledger.count(.breakTime))") {
            return BuddyMoment(kind: .breakTime, id: id, minutes: Int(s.stretch / 60))
        }
        // Friday afternoon, once.
        if parts.weekday == 6, minutes >= 16 * 60, minutes < 18 * 60 + 30, let id = once(.fridayWrap) {
            return BuddyMoment(kind: .fridayWrap, id: id)
        }
        return nil
    }

    /// The text key for a moment in a tone; the app adds the numbers.
    static func lineKey(_ moment: BuddyMoment, tone: BuddyTone) -> String {
        var variant = ""
        switch moment.kind {
        case .morning: variant = moment.count == 0 ? ".free" : (moment.count == 1 ? ".one" : ".many")
        case .welcomeBack: variant = moment.count == 0 ? ".quiet" : (moment.count == 1 ? ".one" : ".many")
        default: break
        }
        return "buddy.\(moment.kind.rawValue)\(variant).\(tone.rawValue)"
    }
}
