import Foundation

/// What the list of Nooks needs to know about a conversation.
protocol ConversationListItem {
    var id: UUID { get }
    var title: String { get }
    var preview: String { get }
    var updated: Date { get }
    var pinned: Bool { get }
    var archived: Bool { get }
    var busy: Bool { get }
}

/// Searching, ordering and trimming the list of Nooks. Old conversations are archived, not thrown away: nothing the user
/// wrote disappears just because there are many of them.
enum ConversationList {
    /// Conversations kept in the active list; older ones are archived.
    static let activeLimit = 40
    /// Archived conversations kept; only beyond this the oldest are deleted.
    static let archiveLimit = 500

    /// What to show: pinned first, then newest first. A search matches title and preview, ignoring case and accents.
    static func visible<Item: ConversationListItem>(_ items: [Item], query: String, showArchived: Bool) -> [Item] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let matching = items.filter { item in
            guard item.archived == showArchived else { return false }
            guard !words.isEmpty else { return true }
            let haystack = (item.title + " " + item.preview).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
        }
        return matching.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }

    /// The conversations to archive: the oldest unpinned ones beyond `limit`. Pinned and busy ones stay.
    static func toArchive<Item: ConversationListItem>(_ items: [Item], limit: Int = activeLimit) -> [UUID] {
        let active = items.filter { !$0.archived }
        guard active.count > limit else { return [] }
        let overflow = active.count - limit
        let candidates = active.filter { !$0.pinned && !$0.busy }.sorted { $0.updated < $1.updated }
        return Array(candidates.prefix(overflow)).map(\.id)
    }

    /// The archived conversations to delete: the oldest ones beyond `limit`.
    static func toDelete<Item: ConversationListItem>(_ items: [Item], limit: Int = archiveLimit) -> [UUID] {
        let archived = items.filter(\.archived).sorted { $0.updated < $1.updated }
        guard archived.count > limit else { return [] }
        return Array(archived.prefix(archived.count - limit)).map(\.id)
    }
}
