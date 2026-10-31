import Foundation

/// Searching every chat app's whole history from Search everything (`ChatSearchBridge`), the same for every app: which
/// words to ask for, and how the found messages come back as chats.
enum ChatHistorySearch {
    /// Most messages one app brings per word.
    static let limit = 60
    /// Most words asked for: a long query is narrowed by its first words already.
    static let maxWords = 4
    /// Words shorter than this find nearly everything and say little.
    static let minLength = 2

    /// The words of a query to ask the apps for: every word of its terms (an `OR` and a phrase too), the longest first,
    /// so the rarest ones are asked; none for a query that leaves chats out or only filters.
    static func words(_ query: SearchQuery) -> [String] {
        guard query.kinds.isEmpty || query.kinds.contains(.chat), !query.excludedKinds.contains(.chat) else { return [] }
        var seen = Set<String>()
        let words = query.groups.flatMap { $0.flatMap(\.words) }
            .filter { $0.count >= minLength && seen.insert($0).inserted }
        return Array(words.sorted { $0.count > $1.count }.prefix(maxWords))
    }

    /// Found messages grouped by their chat (its key in the inbox), oldest first inside each, without repeats: what a
    /// bridge that searches word by word returns.
    static func chats(_ found: [(chat: BridgedChat, messages: [InboxMessage])]) -> [BridgedChat] {
        var order: [String] = []
        var chats: [String: BridgedChat] = [:]
        var ids: [String: Set<String>] = [:]
        for hit in found {
            let key = ChatInbox.key(of: hit.chat)
            if chats[key] == nil {
                order.append(key)
                var chat = hit.chat
                chat.messages = []
                chat.unread = nil
                chats[key] = chat
            }
            for message in hit.messages where ids[key, default: []].insert(message.id).inserted {
                chats[key]?.messages.append(message)
            }
        }
        return order.compactMap { key in
            guard var chat = chats[key] else { return nil }
            chat.messages.sort { $0.date < $1.date }
            return chat
        }
    }

    /// Whether a message holds any of the words (in its text or its sender): what an app's own search found loosely is
    /// checked the same way for every app.
    static func matches(_ message: InboxMessage, _ words: [String]) -> Bool {
        let text = SearchText.fold(message.summary + " " + message.sender)
        return words.contains { SearchText.contains(text, $0) }
    }
}
