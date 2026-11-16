import Foundation

// Scheduled tasks: when a task runs next, which runs are skipped, and the guards that keep
// a task from overlapping itself. Foundation only; the lead's service owns the timers, the process and the storage.

/// When a task runs. Decoding is tolerant: a missing field falls back to a safe default and an unknown type becomes
/// `.webhook`, which never fires on its own, so a row written by a newer version cannot start running by surprise.
enum ScheduleRule: Equatable, Sendable, Codable {
    /// Every `seconds` after the previous run finished.
    case interval(seconds: Int)
    /// At `hour:minute` local time on these weekdays (1 = Sunday, like `Calendar`); empty = every day.
    case fixedTime(hour: Int, minute: Int, weekdays: Set<Int>)
    /// Only when its URL receives a signed request.
    case webhook
    /// One run at this moment, then done. A run the Mac slept through runs as soon as it is awake again.
    case once(at: Date)

    /// One-minute minimum interval floor. Rows saved before the floor stay readable but do not keep their old rate.
    static let minimumIntervalSeconds = 60

    var isWebhook: Bool { if case .webhook = self { return true }; return false }
    var isOnce: Bool { if case .once = self { return true }; return false }

    private enum CodingKeys: String, CodingKey { case type, seconds, hour, minute, weekdays, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? c.decode(String.self, forKey: .type)) ?? "" {
        case "interval":
            self = .interval(seconds: (try? c.decode(Int.self, forKey: .seconds)) ?? Self.minimumIntervalSeconds)
        case "fixedTime":
            let days = (try? c.decode([Int].self, forKey: .weekdays)) ?? []
            self = .fixedTime(hour: (try? c.decode(Int.self, forKey: .hour)) ?? 9,
                              minute: (try? c.decode(Int.self, forKey: .minute)) ?? 0,
                              weekdays: Set(days))
        case "once":
            // Without its moment it can never run: a webhook rule, which never fires on its own.
            if let at = try? c.decode(Date.self, forKey: .at) { self = .once(at: at) } else { self = .webhook }
        default:
            self = .webhook
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .interval(let seconds):
            try c.encode("interval", forKey: .type)
            try c.encode(seconds, forKey: .seconds)
        case .fixedTime(let hour, let minute, let weekdays):
            try c.encode("fixedTime", forKey: .type)
            try c.encode(hour, forKey: .hour)
            try c.encode(minute, forKey: .minute)
            try c.encode(weekdays.sorted(), forKey: .weekdays)
        case .webhook:
            try c.encode("webhook", forKey: .type)
        case .once(let at):
            try c.encode("once", forKey: .type)
            try c.encode(at, forKey: .at)
        }
    }
}

enum ScheduleTiming {
    /// Skips a fixed-time run that is more than this late (the Mac slept through it) instead of running it late.
    static let missedGraceSeconds: TimeInterval = 10 * 60

    /// The next run. Intervals count from when the previous run FINISHED, so a slow run drifts the schedule
    /// and runs never pile up. A fixed time is the next matching weekday and wall-clock time after `now`.
    /// Webhooks have none. Once is its moment until it ran, then none. A result at or before `now` means "due".
    static func nextRun(rule: ScheduleRule, lastFinished: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        switch rule {
        case .webhook:
            return nil
        case .once(let at):
            return lastFinished == nil ? at : nil
        case .interval(let seconds):
            let step = TimeInterval(max(seconds, ScheduleRule.minimumIntervalSeconds))
            return (lastFinished ?? now).addingTimeInterval(step)
        case .fixedTime(let hour, let minute, let weekdays):
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            let valid = weekdays.filter { (1...7).contains($0) }
            // Only invalid days were given: nothing can match, which is not the same as "every day".
            if !weekdays.isEmpty && valid.isEmpty { return nil }
            let from = max(now, lastFinished ?? now)
            // Day by day with wall-clock times, so DST shifts, month ends and leap days fall out of `Calendar`.
            // `.nextTime` makes a time inside a spring-forward gap run just after it instead of never.
            for offset in 0...8 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: from),
                      let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                                                    matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                                    direction: .forward),
                      candidate > from else { continue }
                if valid.isEmpty || valid.contains(calendar.component(.weekday, from: candidate)) { return candidate }
            }
            return nil
        }
    }

    /// True when the run is older than the grace period: skip it and reschedule.
    static func isMissed(scheduledFor: Date, now: Date) -> Bool {
        now.timeIntervalSince(scheduledFor) > missedGraceSeconds
    }

    /// Only fixed times can be missed; an interval that is overdue simply runs once, now.
    static func shouldSkip(rule: ScheduleRule, scheduledFor: Date, now: Date) -> Bool {
        if case .fixedTime = rule { return isMissed(scheduledFor: scheduledFor, now: now) }
        return false
    }
}

