import Foundation

/// Several rows of a list picked at once, the way a Mac list does it: ⌘-click adds or removes a row, ⇧-click takes the
/// range from the row clicked last, and after "Select" a plain click toggles too. Used by the Nooks and the Agents list
/// to archive, pin or mark many at once.
struct ListSelection<ID: Hashable>: Equatable {
    private(set) var ids: Set<ID> = []
    /// Where a ⇧-click range starts: the row toggled last.
    private(set) var anchor: ID?
    /// In selection mode a plain click toggles a row instead of opening it; the mode can be on with nothing picked yet.
    private(set) var isActive = false

    /// What a click on a row does.
    enum Click: Equatable { case open, toggle, extend }

    var count: Int { ids.count }
    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: ID) -> Bool { ids.contains(id) }

    /// ⇧ extends, ⌘ or selection mode toggles, anything else opens the row.
    func click(command: Bool, shift: Bool) -> Click {
        if shift { return .extend }
        if command || isActive { return .toggle }
        return .open
    }

    mutating func begin() { isActive = true }

    mutating func toggle(_ id: ID) {
        if ids.remove(id) == nil { ids.insert(id) }
        anchor = id
        isActive = true
    }

    /// ⇧-click: every row between the anchor and this one, in the order shown, joins the selection. Without an anchor
    /// that is still in the list it toggles the row instead.
    mutating func extend(to id: ID, in order: [ID]) {
        guard let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) else {
            toggle(id)
            return
        }
        ids.formUnion(order[min(from, to)...max(from, to)])
        isActive = true
    }

    /// Everything shown; when all of it is already picked, nothing.
    mutating func toggleAll(_ order: [ID]) {
        let all = Set(order)
        ids = !all.isEmpty && all.isSubset(of: ids) ? [] : all
        isActive = true
    }

    mutating func clear() {
        ids = []
        anchor = nil
        isActive = false
    }

    /// Rows that left the list (deleted, archived away, filtered out) drop out of the selection.
    mutating func keep(only visible: [ID]) {
        let shown = Set(visible)
        ids.formIntersection(shown)
        if let anchor, !shown.contains(anchor) { self.anchor = nil }
    }

    /// The picked rows in the order shown.
    func ordered(_ order: [ID]) -> [ID] { order.filter(ids.contains) }
}
