import Foundation

// What keeps the companion useful while the Mac is out of reach (docs/COMPANION.md, "When the Mac is out of reach"):
// the clock difference to the Mac, notifications that no longer ask for anything, actions from a notification that
// could not be delivered, and the last answer the phone saw, kept for the next launch. Foundation only, so the rules are
// tested on Linux; the phone keeps the files and the notification center.

/// How far the phone's clock is from the Mac's. The Mac refuses a request whose time is more than
/// `CompanionConstants.freshness` off; with `CompanionFeature.clock` it says its own time with that refusal
/// (`CompanionResponse.macTime`), and the phone adds the difference to the time of every later request to that Mac.
enum CompanionClock {
    /// The largest difference the phone takes over: a clock further off than a day is a broken clock, not a time zone.
    static let maxOffset: TimeInterval = 24 * 3600

    /// The difference to add to the phone's time, from the Mac's time in a refusal and the phone's when it came; capped
    /// at a day either way. Nil for a time that is not one.
    static func offset(macTime: Double, phoneTime: Double) -> TimeInterval? {
        guard macTime.isFinite, phoneTime.isFinite, macTime > 0 else { return nil }
        return clamp(macTime - phoneTime)
    }

    /// The time a request carries: the phone's own, moved by the offset (capped).
    static func sent(_ phoneTime: Double, offset: TimeInterval) -> Double { phoneTime + clamp(offset) }

    /// Whether a new offset differs enough from the one in use to be worth trying again at once. A refusal whose time
    /// moves the offset by only seconds means the problem is not the clock.
    static func changed(_ old: TimeInterval, _ new: TimeInterval) -> Bool { abs(old - new) >= 5 }

    private static func clamp(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return max(-maxOffset, min(maxOffset, value))
    }
}

/// Which notifications on the phone ask for something that is no longer waiting: an approval or a question answered on
/// the Mac, or elsewhere. The phone removes them on every list it gets, so the Lock Screen does not keep asking.
enum DeliveredNotifications {
    /// One delivered notification: its identifier and what it carries under "nook" (`APNsPayload.make`,
    /// `RelayPushContent.userInfo`).
    struct Delivered: Equatable, Sendable {
        var id: String
        var session: String?
        var item: String?
        /// The pairing id of the Mac that sent it; nil from a Mac that predates it.
        var mac: String?

        init(id: String, session: String?, item: String?, mac: String?) {
            self.id = id; self.session = session; self.item = item; self.mac = mac
        }

        /// Reads the "nook" dictionary of a notification's user info.
        init(id: String, nook: [String: Any]?) {
            self.init(id: id, session: nook?["session"] as? String, item: nook?["item"] as? String, mac: nook?["mac"] as? String)
        }
    }

    /// The identifiers to remove: notifications of `mac` about an item that is not in `pending`. A notification that
    /// names no Mac is taken as `mac`'s only when `onlyMac` (the phone is paired with one Mac, so it can only be that
    /// one's). Notifications without an item (a finished turn) stay: they ask for nothing.
    static func stale(_ delivered: [Delivered], pending: Set<String>, mac: String, onlyMac: Bool) -> [String] {
        delivered.filter { note in
            guard let item = note.item, !pending.contains(item) else { return false }
            if let from = note.mac { return from == mac }
            return onlyMac
        }.map(\.id)
    }

    /// The ids of what waits on you in a list: approvals and questions.
    static func pending(_ sessions: [SessionDigest]) -> Set<String> { Set(sessions.flatMap { $0.items.map(\.id) }) }
}

/// What a notification's button could not deliver (the Mac was out of reach): a Deny or a Reply, kept a short while to
/// try again when the user taps "Couldn't reach your Mac" or comes back to the app. Each keeps its request id: the Mac
/// answers a repeat with its first answer (`CommandReceipts`), so trying twice never does it twice. An Allow is never
/// kept: allowing something later than you meant is not the same decision.
struct NotificationRetries: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var request: CompanionRequest
        /// The pairing id of the Mac it goes to (`PairedMac.id`).
        var mac: String
        /// When it failed (seconds since 1970).
        var queued: Double
        var id: String { request.id }
    }

    private(set) var entries: [Entry] = []

    static let maxEntries = 20
    /// An approval may wait on the Mac for long, but a Deny tapped a quarter of an hour ago is not a decision about now.
    static let lifetime: TimeInterval = 15 * 60

    /// Only a Deny and a message (Reply) are kept.
    static func keeps(_ request: CompanionRequest) -> Bool {
        switch request.op {
        case .send: return true
        case .decide: return request.allow != true
        default: return false
        }
    }

    /// False when it is not kept (an Allow, another kind, or the list is full).
    @discardableResult
    mutating func add(_ request: CompanionRequest, mac: String, now: Date) -> Bool {
        guard Self.keeps(request), entries.count < Self.maxEntries else { return false }
        guard !entries.contains(where: { $0.id == request.id }) else { return true }
        entries.append(Entry(request: request, mac: mac, queued: now.timeIntervalSince1970))
        return true
    }

    mutating func remove(_ id: String) { entries.removeAll { $0.id == id } }

    /// Drops what waited too long and returns it.
    @discardableResult
    mutating func expire(now: Date) -> [Entry] {
        let limit = now.timeIntervalSince1970 - Self.lifetime
        let old = entries.filter { $0.queued < limit }
        entries.removeAll { $0.queued < limit }
        return old
    }

    func waiting(for mac: String) -> [Entry] { entries.filter { $0.mac == mac } }
    var macs: [String] { Array(Set(entries.map(\.mac))).sorted() }
}