enum ScheduledTaskTarget: Equatable, Sendable, Codable {
    case newSession(projectPath: String, provider: String, profileID: String?)
    /// Every run goes to this session. `fresh`: each run starts a new conversation there (the agent sees nothing of the
    /// earlier runs, the timeline keeps them all); otherwise it continues the conversation.
    case existingSession(id: UUID, fresh: Bool = false)
    /// Every run asks Nook itself, in a new Nook Chat conversation named after the task: Nook as the user's secretary
    /// ("every morning at 9, what came in since yesterday"). Nook answers with its own tools; whatever it wants to do is
    /// a proposal the user approves, as in any chat, and the finished answer arrives as a notice.
    case nook

    private enum CodingKeys: String, CodingKey { case type, projectPath, provider, profileID, id, fresh }

    var sessionID: UUID? { if case .existingSession(let id, _) = self { return id }; return nil }
    var freshConversation: Bool { if case .existingSession(_, let fresh) = self { return fresh }; return false }
    var isNook: Bool { if case .nook = self { return true }; return false }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(UUID.self, forKey: .id), (try? c.decode(String.self, forKey: .type)) == "existingSession" {
            self = .existingSession(id: id, fresh: (try? c.decode(Bool.self, forKey: .fresh)) ?? false)
            return
        }
        if (try? c.decode(String.self, forKey: .type)) == "nook" {
            self = .nook
            return
        }
        self = .newSession(projectPath: (try? c.decode(String.self, forKey: .projectPath)) ?? "",
                           provider: (try? c.decode(String.self, forKey: .provider)) ?? "claude",
                           profileID: try? c.decode(String.self, forKey: .profileID))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .newSession(let path, let provider, let profileID):
            try c.encode("newSession", forKey: .type)
            try c.encode(path, forKey: .projectPath)
            try c.encode(provider, forKey: .provider)
            try c.encodeIfPresent(profileID, forKey: .profileID)
        case .existingSession(let id, let fresh):
            try c.encode("existingSession", forKey: .type)
            try c.encode(id, forKey: .id)
            if fresh { try c.encode(true, forKey: .fresh) }
        case .nook:
            try c.encode("nook", forKey: .type)
        }
    }
}

enum ScheduledRunStatus: String, Codable, Sendable {
    case running, succeeded, failed
    /// Missed, overlapping or disabled when it came due.
    case skipped
}

enum ScheduleTrigger: String, Codable, Sendable {
    case schedule, manual, webhook
}

