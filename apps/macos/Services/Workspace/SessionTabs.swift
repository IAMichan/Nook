import Foundation

/// The sessions open as tabs above the conversation on the Agents page, in the order they show. Opening a session
/// adds its tab at the end; past the limit the tab you looked at longest ago goes (never the one that is open), so the
/// row stays a handful of sessions you switch between, not every session you ever clicked.
struct SessionTabList: Codable, Equatable {
    static let limit = 8

    /// The tabs, left to right: list ids ("run:<uuid>", a hub session id, "past:<id>").
    private(set) var ids: [String] = []
    /// The same ids, the one looked at longest ago first.
    private(set) var recency: [String] = []

    init(ids: [String] = []) {
        self.ids = Self.unique(ids)
        recency = self.ids
    }

    /// You opened `id`: its tab is added at the end (or stays where it is) and counts as the latest one looked at.
    mutating func open(_ id: String) {
        guard !id.isEmpty else { return }
        if !ids.contains(id) { ids.append(id) }
        recency.removeAll { $0 == id }
        recency.append(id)
        while ids.count > Self.limit, let oldest = recency.first(where: { $0 != id }) {
            remove(oldest)
        }
    }

    /// Closes `id`. When it was the open one (`active`), the tab to open next: the one to its right, else to its left;
    /// nil when it was the last tab or another one is open.
    @discardableResult
    mutating func close(_ id: String, active: String?) -> String? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        remove(id)
        guard id == active, !ids.isEmpty else { return nil }
        return ids[min(index, ids.count - 1)]
    }

    /// Closes every tab but `id`.
    mutating func closeOthers(than id: String) {
        for other in ids where other != id { remove(other) }
    }

    /// Closes the tabs to the right of `id`.
    mutating func closeRight(of id: String) {
        guard let index = ids.firstIndex(of: id) else { return }
        for other in ids[(index + 1)...] { remove(other) }
    }

    mutating func closeAll() {
        ids = []
        recency = []
    }

    /// The session behind a tab got another id (Nook took an earlier conversation over: "past:<id>" became
    /// "run:<uuid>"): the tab stays in its place under the new id.
    mutating func replace(_ old: String, with new: String) {
        guard old != new, let index = ids.firstIndex(of: old) else { return }
        if ids.contains(new) {
            remove(old)
            return
        }
        ids[index] = new
        recency = recency.map { $0 == old ? new : $0 }
    }

    /// Moves the tab `moved` to the place of `target`.
    mutating func move(_ moved: String, onto target: String) {
        guard moved != target, let from = ids.firstIndex(of: moved), let to = ids.firstIndex(of: target) else { return }
        ids.remove(at: from)
        ids.insert(moved, at: to)
    }

    private mutating func remove(_ id: String) {
        ids.removeAll { $0 == id }
        recency.removeAll { $0 == id }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// The session tabs of this Mac, kept in UserDefaults so they are there again after a restart.
@MainActor
final class SessionTabs: ObservableObject {
    static let shared = SessionTabs()
    private static let key = "agents.sessionTabs"
    private let defaults: UserDefaults
    /// Not `@Published`: opening a tab that is already there only changes which one was looked at last, and redrawing
    /// the whole Agents page for that on every switch made switching slower. Only a change to the tabs announces itself.
    private(set) var list: SessionTabList

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        list = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(SessionTabList.self, from: $0) }
            ?? SessionTabList()
    }

    func open(_ id: String) { update { $0.open(id) } }
    func close(_ id: String, active: String?) -> String? {
        var next: String?
        update { next = $0.close(id, active: active) }
        return next
    }
    func closeOthers(than id: String) { update { $0.closeOthers(than: id) } }
    func closeRight(of id: String) { update { $0.closeRight(of: id) } }
    func closeAll() { update { $0.closeAll() } }
    func replace(_ old: String, with new: String) { update { $0.replace(old, with: new) } }
    func move(_ moved: String, onto target: String) { update { $0.move(moved, onto: target) } }

    private func update(_ change: (inout SessionTabList) -> Void) {
        var next = list
        change(&next)
        guard next != list else { return }
        if next.ids != list.ids { objectWillChange.send() }
        list = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
    }
}
