import Foundation

/// Keeps the notices Nook gives by himself from piling up on the notch, the same for every source: agents, chats, Nook
/// and Think Along. A notice it holds back still is in the history under the bell (`logNotice` runs first), it only does
/// not pop up or sound. What waits on you (an agent's question or permission request) always gets through.
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

    /// Whether a notice may pop up now. `key` names what it is about ("agent:<id>", "chat:<id>"). `urgent`: it waits on
    /// you, and always may. `calm`: how long the notch must have been free of other pop-ups (a suggestion waits longer).
    func permits(key: String, urgent: Bool = false, calm: TimeInterval = 0, now: Date = Date()) -> Bool {
        if urgent { return true }
        let recent = shown.filter { now.timeIntervalSince($0.date) < Self.burstWindow }
        if let last = recent.last, now.timeIntervalSince(last.date) < max(Self.gap, calm) { return false }
        if recent.contains(where: { $0.key == key && now.timeIntervalSince($0.date) < Self.sameKeyGap }) { return false }
        return recent.count < Self.burstLimit
    }

    /// The first moment `permits` lets a notice about `key` through, from `now` on (`now` itself when it does already).
    /// A chat held back pops up then, if it still has news, instead of only waiting in the list.
    func nextPermitted(key: String, calm: TimeInterval = 0, now: Date = Date()) -> Date {
        let recent = shown.filter { now.timeIntervalSince($0.date) < Self.burstWindow }
        var at = now
        if let last = recent.last { at = max(at, last.date.addingTimeInterval(max(Self.gap, calm))) }
        if let same = recent.last(where: { $0.key == key }) { at = max(at, same.date.addingTimeInterval(Self.sameKeyGap)) }
        // The burst has room again once enough of it left the window that one more fits.
        if recent.count >= Self.burstLimit {
            at = max(at, recent[recent.count - Self.burstLimit].date.addingTimeInterval(Self.burstWindow))
        }
        return at
    }

    /// Notes a notice that popped up, so the next ones keep their distance.
    mutating func record(key: String, now: Date = Date()) {
        shown = shown.filter { now.timeIntervalSince($0.date) < Self.burstWindow } + [(now, key)]
    }

    /// `permits`, and when it does, `record`.
    mutating func allow(key: String, urgent: Bool = false, calm: TimeInterval = 0, now: Date = Date()) -> Bool {
        guard permits(key: key, urgent: urgent, calm: calm, now: now) else { return false }
        record(key: key, now: now)
        return true
    }
}
