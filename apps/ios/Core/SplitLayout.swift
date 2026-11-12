import Foundation

// The iPad layout's logic (docs/COMPANION.md, "iPad"): which session ⌘[ and ⌘] open, and how dropped words join what
// is already in a composer. Foundation only, so it is tested on the Mac (NookTests).

enum SessionStepping {
    /// The id `step` places from `current` in `order` (the Agents list from top to bottom), held at either end. With
    /// nothing open (or the open one gone from the list), ⌘] starts at the top and ⌘[ at the bottom. Nil for an empty list.
    static func target(order: [String], current: String?, step: Int) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return step > 0 ? order.first : order.last
        }
        return order[min(max(index + step, 0), order.count - 1)]
    }
}

enum DroppedText {
    /// The longest piece of plain text a drop puts in a composer.
    static let maxLength = 6_000

    /// What the composer holds after `dropped` words land in it: after what was typed, a blank line between them; the
    /// text alone when the composer was empty. Nothing dropped changes nothing.
    static func merge(current: String, dropped: String) -> String {
        let words = dropped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return current }
        let typed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? words : typed + "\n\n" + words
    }

    /// A dropped piece of text, cut to `maxLength` characters.
    static func clip(_ text: String) -> String { String(text.prefix(maxLength)) }
}
