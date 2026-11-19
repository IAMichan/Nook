import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Which chats count as finished in the Agents list: the ones you marked as finished (by hand, or through the auto-settle
/// rules you switched on in `InboxStore`). A chat that only went quiet stays in the list until you handled it. A finished
/// chat comes back by itself when the agent starts working in it again, and you can reopen it by hand.
/// The notch is quieter: a done session leaves it once nothing has happened in it for a while (`isFinished`).
/// A chat you mark while it still reads as busy (a turn that hangs, a hook that never came) stays finished until that turn
/// ends and a new one starts. A new turn reopens a chat where it starts (`WorkspaceManager.launchTurn`, a hook's
/// `UserPromptSubmit`), not only when the Agents list happens to be on screen to see it work (`reconcile(busy:)`).
///
/// Chats are identified by agent and conversation, not by the row they are shown in, so a mark follows a conversation from
/// a running session to the earlier sessions list.
@MainActor
final class FinishedSessions: ObservableObject {
    static let shared = FinishedSessions()

    @Published private(set) var keys: Set<String>
    /// Oldest first, to keep the list from growing without end.
    private var order: [String]
    private static let defaultsKey = "agents.finishedSessions"
    private static let keptKey = "agents.keptOpenSessions"
    private static let busyKey = "agents.finishedWhileBusy"
    private static let keepsOpenSinceKey = "agents.keepsUnsettledSince"
    private static let autoSettledKey = "agents.autoSettledAt"
    private static let settledAtKey = "agents.settledAt"
    /// How long a done session stays in the notch after its last activity. The Agents list keeps it until you settle it.
    static let autoFinishAfter: TimeInterval = 10 * 60
    /// Chats you reopened, and when.
    @Published private(set) var kept: [String: Date]
    /// A mark that falls off brings its chat back to the list, so keep plenty.
    private nonisolated static let defaultLimit = 5000
    private let defaults: UserDefaults
    private let limit: Int
    /// Chats the auto-settle rules settled, and when, for the line at the end of their conversation. A chat you settle
    /// yourself has no entry: you know you did. The entry goes with the mark.
    @Published private(set) var autoSettled: [String: Date]
    /// When each chat was settled (by you or the auto-settle rules), so the Settled shelf lists what you handled last on
    /// top. Its last activity is no order for that: a hook of an old chat (closing its terminal, a resume) moves it to now.
    /// Marks from before this was kept have no entry. The entry goes with the mark.
    @Published private(set) var settledAt: [String: Date]
    /// Chats you marked while they were busy, until that busy spell ends.
    private var markedWhileBusy: Set<String>
    /// Since when an unsettled chat stays in the Agents list for good. Before, a quiet chat left the list a day after its
    /// last activity without a mark, so an update must not bring back what had already gone (see `isSettled`).
    let keepsOpenSince: Date

    init(defaults: UserDefaults = .standard, limit: Int = FinishedSessions.defaultLimit) {
        self.defaults = defaults
        self.limit = limit
        let stored = defaults.stringArray(forKey: Self.defaultsKey) ?? []
        order = stored
        let storedKeys = Set(stored)
        keys = storedKeys
        let raw = defaults.dictionary(forKey: Self.keptKey) as? [String: Double] ?? [:]
        kept = raw.mapValues { Date(timeIntervalSince1970: $0) }
        markedWhileBusy = Set(defaults.stringArray(forKey: Self.busyKey) ?? []).intersection(storedKeys)
        let auto = defaults.dictionary(forKey: Self.autoSettledKey) as? [String: Double] ?? [:]
        autoSettled = auto.filter { storedKeys.contains($0.key) }.mapValues { Date(timeIntervalSince1970: $0) }
        let times = defaults.dictionary(forKey: Self.settledAtKey) as? [String: Double] ?? [:]
        settledAt = times.filter { storedKeys.contains($0.key) }.mapValues { Date(timeIntervalSince1970: $0) }
        if let since = defaults.object(forKey: Self.keepsOpenSinceKey) as? Date {
            keepsOpenSince = since
        } else {
            keepsOpenSince = Date()
            defaults.set(keepsOpenSince, forKey: Self.keepsOpenSinceKey)
        }
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    /// Settled for the Agents list: marked by you, or quiet for a day already before unsettled chats were kept
    /// (`keepsOpenSince`), when it had left the list by itself. `lastActive` is the last time anything happened in it.
    func isSettled(_ key: String, lastActive: Date) -> Bool {
        keys.contains(key) || Self.leftBefore(keepsOpenSince, lastActive: lastActive)
    }

    /// A chat whose last activity lies more than a day before `since` had already dropped out of the list then.
    nonisolated static func leftBefore(_ since: Date, lastActive: Date) -> Bool {
        lastActive < since.addingTimeInterval(-SessionLiveness.doneLifetime)
    }

    /// When the auto-settle rules settled this chat, while it is still settled; nil when you settled it yourself.
    func autoSettledAt(_ key: String) -> Date? {
        keys.contains(key) ? autoSettled[key] : nil
    }

    /// `busy`: the chat still reads as busy, so the mark must outlast the current turn (see `reconcile(busy:)`).
    /// `automatically`: when the auto-settle rules settled it (`autoSettledAt`); a mark of yours clears that.
    func mark(_ key: String, busy: Bool = false, automatically: Date? = nil, now: Date = Date()) {
        mark([(key: key, busy: busy)], automatically: automatically, now: now)
    }

    /// Marks multiple chats finished in one batch so `UserDefaults` and `@Published` properties update once instead of O(N) times.
    func mark(_ items: [(key: String, busy: Bool)], automatically: Date? = nil, now: Date = Date()) {
        guard !items.isEmpty else { return }
        var busyChanged = false
        var autoChanged = false
        var keysChanged = false
        var currentKeys = keys
        var currentAuto = autoSettled
        var currentSettledAt = settledAt
        var evictIndex = 0
        for (key, busy) in items where !key.isEmpty {
            if busy, markedWhileBusy.insert(key).inserted { busyChanged = true }
            if currentAuto[key] != automatically, automatically != nil || !currentKeys.contains(key) {
                currentAuto[key] = automatically
                autoChanged = true
            }
            guard !currentKeys.contains(key) else { continue }
            order.append(key)
            currentKeys.insert(key)
            currentSettledAt[key] = automatically ?? now
            keysChanged = true
            // Account for evictions immediately so a key evicted earlier in this batch can be re-marked later in it.
            while order.count - evictIndex > limit {
                let evicted = order[evictIndex]
                evictIndex += 1
                currentKeys.remove(evicted)
            }
        }
        if busyChanged { saveBusy() }
        if autoChanged {
            autoSettled = currentAuto
            saveAutoSettled()
        }
        if keysChanged {
            if evictIndex > 0 {
                order.removeFirst(evictIndex)
                currentKeys = Set(order)
            }
            keys = currentKeys
            save()
            settledAt = currentSettledAt
            saveSettledAt()
        }
    }

    /// When this chat was settled, while it is; nil for a mark from before the time was kept.
    func settledTime(_ key: String) -> Date? {
        keys.contains(key) ? settledAt[key] : nil
    }

    func reopen(_ key: String) {
        if markedWhileBusy.remove(key) != nil { saveBusy() }
        if autoSettled.removeValue(forKey: key) != nil { saveAutoSettled() }
        if kept.removeValue(forKey: key) != nil {
            defaults.set(kept.mapValues { $0.timeIntervalSince1970 }, forKey: Self.keptKey)
        }
        guard keys.contains(key) else { return }
        order.removeAll { $0 == key }
        keys = Set(order)
        save()
        saveSettledAt()
    }

    /// The chats that are busy right now. One you marked while it was busy stays finished as long as it stays busy; any other
    /// marked chat that works again is not finished after all. A busy spell that ended frees the mark for the next one.
    func reconcile(busy: Set<String>) {
        let ended = markedWhileBusy.subtracting(busy)
        if !ended.isEmpty {
            markedWhileBusy.subtract(ended)
            saveBusy()
        }
        let gone = busy.subtracting(markedWhileBusy).intersection(keys)
        guard !gone.isEmpty else { return }
        order.removeAll { gone.contains($0) }
        keys = Set(order)
        save()
        if !autoSettled.keys.filter(gone.contains).isEmpty {
            for key in gone { autoSettled[key] = nil }
            saveAutoSettled()
        }
        saveSettledAt()
    }

    /// Marked by you while busy, and still in that busy spell: the list shows it as finished anyway.
    func isMarkedWhileBusy(_ key: String) -> Bool { markedWhileBusy.contains(key) }

    /// You reopen a chat: it leaves "Finished", and a done session shows in the notch again until it has new activity.
    func reopenByUser(_ key: String) {
        reopenByUser([key])
    }

    /// Reopens multiple chats in a single batch, writing `UserDefaults` once.
    func reopenByUser(_ rawKeys: [String]) {
        let valid = rawKeys.filter { !$0.isEmpty }
        guard !valid.isEmpty else { return }
        let target = Set(valid)
        if !markedWhileBusy.isDisjoint(with: target) {
            markedWhileBusy.subtract(target)
            saveBusy()
        }
        if autoSettled.keys.contains(where: target.contains) {
            var nextAuto = autoSettled
            for key in target { nextAuto[key] = nil }
            autoSettled = nextAuto
            saveAutoSettled()
        }
        if !keys.isDisjoint(with: target) {
            order.removeAll { target.contains($0) }
            keys = Set(order)
            save()
            saveSettledAt()
        }
        let now = Date()
        var nextKept = kept
        for key in valid { nextKept[key] = now }
        if nextKept.count > limit {
            let oldest = nextKept.sorted { $0.value < $1.value }.prefix(nextKept.count - limit).map(\.key)
            for old in oldest { nextKept[old] = nil }
        }
        kept = nextKept
        defaults.set(kept.mapValues { $0.timeIntervalSince1970 }, forKey: Self.keptKey)
    }

    func toggle(_ key: String) {
        if contains(key) { reopenByUser(key) } else { mark(key) }
    }

    /// Is this chat out of the notch: marked by you, or idle for long enough after the agent was done? The Agents list
    /// asks `contains` instead. `lastActive` is the last time anything happened in it; nil when that is not known.
    func isFinished(key: String, idle: Bool, lastActive: Date?, now: Date = Date()) -> Bool {
        if keys.contains(key) { return true }
        guard idle, let lastActive, now.timeIntervalSince(lastActive) >= Self.autoFinishAfter else { return false }
        if let reopened = kept[key], reopened >= lastActive { return false }
        return true
    }

    private func save() {
        defaults.set(order, forKey: Self.defaultsKey)
    }

    private func saveAutoSettled() {
        defaults.set(autoSettled.mapValues { $0.timeIntervalSince1970 }, forKey: Self.autoSettledKey)
    }

    /// Keeps only the times of chats that are still settled, so the store shrinks with the marks.
    private func saveSettledAt() {
        let kept = settledAt.filter { keys.contains($0.key) }
        if kept.count != settledAt.count { settledAt = kept }
        defaults.set(kept.mapValues { $0.timeIntervalSince1970 }, forKey: Self.settledAtKey)
    }

    private func saveBusy() {
        defaults.set(Array(markedWhileBusy), forKey: Self.busyKey)
    }

    // MARK: Keys

    /// A conversation of an agent ("Claude Code|<conversation id>"). Without a conversation id the row id is all there is.
    static func key(agent: String, conversation: String?, fallback: String) -> String {
        guard let conversation, !conversation.isEmpty else { return fallback }
        return "\(agent)|\(conversation)"
    }

    /// The conversation id an agent session reported itself: from its hooks, or from the hub key ("<agent>:<session id>",
    /// with the folder as fallback when the agent sent no id). Nil for a process Nook only sees, and for an agent that sent no id.
    nonisolated static func ownConversation(id: String, sessionID: String, cwd: String, detected: Bool) -> String? {
        if !sessionID.isEmpty { return sessionID }
        guard !detected, let colon = id.firstIndex(of: ":") else { return nil }
        let rest = String(id[id.index(after: colon)...])
        return rest.isEmpty || rest == cwd ? nil : rest
    }

    static func key(run: WorkspaceRun) -> String {
        key(agent: run.provider.displayName, conversation: run.providerSessionID, fallback: "run:" + run.id.uuidString)
    }
}

/// When you last looked at each session in the Agents list, so a session that finished while you were elsewhere stands
/// out ("done" in green) until you open it. Kept in UserDefaults; old entries fall away after two weeks.
/// Opening a session must stay cheap: a visit that changes nothing visible (the same session again within a second)
/// publishes nothing, and the write to disk waits half a second so a run of switches costs one write.
@MainActor
final class SessionVisits: ObservableObject {
    static let shared = SessionVisits()
    private static let key = "agents.visits"
    /// How long a write waits for more visits; a crash in that window only loses "seen" marks.
    static let saveDelay: TimeInterval = 0.5
    @Published private var visited: [String: Double]
    private let defaults: UserDefaults
    private var pendingSave: DispatchWorkItem?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = (defaults.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600).timeIntervalSince1970
        visited = stored.filter { $0.value > cutoff }
        #if canImport(AppKit)
        // The core tests also build this file on Linux, where there is no AppKit (and no app to quit).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        #endif
    }

    /// "Mark as unread": the session counts as news again until you open it. Written at once.
    func markUnread(_ id: String) {
        guard !id.isEmpty else { return }
        visited[id] = 0
        flush()
    }

    func visit(_ id: String, at date: Date = Date()) {
        guard let updated = Self.visiting([id], in: visited, at: date) else { return }
        visited = updated
        scheduleSave()
    }

    /// Several sessions seen at once (a multi-select "mark as read"): one publish and one write.
    func visit(_ ids: [String], at date: Date = Date()) {
        guard let updated = Self.visiting(ids, in: visited, at: date) else { return }
        visited = updated
        scheduleSave()
    }

    /// The visits after seeing `ids` at `date`, or nil when that changes nothing: an id already seen within a second
    /// keeps its time.
    private static func visiting(_ ids: [String], in visited: [String: Double], at date: Date) -> [String: Double]? {
        let now = date.timeIntervalSince1970
        var updated = visited
        var changed = false
        for id in ids where !id.isEmpty {
            if let last = updated[id], abs(last - now) < 1 { continue }
            updated[id] = now
            changed = true
        }
        return changed ? updated : nil
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes the visits now, dropping a pending delayed write.
    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        defaults.set(visited, forKey: Self.key)
    }

    /// Finished after the last visit. A session never visited counts only when it finished in the last day, so the list
    /// does not light up with old work the first time.
    func isUnseen(_ id: String, finished: Date) -> Bool {
        if let last = visited[id] { return finished.timeIntervalSince1970 > last + 1 }
        return Date().timeIntervalSince(finished) < 24 * 3600
    }
}
