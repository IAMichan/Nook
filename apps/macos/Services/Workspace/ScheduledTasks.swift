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

    /// Only fixed times can be missed; an interval that is overdue simply runs once, now. `catchesUp`: a run that is still
    /// worth having late (Nook's morning mail overview when the Mac was asleep at eight) runs once when the Mac is awake.
    static func shouldSkip(rule: ScheduleRule, scheduledFor: Date, now: Date, catchesUp: Bool = false) -> Bool {
        if catchesUp { return false }
        if case .fixedTime = rule { return isMissed(scheduledFor: scheduledFor, now: now) }
        return false
    }
}

enum ScheduledTaskTarget: Equatable, Sendable, Codable {
    case newSession(projectPath: String, provider: String, profileID: String?)
    /// Every run goes to this session. `fresh`: each run starts a new conversation there (the agent sees nothing of the
    /// earlier runs, the timeline keeps them all); otherwise it continues the conversation.
    case existingSession(id: UUID, fresh: Bool = false)
    /// Nook Chat answers each run itself, in a conversation of its own that the user opens from the notice: "every morning
    /// check my mail and draft the replies". Nook only reads and proposes there; whatever it would send or change waits
    /// in that conversation for the user's own click (a mail draft's Send, a plan's Run), as any chat answer does.
    case nook

    private enum CodingKeys: String, CodingKey { case type, projectPath, provider, profileID, id, fresh }

