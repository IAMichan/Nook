import Foundation

/// What Settings › Archive shows and what its "Delete all archived…" may remove, the same for coding agent sessions and
/// Nook's own conversations. Foundation-only, so the rules are tested without the stores.
enum ArchivePurge {
    /// True when the search is empty or one of the fields contains it (case- and diacritic-insensitive).
    static func matches(_ query: String, _ fields: [String]) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    /// The archived items the page shows for this search, newest first.
    static func shown<Item>(_ items: [Item], query: String, archived: (Item) -> Bool, fields: (Item) -> [String],
                            updated: (Item) -> Date) -> [Item] {
        items.filter { archived($0) && matches(query, fields($0)) }.sorted { updated($0) > updated($1) }
    }

    /// The shown items "Delete all archived…" removes: everything listed apart from what still works (a session with a
    /// running turn or a live process, a conversation Nook is answering). Those stay, and the confirmation counts only
    /// these, so the number it states is the number that goes.
    static func deletable<Item>(_ shown: [Item], busy: (Item) -> Bool) -> [Item] {
        shown.filter { !busy($0) }
    }
}
