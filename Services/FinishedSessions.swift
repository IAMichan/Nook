import Foundation

/// Which chats count as finished in the Agents list. Two ways in: you mark a chat as finished, or the agent is done and
/// nothing has happened in the chat for a while (`autoFinishAfter`). A finished chat comes back by itself when the agent
/// starts working in it again, and you can reopen it by hand; a chat you reopened stays open until it has new activity.
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
    /// How long an idle chat stays in the list before it moves to "Finished" by itself.
    static let autoFinishAfter: TimeInterval = 10 * 60
    /// Chats you reopened, and when.
    @Published private(set) var kept: [String: Date]
    private static let limit = 500

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        order = stored
        keys = Set(stored)
        let raw = UserDefaults.standard.dictionary(forKey: Self.keptKey) as? [String: Double] ?? [:]
        kept = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    func mark(_ key: String) {
        guard !key.isEmpty, !keys.contains(key) else { return }
        order.append(key)
        if order.count > Self.limit { order.removeFirst(order.count - Self.limit) }
        keys = Set(order)
        save()
    }

    func reopen(_ key: String) {
        guard keys.contains(key) else { return }
        order.removeAll { $0 == key }
        keys = Set(order)
        save()
    }

    func reopenAll(_ many: Set<String>) {
        let gone = many.intersection(keys)
        guard !gone.isEmpty else { return }
        order.removeAll { gone.contains($0) }
        keys = Set(order)
        save()
    }

    /// You reopen a chat: it leaves "Finished" and stays out of it until the agent has done something new in it.
    func reopenByUser(_ key: String) {
        reopen(key)
        guard !key.isEmpty else { return }
        kept[key] = Date()
        if kept.count > Self.limit {
            let oldest = kept.sorted { $0.value < $1.value }.prefix(kept.count - Self.limit).map(\.key)
            for old in oldest { kept[old] = nil }
        }
        UserDefaults.standard.set(kept.mapValues { $0.timeIntervalSince1970 }, forKey: Self.keptKey)
    }

    func toggle(_ key: String) {
        if contains(key) { reopenByUser(key) } else { mark(key) }
    }

    /// Is this chat finished right now: marked by you, or idle for long enough after the agent was done?
    /// `lastActive` is the last time anything happened in it; nil when that is not known.
    func isFinished(key: String, idle: Bool, lastActive: Date?, now: Date = Date()) -> Bool {
        if keys.contains(key) { return true }
        guard idle, let lastActive, now.timeIntervalSince(lastActive) >= Self.autoFinishAfter else { return false }
        if let reopened = kept[key], reopened >= lastActive { return false }
        return true
    }

    private func save() {
        UserDefaults.standard.set(order, forKey: Self.defaultsKey)
    }

    // MARK: Keys

    /// A conversation of an agent ("Claude Code|<conversation id>"). Without a conversation id the row id is all there is.
    static func key(agent: String, conversation: String?, fallback: String) -> String {
        guard let conversation, !conversation.isEmpty else { return fallback }
        return "\(agent)|\(conversation)"
    }

    static func key(run: WorkspaceRun) -> String {
        key(agent: run.provider.displayName, conversation: run.providerSessionID, fallback: "run:" + run.id.uuidString)
    }
}