    var sessionID: UUID? { if case .existingSession(let id, _) = self { return id }; return nil }
    var freshConversation: Bool { if case .existingSession(_, let fresh) = self { return fresh }; return false }
    var isNook: Bool { if case .nook = self { return true }; return false }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if (try? c.decode(String.self, forKey: .type)) == "nook" {
            self = .nook
            return
        }
        if let id = try? c.decode(UUID.self, forKey: .id), (try? c.decode(String.self, forKey: .type)) == "existingSession" {
            self = .existingSession(id: id, fresh: (try? c.decode(Bool.self, forKey: .fresh)) ?? false)
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

/// A scheduled task as Nook Chat proposes it with `schedule_task` ("check my mail every morning at eight and draft the
/// replies"): the tool's input becomes a task for Nook itself (`ScheduledTaskTarget.nook`), or the problems to fix.
/// Foundation only, so the parsing is tested on its own; the user approves the task in the plan before it is saved.
enum NookSchedule {
    enum Kind: String, CaseIterable {
        case daily, weekdays, weekly, interval, once
    }

    struct Draft: Equatable {
        var title: String
        var prompt: String
        var rule: ScheduleRule
        /// Only speak up when something new needs the user: a run that finds nothing leaves no conversation and no notice.
        var quiet = false
    }

    /// What a quiet run answers when nothing new needs the user (`runNote`); Nook then drops that run without a notice.
    static let nothingNew = "NOTHING_NEW"

    /// The answer is the "nothing new" word, alone (also with markup or a full stop around it).
    static func isNothingNew(_ answer: String) -> Bool {
        let bare = answer.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        return bare.uppercased().replacingOccurrences(of: " ", with: "_") == nothingNew
    }

    /// Nook Chat runs on the user's brain, and each run reads sources and writes an answer: more often than every quarter
    /// of an hour costs a lot and helps nobody.
    static let minimumMinutes = 15

    /// The task the input asks for, or what is wrong with it in plain language (for the brain, which fixes and asks again).
    static func parse(_ input: [String: Any], now: Date, calendar: Calendar = .current) -> (draft: Draft?, problems: [String]) {
        func text(_ key: String) -> String {
            ((input[key] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ key: String) -> Int? {
            if let value = input[key] as? Int { return value }
            if let value = input[key] as? Double { return Int(value) }
            return Int(text(key))
        }
        var problems: [String] = []
        let prompt = text("prompt")
        if prompt.isEmpty { problems.append("give the prompt: what Nook does on each run, complete, in the user's words") }
        guard let kind = Kind(rawValue: text("schedule").lowercased()) else {
            problems.append("schedule must be one of: " + Kind.allCases.map(\.rawValue).joined(separator: ", "))
            return (nil, problems)
        }
        var rule: ScheduleRule?
        switch kind {
        case .daily, .weekdays, .weekly:
            guard let time = time(text("time")) else {
                problems.append("give the time as HH:mm (24 hours), for example 08:00")
                break
            }
            var days: Set<Int> = []
            if kind == .weekdays { days = [2, 3, 4, 5, 6] }
            if kind == .weekly {
                var names: [String] = []
                if let list = input["days"] as? [Any] { names = list.compactMap { $0 as? String } }
                else { names = text("days").components(separatedBy: CharacterSet(charactersIn: ", ")).filter { !$0.isEmpty } }
                days = Set(names.compactMap(weekday))
                if days.isEmpty { problems.append("give days for a weekly schedule, for example [\"monday\", \"thursday\"]") }
            }
            rule = .fixedTime(hour: time.hour, minute: time.minute, weekdays: days)
        case .interval:
            guard let minutes = number("every_minutes"), minutes >= minimumMinutes else {
                problems.append("give every_minutes, at least \(minimumMinutes)")
                break
            }
            rule = .interval(seconds: minutes * 60)
        case .once:
            guard let at = moment(text("at"), calendar: calendar) else {
                problems.append("give at as a date and time, for example 2026-11-20T09:00")
                break
            }
            if at <= now { problems.append("at is in the past; pick a moment that is still to come") }
            rule = .once(at: at)
        }
        guard problems.isEmpty, let rule else { return (nil, problems) }
        var title = text("title")
        if title.isEmpty { title = prompt.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) } ?? "" }
        // A check every so many minutes is only worth hearing about when it finds something; an overview at a set time
        // always says how things stand.
        let quiet = (input["quiet"] as? Bool) ?? (text("quiet").lowercased() == "true" ? true : kind == .interval)
        return (Draft(title: String(title.prefix(80)), prompt: prompt, rule: rule, quiet: quiet), [])
    }

    /// "08:00", "8:30", "8.30", "8u30", "8h" or "8" → hour and minute.
    static func time(_ raw: String) -> (hour: Int, minute: Int)? {
        let trimmed = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.range(of: #"^(\d{1,2})(?:[:.hu](\d{2})?)?$"#, options: .regularExpression), match == trimmed.startIndex..<trimmed.endIndex else { return nil }
        let digits = trimmed.split(whereSeparator: { !$0.isNumber }).map(String.init)
        guard let hour = digits.first.flatMap({ Int($0) }), (0...23).contains(hour) else { return nil }
        let minute = digits.count > 1 ? Int(digits[1]) ?? -1 : 0
        guard (0...59).contains(minute) else { return nil }
        return (hour, minute)
    }

    /// A weekday name or abbreviation in English, Dutch, German, French or Spanish → 1 (Sunday) … 7 (Saturday).
    static func weekday(_ raw: String) -> Int? {
        let name = raw.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
        let days: [(Int, [String])] = [
            (1, ["sun", "sunday", "zo", "zondag", "so", "sonntag", "dim", "dimanche", "dom", "domingo"]),
            (2, ["mon", "monday", "ma", "maandag", "mo", "montag", "lun", "lundi", "lunes"]),
            (3, ["tue", "tues", "tuesday", "di", "dinsdag", "dienstag", "mar", "mardi", "martes"]),
            (4, ["wed", "wednesday", "wo", "woensdag", "mi", "mittwoch", "mer", "mercredi", "mie", "miercoles"]),
            (5, ["thu", "thur", "thurs", "thursday", "do", "donderdag", "donnerstag", "jeu", "jeudi", "jue", "jueves"]),
            (6, ["fri", "friday", "vr", "vrijdag", "fr", "freitag", "ven", "vendredi", "vie", "viernes"]),
            (7, ["sat", "saturday", "za", "zaterdag", "sa", "samstag", "sam", "samedi", "sab", "sabado"])
        ]
        return days.first { $0.1.contains(name) }?.0
    }

    /// An ISO 8601 moment, with or without seconds and time zone (without one it is the user's own time).
    static func moment(_ raw: String, calendar: Calendar = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// One line for the plan and the audit log, e.g. "Scheduled task “Morning mail”: every day at 08:00".
    static func summary(_ draft: Draft) -> String {
        "Scheduled task “\(draft.title)”: " + describe(draft.rule)
    }

    /// The schedule in plain English, for the plan and for the brain.
    static func describe(_ rule: ScheduleRule) -> String {
        switch rule {
        case .interval(let seconds):
            return "every \(max(seconds, ScheduleRule.minimumIntervalSeconds) / 60) minutes"
        case .fixedTime(let hour, let minute, let weekdays):
            let at = String(format: "%02d:%02d", hour, minute)
            let valid = weekdays.filter { (1...7).contains($0) }
            if valid.isEmpty { return "every day at \(at)" }
            if valid == [2, 3, 4, 5, 6] { return "every weekday at \(at)" }
            let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
            return "every " + valid.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { names[$0 - 1] }.joined(separator: ", ") + " at \(at)"
        case .webhook:
            return "when its webhook is called"
        case .once(let at):
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return "once, on \(formatter.string(from: at))"
        }
    }

    /// What Nook adds to the prompt of a run, for the brain only (`ReplyContext.note`): nobody is watching, so Nook works
    /// as the user's secretary. It looks through every source the task is about, says what matters, and prepares every
    /// step the user has to take as a proposal (a draft to send, an action to approve), so the user only says yes or what
    /// to change. `since`: the previous run, so a recurring task reports what is new. `quiet`: answer `nothingNew` when
    /// nothing new needs the user.
    static func runNote(title: String, since: Date? = nil, quiet: Bool = false) -> String {
        var parts = [
            "This request is the user's own scheduled task \"\(title)\", which Nook runs by itself; the user is not watching and reads the answer later from a notice.",
            "Work as their personal secretary and do the whole task in one answer, without asking questions first.",
            "Look everything up yourself in every source the task is about. When it asks for everything or names no source, check mail (inbox_mail), chats in every chat app (unread and unanswered ones), the calendar (today and what comes, new invitations), reminders and open loops, pull requests, coding agents that wait for the user, and connected services; open what matters in full."
        ]
        if let since {
            parts.append("The previous run was at \(iso(since)): report what is new or changed since then, plus what still waits for the user.")
        }
        parts += [
            "Start with a short overview, most important first, grouped per topic, not per source.",
            "For everything that needs the user, prepare the step so they only approve it or say what to change: a reply ready to send for every mail (compose_mail with reply_to set to its id, one per mail) and for every chat message (whatsapp_send or chat_send), accepting or moving an appointment or making one (calendar tools), a reminder or open loop for every commitment or deadline, a review or merge for a pull request that is ready, an answer for a coding agent that waits. Write each draft in the language of the person it goes to and in the user's own style.",
            "Nothing is sent or changed without the user's approval; never say you did something you only proposed.",
            "End with what the user has to decide, one short line each."
        ]
        parts.append(quiet
            ? "When nothing new needs the user, answer only \(nothingNew) and nothing else: Nook then does not disturb them."
            : "When nothing needs the user, say so in one line.")
        return parts.joined(separator: " ")
    }

    /// The personal secretary in one click: a briefing each morning, a quiet check at midday that only speaks up when
    /// something new needs the user, and a wrap-up at the end of the working day that prepares tomorrow. Fixed times, so
    /// nothing runs (and costs) at night. The prompts are in the user's language, since they are the request Nook answers.
    static func secretary() -> [Draft] {
        [
            Draft(title: tr("automation.secretary.morning.title"), prompt: tr("automation.secretary.morning.prompt"),
                  rule: .fixedTime(hour: 8, minute: 0, weekdays: [])),
            Draft(title: tr("automation.secretary.midday.title"), prompt: tr("automation.secretary.midday.prompt"),
                  rule: .fixedTime(hour: 13, minute: 0, weekdays: [2, 3, 4, 5, 6]), quiet: true),
            Draft(title: tr("automation.secretary.evening.title"), prompt: tr("automation.secretary.evening.prompt"),
                  rule: .fixedTime(hour: 17, minute: 30, weekdays: [2, 3, 4, 5, 6]))
        ]
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