struct ScheduledTask: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var prompt: String
    var rule: ScheduleRule
    var target: ScheduledTaskTarget
    var enabled: Bool
    var lastRun: Date?
    var lastStatus: ScheduledRunStatus?
    var lastError: String?
    var nextRun: Date?
    var createdAt: Date

    /// Stored in `lastError` for a run a restart cut off; the view maps this text to a localized one.
    static let interruptedReason = "interrupted by a restart"

    init(id: UUID = UUID(), title: String, prompt: String, rule: ScheduleRule, target: ScheduledTaskTarget,
         enabled: Bool = true, lastRun: Date? = nil, lastStatus: ScheduledRunStatus? = nil, lastError: String? = nil,
         nextRun: Date? = nil, createdAt: Date) {
        self.id = id; self.title = title; self.prompt = prompt; self.rule = rule; self.target = target
        self.enabled = enabled; self.lastRun = lastRun; self.lastStatus = lastStatus; self.lastError = lastError
        self.nextRun = nextRun; self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, prompt, rule, target, enabled, lastRun, lastStatus, lastError, nextRun, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        prompt = (try? c.decode(String.self, forKey: .prompt)) ?? ""
        rule = (try? c.decode(ScheduleRule.self, forKey: .rule)) ?? .webhook
        target = (try? c.decode(ScheduledTaskTarget.self, forKey: .target)) ?? .newSession(projectPath: "", provider: "claude", profileID: nil)
        // A row without the flag stays off: an unknown state must not start running.
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        lastRun = try? c.decode(Date.self, forKey: .lastRun)
        lastStatus = try? c.decode(ScheduledRunStatus.self, forKey: .lastStatus)
        lastError = try? c.decode(String.self, forKey: .lastError)
        nextRun = try? c.decode(Date.self, forKey: .nextRun)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
    }

    /// The next run when the task is (re)planned now: a once-task that already ran stays done, any other rule counts
    /// from now. `keepsHistory` is false when the schedule itself changed, so a new moment for a once-task runs again.
    func plannedRun(now: Date, keepsHistory: Bool = true, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        let finished = rule.isOnce && keepsHistory ? lastRun : nil
        return ScheduleTiming.nextRun(rule: rule, lastFinished: finished, now: now, calendar: calendar)
    }

    /// A once-task that has run: nothing more to do.
    var isDone: Bool { rule.isOnce && lastRun != nil && lastStatus != .running }

    /// One key per task, due time and trigger: a retry of the same firing is recognised and does not start a second run.
    static func fireKey(taskID: UUID, scheduledFor: Date, trigger: ScheduleTrigger) -> String {
        let ms = Int64((scheduledFor.timeIntervalSince1970 * 1000).rounded())
        return "scheduled-task:\(taskID.uuidString):\(ms):\(trigger.rawValue)"
    }

    /// The row after a run ended: records the outcome and schedules the next run from the finish time.
    func finishing(status: ScheduledRunStatus, error: String? = nil, at finished: Date, calendar: Calendar = .current) -> ScheduledTask {
        var copy = self
        copy.lastRun = finished
        copy.lastStatus = status
        copy.lastError = error
        copy.nextRun = enabled ? ScheduleTiming.nextRun(rule: rule, lastFinished: finished, now: finished, calendar: calendar) : nil
        return copy
    }

    /// Rows left `running` by a restart become failed and are rescheduled, so a crashed run neither blocks the task
    /// forever nor counts as success. Other rows are returned unchanged.
    static func recoverInterrupted(tasks: [ScheduledTask], now: Date = Date(), calendar: Calendar = .current) -> [ScheduledTask] {
        tasks.map { task in
            guard task.lastStatus == .running else { return task }
            var copy = task.finishing(status: .failed, error: interruptedReason, at: now, calendar: calendar)
            copy.lastRun = task.lastRun ?? now
            return copy
        }
    }
}

/// Remembers fire keys so a firing that is delivered twice (retry, relay replay) runs once. Bounded.
struct FireLedger: Sendable {
    private var order: [String] = []
    private var seen: Set<String> = []
    let capacity: Int

    init(capacity: Int = 500) { self.capacity = max(1, capacity) }

    /// True the first time `key` is seen.
    mutating func claim(_ key: String) -> Bool {
        guard seen.insert(key).inserted else { return false }
        order.append(key)
        if order.count > capacity { seen.remove(order.removeFirst()) }
        return true
    }
}

/// No overlap: one active run per task. A tick or webhook that finds the task busy is skipped or queued by the caller.
struct RunGate: Sendable {
    private var active: Set<UUID> = []

    func isRunning(_ taskID: UUID) -> Bool { active.contains(taskID) }

    /// False when the task already runs.
    mutating func begin(_ taskID: UUID) -> Bool { active.insert(taskID).inserted }

    mutating func finish(_ taskID: UUID) { active.remove(taskID) }
}

/// Bounds the deliveries a task holds (waiting for its permit plus the running one) at 20 and REJECTS the next
/// one with `queue_full` (HTTP rate limited); it never drops an older delivery, which the sender already got "accepted" for.
struct WebhookQueue: Sendable {
    static let maxQueuedPerTask = 20

    enum Admission: Equatable, Sendable { case accepted, queueFull }

    private var counts: [UUID: Int] = [:]

    func count(_ taskID: UUID) -> Int { counts[taskID] ?? 0 }

    mutating func admit(_ taskID: UUID) -> Admission {
        let n = counts[taskID] ?? 0
        guard n < Self.maxQueuedPerTask else { return .queueFull }
        counts[taskID] = n + 1
        return .accepted
    }

    /// A delivery finished, failed or was dropped (task paused or deleted).
    mutating func release(_ taskID: UUID) {
        let n = (counts[taskID] ?? 1) - 1
        if n <= 0 { counts.removeValue(forKey: taskID) } else { counts[taskID] = n }
    }

    /// The task was deleted or its webhook rotated.
    mutating func forget(_ taskID: UUID) { counts.removeValue(forKey: taskID) }
}

