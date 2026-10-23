import Foundation

// Live Activities for the companion: one activity per session that works on the Mac, on the Lock Screen and in the
// Dynamic Island. This file is shared by the Mac app, the iPhone app and its widget extension, and depends on Foundation
// only (the widget compiles nothing else from this package), so the rules are tested on Linux.
//
// How it runs (docs/COMPANION.md › Live Activities):
// - The phone hands the Mac two kinds of tokens (`LiveActivityRegistration`): its push-to-start token, and the update
//   token of every activity that exists on it.
// - The Mac decides what each phone should see (`LiveActivityPlanner`) and sends `liveactivity` pushes with the user's own
//   APNs key (`LiveActivityPayload`): start when a session begins to work, update when its phase changes, end when it is
//   done or failed. A finished result stays up for 15 minutes; a stale date makes a dead Mac show "out of date" instead of
//   a spinner that never stops.

/// What a session is doing, as the activity shows it.
enum LiveActivityPhase: String, Codable, CaseIterable, Sendable {
    case working, waiting, done, failed

    /// Done and failed end the activity.
    var isFinished: Bool { self == .done || self == .failed }

    /// From `SessionDigest.attention` (`AgentAttention` raw values) and whether something waits on you.
    init(attention: String, waiting: Bool) {
        if waiting { self = .waiting; return }
        switch attention {
        case "working": self = .working
        case "approval", "input": self = .waiting
        case "failed", "limited": self = .failed
        default: self = .done
        }
    }
}

/// The fixed part of an activity (ActivityKit's attributes). The widget extension makes this `ActivityAttributes`; the
/// type name is what a push-to-start names in `attributes-type`, so it must not change.
struct NookActivityAttributes: Codable, Hashable, Sendable {
    /// `SessionDigest.id`.
    var session: String
    /// The session's folder; empty when titles are kept out of pushes.
    var project: String
    /// "Claude Code", "Codex".
    var agent: String
    /// The title when the activity started; the content's title wins when it has one.
    var title: String
}

/// What changes (ActivityKit's content state). Plain numbers and strings only: the Mac's JSON must decode as-is.
struct LiveActivityContent: Codable, Hashable, Sendable {
    var phase: LiveActivityPhase
    /// Empty when titles are kept out of pushes.
    var title: String
    var model: String
    /// When this phase began, in seconds since 1970 (a timer counts from it while working).
    var since: Double
}

/// A session as the planner sees it, already cut to what may travel through Apple.
struct LiveActivitySnapshot: Equatable, Sendable {
    var session: String
    var project: String
    var title: String
    var agent: String
    var model: String
    var phase: LiveActivityPhase

    var attributes: NookActivityAttributes { NookActivityAttributes(session: session, project: project, agent: agent, title: title) }
}

/// One push to one phone.
struct LiveActivityAction: Equatable, Sendable {
    enum Event: String, Sendable { case start, update, end }

    var event: Event
    var session: String
    /// For `start` only: a push-to-start creates the activity with these.
    var attributes: NookActivityAttributes?
    var content: LiveActivityContent
    var staleDate: Date?
    /// For `end`: how long the final state stays on the Lock Screen.
    var dismissalDate: Date?
    /// Priority 10 (a phase change); otherwise 5, which iOS does not count against the activity's budget the same way.
    var urgent: Bool
}

