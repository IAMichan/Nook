// What you owe in your chats and what you wait for, the same for every chat app: a chat whose last word is theirs and
// has waited a while ("owed"), a chat you marked "waiting for reply" (with a reminder), a chat you snoozed until later,
// and a message you scheduled to go later. Each app's bridge only fills `ChatFollowUpTurn` from its own data; the rules here are
// shared (docs/INTEGRATIONS.md). Foundation only, so it is tested anywhere.
import Foundation

/// A chat reduced to what follow-up needs: whose word is last, and since when.
struct ChatFollowUpTurn: Equatable, Sendable {
    /// The chat's key in `ChatInbox` (`InboxThread.id`).
    var chat: String
    var app: String
    var name: String
    var kind: ChatKind
    /// When the newest message (not a group notice) was written; nil while the chat holds none.
    var date: Date?
    /// The newest message is yours.
    var lastIsMine: Bool
    /// What the newest message says (its caption for a file); empty when nothing.
    var lastText: String
    var unread: Int

    /// The newest message asks something (`TextKit.asksQuestion`).
    var asksQuestion: Bool { TextKit.asksQuestion(lastText) }
}

extension ChatFollowUpTurn {
    /// The same reduction for every app: an `InboxThread` already is the shared shape.
    init(_ thread: InboxThread) {
        let last = thread.messages.last { !$0.isNotice }
        self.init(chat: thread.id, app: thread.app, name: thread.name, kind: thread.noticeKind, date: last?.date,
                  lastIsMine: last?.isMine ?? false, lastText: last?.text ?? "", unread: thread.unread)
    }
}

/// Your follow-ups, kept by chat id: waiting for a reply, snoozed, and scheduled messages.
struct ChatFollowUps: Codable, Equatable, Sendable {
    struct Waiting: Codable, Equatable, Sendable {
        /// When you marked the chat: a message of theirs after it answers you.
        var since: Date
        /// When Nook reminds you, once; answering the reminder moves it on (`acknowledge`).
        var remindAt: Date
    }

    /// Nook reminds you after a day by default.
    static let defaultWait: TimeInterval = 24 * 3600
    /// A chat owes an answer once their word waited this long: a reply in a minute is not owed yet.
    static let owedAfter: TimeInterval = 4 * 3600
    /// Owed chats older than this are not nagged about: it is past answering for a quick line.
    static let owedUntil: TimeInterval = 14 * 24 * 3600

    var waiting: [String: Waiting] = [:]
    var snoozed: [String: Date] = [:]
    var scheduled: [ChatScheduledSend] = []

    init() {}

