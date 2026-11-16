// What the follow-up tick does with your follow-ups (`ChatFollowUps`), the same for every chat app: which "waiting for
// a reply" reminders are due, and which scheduled messages go now or wait for your OK. The tick itself
// (`AppModel.chatFollowUpTick`) settles the follow-ups with the inbox first and then does what this plans. Foundation only,
// so it is tested anywhere.
import Foundation

/// What one tick of the follow-ups does.
struct ChatFollowUpPlan: Equatable, Sendable {
    /// Chats to remind you about now (you marked them "waiting for reply" and the time is up): oldest wait first.
    var reminders: [String] = []
    /// Scheduled messages that go now, through the same checks and audit as a message you send by hand.
    var sends: [ChatScheduledSend] = []
    /// Scheduled messages that should have gone long ago (the Mac slept through their time) or whose chat is gone: they
    /// are not sent by themselves; their chat comes up with the text ready, for you to send or drop.
    var confirm: [ChatScheduledSend] = []

    var isEmpty: Bool { reminders.isEmpty && sends.isEmpty && confirm.isEmpty }
}

enum ChatFollowUpTick {
    /// How often the tick looks, at most.
    static let interval: TimeInterval = 60
    /// A scheduled message more late than this waits for your OK: a "good morning" sent at night is not what you meant.
    static let lateLimit: TimeInterval = 2 * 3600

    /// Whether there is anything to look at: with no waits, snoozes or scheduled messages the tick costs nothing.
    static func hasWork(_ follow: ChatFollowUps) -> Bool {
        !follow.waiting.isEmpty || !follow.snoozed.isEmpty || !follow.scheduled.isEmpty
    }

    /// What is due at `now`. `chats`: the chats Nook holds now (their ids in `ChatInbox`), so a message for a chat that
    /// is gone is not sent blindly. Writing the scheduled message (its text and its time) is your OK for sending it then;
    /// one that comes too late asks again.
    static func plan(_ follow: ChatFollowUps, chats: Set<String>, now: Date) -> ChatFollowUpPlan {
        var plan = ChatFollowUpPlan()
        plan.reminders = follow.dueReminders(now: now).filter { chats.contains($0) }
        for send in follow.dueSends(now: now) {
            let late = now.timeIntervalSince(send.sendAt) > lateLimit
            if late || !chats.contains(send.chat) || send.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plan.confirm.append(send)
            } else {
                plan.sends.append(send)
            }
        }
        return plan
    }
}
