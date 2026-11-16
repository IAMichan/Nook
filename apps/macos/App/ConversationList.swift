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
    /// Asks something of you: a new answer, a plan or draft waiting for your yes, or still working.
    var asksAttention: Bool { get }
    /// The conversation of a scheduled task's run: it is reached from the Scheduled tab.
    var isScheduledRun: Bool { get }
}

extension ConversationListItem {
    var asksAttention: Bool { false }
    var isScheduledRun: Bool { false }
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
        matching(items, query: query, showArchived: showArchived).sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }

    /// The items `visible` shows, in no particular order: enough to count them.
    static func matching<Item: ConversationListItem>(_ items: [Item], query: String, showArchived: Bool) -> [Item] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            guard item.archived == showArchived else { return false }
            guard !words.isEmpty else { return true }
            let haystack = (item.title + " " + item.preview).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            return words.allSatisfy { haystack.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)) }
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

    /// The open list in its parts, each in the order given: what asks something of you (pinned or not, on the card on
    /// top), the pinned ones, and the rest. Without a search, a scheduled task's run that asks nothing of you is left
    /// out: the task's own row in the Scheduled tab opens its latest run, and a search still finds the older ones. A
    /// run you pinned stays.
    static func sections<Item: ConversationListItem>(_ items: [Item], searching: Bool)
        -> (attention: [Item], pinned: [Item], rest: [Item]) {
        let attention = items.filter(\.asksAttention)
        let settled = items.filter { !$0.asksAttention && ($0.pinned || searching || !$0.isScheduledRun) }
        return (attention, settled.filter(\.pinned), settled.filter { !$0.pinned })
    }
}

/// A short title for a Nook, written by the chosen brain after its first answer, in place of the first words of the
/// question the list shows until then (`Conversation.title(from:)`).
enum ConversationTitle {
    /// The longest title kept, in characters; a longer answer is not a title.
    static let maxLength = 48

    static let system = """
        You name conversations for a list. Reply with only a title of two to five words that says what the \
        conversation is about, so the user recognizes it weeks later. Write it in the language of the user's \
        message. Name the subject (a person, a thing, a task), not the request: "Offer from Infaris", not \
        "Can you check the mail". No quotes, no final period, no emoji, nothing else.
        """

    /// The question and the start of the answer, enough to see what the conversation is about.
    static func prompt(question: String, answer: String) -> String {
        "User message:\n\(question.prefix(1_500))\n\nAnswer:\n\(answer.prefix(1_000))"
    }

    /// The title in the brain's reply: its first line, without quotes, a label ("Title:"), markdown or a final period.
    /// Nil when nothing usable is left or it is too long to be a title.
    static func clean(_ reply: String) -> String? {
        guard var line = reply.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        if let colon = line.firstIndex(of: ":"), line[..<colon].split(separator: " ").count == 1,
           ["title", "titel", "titre", "título"].contains(line[..<colon].lowercased()) {
            line = String(line[line.index(after: colon)...])
        }
        let strip = CharacterSet(charactersIn: "\"'“”‘’«»*_#`.").union(.whitespaces)
        line = line.trimmingCharacters(in: strip)
        guard !line.isEmpty, line.count <= maxLength else { return nil }
        return line.prefix(1).uppercased() + line.dropFirst()
    }
}
