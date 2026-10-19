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

    /// One-minute minimum interval floor. Rows saved before the floor stay readable but do not keep their old rate.
    static let minimumIntervalSeconds = 60

    var isWebhook: Bool { if case .webhook = self { return true }; return false }

    private enum CodingKeys: String, CodingKey { case type, seconds, hour, minute, weekdays }

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
        }
    }
}

enum ScheduleTiming {
    /// Skips a fixed-time run that is more than this late (the Mac slept through it) instead of running it late.
    static let missedGraceSeconds: TimeInterval = 10 * 60

    /// The next run. Intervals count from when the previous run FINISHED, so a slow run drifts the schedule
    /// and runs never pile up. A fixed time is the next matching weekday and wall-clock time after `now`.
    /// Webhooks have none. A result at or before `now` means "due".
    static func nextRun(rule: ScheduleRule, lastFinished: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        switch rule {
        case .webhook:
            return nil
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
    case existingSession(id: UUID)

    private enum CodingKeys: String, CodingKey { case type, projectPath, provider, profileID, id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(UUID.self, forKey: .id), (try? c.decode(String.self, forKey: .type)) == "existingSession" {
            self = .existingSession(id: id)
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
        case .existingSession(let id):
            try c.encode("existingSession", forKey: .type)
            try c.encode(id, forKey: .id)
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