    /// Every part is optional when read back, so what was saved before a part existed still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        waiting = try container.decodeIfPresent([String: Waiting].self, forKey: .waiting) ?? [:]
        snoozed = try container.decodeIfPresent([String: Date].self, forKey: .snoozed) ?? [:]
        scheduled = try container.decodeIfPresent([ChatScheduledSend].self, forKey: .scheduled) ?? []
    }

    // MARK: Waiting for a reply

    mutating func markWaiting(chat: String, now: Date, after: TimeInterval = ChatFollowUps.defaultWait) {
        waiting[chat] = Waiting(since: now, remindAt: now.addingTimeInterval(max(60, after)))
    }

    mutating func clearWaiting(chat: String) { waiting[chat] = nil }

    func isWaiting(_ chat: String) -> Bool { waiting[chat] != nil }

    /// The reminder was shown: the next one comes after another day, until they answer or you clear it.
    mutating func acknowledge(chat: String, now: Date) {
        guard var entry = waiting[chat] else { return }
        entry.remindAt = now.addingTimeInterval(Self.defaultWait)
        waiting[chat] = entry
    }

    /// The chats you waited for whose time is up and that are not snoozed: oldest wait first.
    func dueReminders(now: Date) -> [String] {
        waiting.filter { $0.value.remindAt <= now && !isSnoozed($0.key, now: now) }
            .sorted { $0.value.since < $1.value.since }.map(\.key)
    }

    // MARK: Snooze

    mutating func snooze(chat: String, until: Date) { snoozed[chat] = until }

    mutating func unsnooze(chat: String) { snoozed[chat] = nil }

    func isSnoozed(_ chat: String, now: Date) -> Bool { (snoozed[chat] ?? .distantPast) > now }

    // MARK: What you owe

    /// The chats where the last word is theirs and has waited since `owedAfter` (and not longer than `owedUntil`):
    /// questions first, then the oldest. A group, a status update or a channel is not a person waiting on you, and a
    /// snoozed chat comes back when its time is up.
    func owed(_ turns: [ChatFollowUpTurn], now: Date) -> [ChatFollowUpTurn] {
        turns.filter { turn in
            guard turn.kind == .person, !turn.lastIsMine, let date = turn.date, !isSnoozed(turn.chat, now: now) else { return false }
            let age = now.timeIntervalSince(date)
            return age >= Self.owedAfter && age <= Self.owedUntil
        }.sorted {
            if $0.asksQuestion != $1.asksQuestion { return $0.asksQuestion }
            return ($0.date ?? .distantPast) < ($1.date ?? .distantPast)
        }
    }

    /// The chats you wait on, with whether they answered yet: their word after you marked it settles it.
    func answered(_ turn: ChatFollowUpTurn) -> Bool {
        guard let entry = waiting[turn.chat], let date = turn.date else { return false }
        return !turn.lastIsMine && date > entry.since
    }

    /// Forgets what is settled: a wait they answered, a chat gone from the list, a snooze past its time. Returns whether
    /// anything changed, so the caller writes only then.
    @discardableResult
    mutating func settle(with turns: [ChatFollowUpTurn], now: Date) -> Bool {
        let before = self
        let byChat = Dictionary(turns.map { ($0.chat, $0) }, uniquingKeysWith: { first, _ in first })
        for chat in Array(waiting.keys) {
            guard let turn = byChat[chat] else { waiting[chat] = nil; continue }
            if answered(turn) { waiting[chat] = nil }
        }
        for (chat, until) in snoozed where until <= now { snoozed[chat] = nil }
        return self != before
    }

    // MARK: Scheduled send

    mutating func schedule(_ send: ChatScheduledSend) {
        scheduled.removeAll { $0.id == send.id }
        scheduled.append(send)
        scheduled.sort { $0.sendAt < $1.sendAt }
    }

    mutating func cancelScheduled(id: UUID) { scheduled.removeAll { $0.id == id } }

    /// What is due now, oldest first. They are not removed here: the caller sends each through the usual checks and
    /// approval, then calls `cancelScheduled`.
    func dueSends(now: Date) -> [ChatScheduledSend] { scheduled.filter { $0.sendAt <= now } }

    func scheduled(for chat: String) -> [ChatScheduledSend] { scheduled.filter { $0.chat == chat } }
}

/// A message you wrote now and chose to send later. It stays a draft you can still edit or cancel until it goes, and it
/// goes only through the same checks as a message sent by hand (`ChatAction.send`).
struct ChatScheduledSend: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    /// The chat's key in `ChatInbox`.
    var chat: String
    var text: String
    var sendAt: Date

    /// Text and a time in the future: a scheduled message in the past is just a message.
    func isValid(now: Date) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && sendAt > now
    }
}

/// The fixed times "scheduled send" offers. Snoozing a chat offers the snooze options of Settings › Sessions instead
/// (`SnoozeOption`, the same menu as a session's); each of these is one of those options too.
enum ChatLaterOption: String, CaseIterable, Identifiable, Sendable {
    case inAnHour, thisEvening, tomorrowMorning, nextWeek

    var id: String { rawValue }

    /// The snooze option this is.
    var option: SnoozeOption {
        switch self {
        case .inAnHour: return .duration(minutes: 60)
        case .thisEvening: return .time(.today, hour: 18)
        case .tomorrowMorning: return .time(.tomorrow, hour: 9)
        case .nextWeek: return .time(.monday, hour: 9)
        }
    }

    /// When it is, counted from `now`: this evening is 18:00 (tomorrow's when it is past), tomorrow morning 09:00, next
    /// week Monday 09:00 (a week ahead on a Monday).
    func date(from now: Date, calendar: Calendar = .current) -> Date {
        if let end = option.end(from: now, calendar: calendar) { return end }
        return SnoozeOption.time(.tomorrow, hour: 18).end(from: now, calendar: calendar) ?? now.addingTimeInterval(3600)
    }
}