/// What the phone tells the Mac about Live Activities (`CompanionOp.liveActivity`).
struct LiveActivityRegistration: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// The push-to-start token (iOS 17.2+): the Mac may start an activity for a session that begins to work.
        case pushToStart
        /// The update token of the activity for `session`.
        case activity
        /// The activity for `session` ended or was dismissed on the phone: its token is no use any more.
        case ended
        /// The switch in the app was turned off: forget every token and send nothing.
        case off
    }

    var kind: Kind
    /// Hex, for `pushToStart` and `activity`.
    var token: String?
    var session: String?
    /// The APNs environment of the token: a development build has sandbox tokens.
    var production: Bool

    init(kind: Kind, token: String? = nil, session: String? = nil, production: Bool = true) {
        self.kind = kind; self.token = token; self.session = session; self.production = production
    }

    /// Whether the Mac may store what this says. A token goes into a URL on Apple's host: hex only.
    var isValid: Bool {
        switch kind {
        case .pushToStart: return token.map(Self.validToken) ?? false
        case .activity: return (token.map(Self.validToken) ?? false) && (session.map(Self.validSession) ?? false)
        case .ended: return session.map(Self.validSession) ?? false
        case .off: return true
        }
    }

    /// Activity tokens are longer than device tokens; any even-length hex within reason.
    static func validToken(_ text: String) -> Bool {
        text.count >= 32 && text.count <= 512 && text.count % 2 == 0 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    static func validSession(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 200 && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Decides, per phone, which `liveactivity` pushes to send for the sessions as they are now. Called on every change and
/// on a timer; it sends nothing when nothing needs telling, so calling it often is fine.
struct LiveActivityPlanner: Sendable {
    /// A done or failed session stays on the Lock Screen this long.
    static let finishedVisible: TimeInterval = 15 * 60
    /// Past this without a word from the Mac the activity shows as out of date.
    static let staleAfter: TimeInterval = 10 * 60
    /// A working session is refreshed this often (priority 5), which moves its stale date on.
    static let heartbeat: TimeInterval = 4 * 60
    /// A new title or model waits this long after the last push; a phase change waits `minPhaseInterval`.
    static let minUpdateInterval: TimeInterval = 30
    static let minPhaseInterval: TimeInterval = 5
    /// After a session's activity ended (or a start failed), no new one for it within this.
    static let startCooldown: TimeInterval = 60
    /// iOS allows a handful of activities per app; Nook keeps to this many at once.
    static let maxActivities = 5

    struct Tracked: Equatable, Sendable {
        var attributes: NookActivityAttributes
        /// What the phone was last told; nil for an activity the phone started itself and the Mac has not updated yet.
        var sent: LiveActivityContent?
        var sentAt: Date?
        /// What it should show now.
        var desired: LiveActivityContent
    }

    private(set) var tracked: [String: Tracked] = [:]
    private var ended: [String: Date] = [:]

    init() {}

    /// `canStart`: the phone gave a push-to-start token. `tokens`: sessions whose activity the phone gave an update token for.
    mutating func plan(_ snapshots: [LiveActivitySnapshot], canStart: Bool, tokens: Set<String>, now: Date) -> [LiveActivityAction] {
        ended = ended.filter { now.timeIntervalSince($0.value) < Self.startCooldown }
        var actions: [LiveActivityAction] = []
        var current: [String: LiveActivitySnapshot] = [:]
        for snapshot in snapshots where current[snapshot.session] == nil { current[snapshot.session] = snapshot }

        // Finished, or gone from the Mac's list (archived, removed): the activity ends.
        for id in tracked.keys.sorted() {
            guard let entry = tracked[id] else { continue }
            let snapshot = current[id]
            guard snapshot == nil || snapshot?.phase.isFinished == true else { continue }
            var content = entry.desired
            if let snapshot {
                content = Self.content(snapshot, since: now)
            }
            tracked[id] = nil
            ended[id] = now
            guard tokens.contains(id) else { continue }
            actions.append(LiveActivityAction(event: .end, session: id, attributes: nil, content: content, staleDate: nil,
                                              dismissalDate: now.addingTimeInterval(snapshot == nil ? 0 : Self.finishedVisible),
                                              urgent: snapshot != nil))
        }

        for snapshot in snapshots where !snapshot.phase.isFinished && current[snapshot.session] == snapshot {
            let id = snapshot.session
            if var entry = tracked[id] {
                let since = entry.desired.phase == snapshot.phase ? entry.desired.since : now.timeIntervalSince1970
                entry.desired = Self.content(snapshot, since: Date(timeIntervalSince1970: since))
                if tokens.contains(id), let update = Self.update(&entry, now: now) { actions.append(update) }
                tracked[id] = entry
            } else if tokens.contains(id) {
                // The phone started this one itself (the app was open): take it over.
                var entry = Tracked(attributes: snapshot.attributes, sent: nil, sentAt: nil, desired: Self.content(snapshot, since: now))
                if let update = Self.update(&entry, now: now) { actions.append(update) }
                tracked[id] = entry
            } else if canStart, tracked.count < Self.maxActivities, ended[id] == nil {
                let content = Self.content(snapshot, since: now)
                tracked[id] = Tracked(attributes: snapshot.attributes, sent: content, sentAt: now, desired: content)
                actions.append(LiveActivityAction(event: .start, session: id, attributes: snapshot.attributes, content: content,
                                                  staleDate: now.addingTimeInterval(Self.staleAfter), dismissalDate: nil, urgent: true))
            }
        }
        return actions
    }

    /// A push for this session failed for good (a start that did not arrive, a dead token): stop following it for a while.
    mutating func forget(_ session: String, now: Date) {
        tracked[session] = nil
        ended[session] = now
    }

    private static func update(_ entry: inout Tracked, now: Date) -> LiveActivityAction? {
        let age = entry.sentAt.map { now.timeIntervalSince($0) } ?? .infinity
        let phaseChanged = entry.sent?.phase != entry.desired.phase
        let changed = entry.sent != entry.desired
        guard (phaseChanged && age >= minPhaseInterval) || (changed && age >= minUpdateInterval) || age >= heartbeat else { return nil }
        entry.sent = entry.desired
        entry.sentAt = now
        return LiveActivityAction(event: .update, session: entry.attributes.session, attributes: nil, content: entry.desired,
                                  staleDate: now.addingTimeInterval(staleAfter), dismissalDate: nil, urgent: phaseChanged)
    }

    static func content(_ snapshot: LiveActivitySnapshot, since: Date) -> LiveActivityContent {
        LiveActivityContent(phase: snapshot.phase, title: snapshot.title, model: snapshot.model, since: since.timeIntervalSince1970)
    }
}

/// The APNs side of a Live Activity push: its type, topic and JSON body.
enum LiveActivityPayload {
    static let pushType = "liveactivity"

    /// Live Activity pushes go to the app's bundle id with this suffix.
    static func topic(bundleID: String) -> String { bundleID + ".push-type.liveactivity" }

    /// The JSON body. `alert` (already in the Mac user's language) is only used for a start, which needs one.
    static func make(_ action: LiveActivityAction, now: Date, alert: (title: String, body: String)? = nil) -> [String: Any] {
        var aps: [String: Any] = [
            "timestamp": Int(now.timeIntervalSince1970),
            "event": action.event.rawValue,
            "content-state": dictionary(action.content)
        ]
        if let stale = action.staleDate { aps["stale-date"] = Int(stale.timeIntervalSince1970) }
        if let dismissal = action.dismissalDate { aps["dismissal-date"] = Int(dismissal.timeIntervalSince1970) }
        if action.event == .start, let attributes = action.attributes {
            aps["attributes-type"] = String(describing: NookActivityAttributes.self)
            aps["attributes"] = dictionary(attributes)
            if let alert { aps["alert"] = ["title": alert.title, "body": alert.body] }
        }
        return ["aps": aps]
    }

    private static func dictionary<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
