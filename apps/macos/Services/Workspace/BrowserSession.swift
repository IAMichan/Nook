import Foundation

/// Which session a browser belongs to. Every session has a browser of its own, so one agent opening a page leaves the
/// page of another alone: a session Nook runs goes by its run, a session Nook only follows by its folder. Without either
/// (Nook's chat, the Agents › Browser page) there is no session and the one browser of Nook itself is meant.
struct BrowserSession: Hashable, Sendable {
    enum Key: Hashable, Sendable {
        case run(UUID)
        case folder(String)
    }

    let run: UUID?
    let directory: String

    init(run: UUID?, directory: String) {
        self.run = run
        self.directory = directory.isEmpty ? "" : WorkspacePathPolicy.normalize(directory)
    }

    /// The key of the session's own browser.
    var own: Key? { keys.first }

    /// The browsers that can show for this session, its own first. A run shows the browser of its folder while it has
    /// none itself: what an agent outside Nook opened there, or a page opened before the session's first message. A
    /// folder never shows the browser of a run in it, or sessions sharing a folder would see each other's pages.
    var keys: [Key] {
        var keys: [Key] = []
        if let run { keys.append(.run(run)) }
        if !directory.isEmpty { keys.append(.folder(directory)) }
        return keys
    }

    /// The browser to show out of those that exist.
    func key(among existing: Set<Key>) -> Key? {
        keys.first { existing.contains($0) }
    }
}
