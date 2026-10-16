import Foundation

/// Which chats you marked as finished. A marked chat moves to "Finished" in the Agents list. It comes back by itself when
/// the agent starts working in it again, and you can reopen it by hand.
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
    private static let limit = 500

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        order = stored
        keys = Set(stored)
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

    func toggle(_ key: String) {
        if contains(key) { reopen(key) } else { mark(key) }
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

    static func key(past: PastSession) -> String {
        key(agent: past.agent.name, conversation: past.sessionID, fallback: "past:" + past.id)
    }
}
