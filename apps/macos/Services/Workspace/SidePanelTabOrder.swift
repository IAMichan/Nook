import Foundation

// The order of the side panel's tabs: dragged by hand, with the pinned ones kept first. A pure value the panel's tab
// row applies, so what a drag does is tested apart from the views. Foundation only, tested in `SidePanelCoreTests`.

enum SidePanelTabOrder {
    /// `tabs` with `moved` put in the place of `target` (before it when dragged left, after it when dragged right), the
    /// way a tab row reorders. A pinned tab never leaves the pinned group and an unpinned one never enters it.
    static func moving<Tab: Hashable>(_ tabs: [Tab], moved: Tab, onto target: Tab, pinned: Set<Tab>) -> [Tab] {
        guard moved != target, let from = tabs.firstIndex(of: moved), let to = tabs.firstIndex(of: target),
              pinned.contains(moved) == pinned.contains(target) else { return tabs }
        var result = tabs
        result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }

    /// `tabs` with the pinned ones first, each group in its own order.
    static func pinnedFirst<Tab: Hashable>(_ tabs: [Tab], pinned: Set<Tab>) -> [Tab] {
        tabs.filter { pinned.contains($0) } + tabs.filter { !pinned.contains($0) }
    }

    /// Pinning or unpinning `tab`: the new set, and the tabs in the order that follows (a pinned tab joins the end of the
    /// pinned group, an unpinned one the start of the others).
    static func toggling<Tab: Hashable>(_ tab: Tab, in tabs: [Tab], pinned: Set<Tab>) -> (tabs: [Tab], pinned: Set<Tab>) {
        var next = pinned
        if next.contains(tab) { next.remove(tab) } else { next.insert(tab) }
        let others = tabs.filter { $0 != tab }
        let front = others.filter { next.contains($0) }
        let back = others.filter { !next.contains($0) }
        // Pinned or not, `tab` sits between the two groups: the end of the pinned ones, or the start of the rest.
        return (front + [tab] + back, next)
    }
}