/// The schedule Nook Chat fills in for `schedule_nook_task`: a time of day with optional weekdays, every so many
/// minutes, or one moment. Exactly one of the three. Foundation only, so the rules are tested without the app.
enum NookTaskSchedule {
    enum Problem: Error, Equatable, Sendable {
        /// None, or more than one, of time, every_minutes and at.
        case when
        /// The time is not a time of day ("09:00").
        case time
        /// A weekday that is not one.
        case days
        /// every_minutes below the floor.
        case interval
        /// at is not a date, or lies in the past.
        case moment
    }

    /// Days as the model writes them: "every day", "weekdays", "weekend", or names like "mon, wed, fri" (English, Dutch,
    /// German, French or Spanish, full or the first three letters). 1 = Sunday, like `Calendar`; empty = every day.
    static func weekdays(_ raw: String) -> Set<Int>? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || ["every day", "everyday", "daily", "all", "elke dag", "dagelijks"].contains(text) { return [] }
        if ["weekdays", "workdays", "werkdagen", "weekdagen", "werktage", "semaine", "laborables"].contains(text) { return [2, 3, 4, 5, 6] }
        if ["weekend", "weekends", "wochenende", "fin de semana", "week-end"].contains(text) { return [1, 7] }
        let names: [[String]] = [
            ["sun", "sunday", "zo", "zondag", "son", "sonntag", "dim", "dimanche", "dom", "domingo"],
            ["mon", "monday", "ma", "maandag", "mo", "montag", "lun", "lundi", "lunes"],
            ["tue", "tues", "tuesday", "di", "dinsdag", "die", "dienstag", "mar", "mardi", "martes"],
            ["wed", "wednesday", "wo", "woensdag", "mi", "mit", "mittwoch", "mer", "mercredi", "mie", "miércoles", "miercoles"],
            ["thu", "thur", "thurs", "thursday", "do", "donderdag", "don", "donnerstag", "jeu", "jeudi", "jue", "jueves"],
            ["fri", "friday", "vr", "vrijdag", "fr", "fre", "freitag", "ven", "vendredi", "vie", "viernes"],
            ["sat", "saturday", "za", "zaterdag", "sa", "sam", "samstag", "samedi", "sab", "sáb", "sábado", "sabado"]
        ]
        var days: Set<Int> = []
        for word in text.split(whereSeparator: { ", ;/&".contains($0) }).map(String.init) where !["and", "en", "und", "et", "y"].contains(word) {
            guard let index = names.firstIndex(where: { $0.contains(word) }) else { return nil }
            days.insert(index + 1)
        }
        return days.isEmpty ? nil : days
    }

    /// "09:00", "9:30", "9", "21.15" → hour and minute.
    static func time(_ raw: String) -> (hour: Int, minute: Int)? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { ":.h".contains($0) }).map(String.init)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// What Nook knows about a scheduled question: the user set it up and approved it, nobody is watching right now, and
    /// the earlier runs are in the same conversation.
    static func runNote(_ task: ScheduledTask) -> String {
        "This is the scheduled task \"\(task.title)\" the user set up earlier; it runs now on its own and the user reads the "
            + "answer later. Answer it as a complete update they can read at a glance. Earlier runs of this task are "
            + "the earlier turns of this conversation: focus on what is new or changed since the previous run, and say so when nothing is. Do not ask questions back. Propose any action as usual so the user approves it."
    }

    /// The rule from the tool's input, or what is wrong with it.
    static func rule(_ input: [String: Any], now: Date = Date(), parseDate: (String) -> Date?) -> Result<ScheduleRule, Problem> {
        func text(_ key: String) -> String? {
            let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let minutes = (input["every_minutes"] as? Int) ?? (input["every_minutes"] as? NSNumber)?.intValue
            ?? text("every_minutes").flatMap(Int.init)
        let given = [text("time") != nil, minutes != nil, text("at") != nil].filter { $0 }.count
        guard given == 1 else { return .failure(.when) }
        if let raw = text("time") {
            guard let time = time(raw) else { return .failure(.time) }
            guard let days = weekdays(text("days") ?? "") else { return .failure(.days) }
            return .success(.fixedTime(hour: time.hour, minute: time.minute, weekdays: days))
        }
        if let minutes {
            guard minutes * 60 >= ScheduleRule.minimumIntervalSeconds else { return .failure(.interval) }
            return .success(.interval(seconds: minutes * 60))
        }
        guard let at = text("at").flatMap(parseDate), at > now else { return .failure(.moment) }
        return .success(.once(at: at))
    }
}
