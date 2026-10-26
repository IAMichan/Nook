import Foundation

/// Tabs you closed, newest last, each with what it showed, so ⇧⌘T (`panel.reopenClosed`) can bring the last one back.
/// Bounded: the oldest go first. A tab that is open again by other means is skipped when reopening.
struct ClosedTabs<Tab> {
    static var limit: Int { 20 }

    private(set) var entries: [Tab] = []

    init() {}

    var isEmpty: Bool { entries.isEmpty }

    /// Several tabs closed at once go in their order, so the last of them comes back first.
    mutating func push(_ tabs: [Tab]) {
        entries.append(contentsOf: tabs)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    mutating func push(_ tab: Tab) { push([tab]) }

    /// The most recently closed tab that is not open now; the open ones it passes are dropped.
    mutating func reopen(skipping isOpen: (Tab) -> Bool = { _ in false }) -> Tab? {
        while let last = entries.popLast() {
            if !isOpen(last) { return last }
        }
        return nil
    }
}