/// The last the phone saw of a Mac, kept for the next launch (`companion-cache-<id>.json` on the phone): the session
/// list with when the Mac answered it, what a new session can start with, and the conversations of the last sessions
/// that were open, so the app shows them at once, marked as not live, and an open session asks only for what came after
/// (`CompanionFeature.resume`).
struct CompanionCache: Codable, Equatable, Sendable {
    struct Timeline: Codable, Equatable, Sendable {
        var session: String
        var entries: [TimelineEntry]
        var saved: Double
    }

    /// When the Mac answered the list (seconds since 1970); 0 when there is none.
    private(set) var saved: Double = 0
    private(set) var sessions: [SessionDigest] = []
    var launch: LaunchOptions?
    /// The most recently saved first.
    private(set) var timelines: [Timeline] = []

    static let maxTimelines = 5
    /// The newest entries of a conversation kept: enough to read on, and to resume from.
    static let maxEntries = 200

    init() {}

    var savedAt: Date? { saved > 0 ? Date(timeIntervalSince1970: saved) : nil }

    /// Keeps a list the Mac answered at `at`; an older one than what is kept changes nothing (false).
    @discardableResult
    mutating func record(sessions list: [SessionDigest], at: Date) -> Bool {
        guard at.timeIntervalSince1970 >= saved else { return false }
        saved = at.timeIntervalSince1970
        sessions = list
        return true
    }

    /// Keeps a session's conversation (its newest entries), as the most recent; the oldest kept one goes past the limit.
    /// An older copy than what is kept changes nothing (false).
    @discardableResult
    mutating func record(timeline entries: [TimelineEntry], session: String, at: Date) -> Bool {
        if let kept = timelines.first(where: { $0.session == session }), kept.saved > at.timeIntervalSince1970 { return false }
        timelines.removeAll { $0.session == session }
        guard !entries.isEmpty else { return true }
        timelines.insert(Timeline(session: session, entries: Array(entries.suffix(Self.maxEntries)), saved: at.timeIntervalSince1970), at: 0)
        if timelines.count > Self.maxTimelines { timelines.removeLast(timelines.count - Self.maxTimelines) }
        return true
    }

    func timeline(_ session: String) -> [TimelineEntry]? { timelines.first { $0.session == session }?.entries }

    /// Every kept conversation by session.
    var allTimelines: [String: [TimelineEntry]] {
        Dictionary(timelines.map { ($0.session, $0.entries) }, uniquingKeysWith: { first, _ in first })
    }
}

extension TimelineDelta {
    /// What the Mac answers a `watch` that names the last entry the phone has (`CompanionFeature.resume`): the entries
    /// from that one on, after the entry before it, so the phone's last entry (an answer that was still being written)
    /// is replaced too. Nil when the Mac does not have that entry, or it is the first: then the whole conversation goes.
    static func resume(_ entries: [TimelineEntry], from last: String?) -> (after: String, entries: [TimelineEntry])? {
        guard let last, let index = entries.lastIndex(where: { $0.id == last }), index > 0 else { return nil }
        return (entries[index - 1].id, Array(entries[index...]))
    }
}

/// Whether the Mac may leave out a push for a phone: it is connected live and in front (`CompanionFeature.foreground`),
/// so what the push would say is already on its screen. Only while the phone was heard from lately: a phone that went
/// away without saying so (a dropped connection, a phone put in a pocket) gets its pushes again.
enum ForegroundPolicy {
    /// The phone pings every `CompanionTiming.pingEvery` while in front; twice that without a word and it counts as gone.
    static let heardWithin: TimeInterval = CompanionTiming.pingEvery * 2

    static func skipsPush(live: Bool, foreground: Bool?, lastHeard: Date, now: Date) -> Bool {
        live && foreground == true && now.timeIntervalSince(lastHeard) <= heardWithin
    }
}

/// How fresh what the phone shows is, apart from whether it is connected (docs/COMPANION.md, "Staying connected"): a live
/// connection gets every change the moment it happens, so what it shows is current however long ago the last change was;
/// answers the phone asks for (an older Mac, or between connections) are as old as the last one.
enum CompanionFreshness: Equatable, Sendable {
    /// Connected live: what shows is current.
    case live
    /// Connected, asking now and then: the last answer came within `recentFor`.
    case current
    /// Connected, but the last answer is `minutes` old.
    case behind(minutes: Int)
    /// Not connected: what shows is from `since` (nil: nothing was ever answered).
    case offline(since: Date?)

    /// Answers older than this read as behind.
    static let recentFor: TimeInterval = 90

    static func of(connected: Bool, live: Bool, lastUpdated: Date?, now: Date) -> CompanionFreshness {
        guard connected else { return .offline(since: lastUpdated) }
        if live { return .live }
        guard let lastUpdated else { return .current }
        let age = now.timeIntervalSince(lastUpdated)
        return age < recentFor ? .current : .behind(minutes: max(1, Int(age / 60)))
    }
}
