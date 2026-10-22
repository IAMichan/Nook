import Foundation

/// Whether you are looking at an agent session right now: its app (Terminal, iTerm, VS Code, the Claude app…) is in front
/// and you are at the Mac. Then Nook does not tell you what you already see there: no notice when it is done, and a
/// permission request or question stays in that window instead of popping up on the notch (Settings › Notifications).
/// The signals are read by `SessionFocus.current()` on a Mac; deciding what they mean lives here, so it can be tested
/// anywhere.
enum SessionFocus {
    /// What is in front of you.
    struct Front: Equatable {
        /// The frontmost app.
        var bundleID: String
        /// The title of its front window; nil when macOS does not tell (no screen recording permission).
        var windowTitle: String?
        /// Seconds since your last key press, click or mouse move.
        var idle: TimeInterval
    }

    /// One agent session as far as this check needs it.
    struct Session: Equatable {
        var id: String
        /// The app the session runs in.
        var hostBundleID: String
        /// The project folder's name.
        var project: String
    }

    /// Without input for longer than this you may have walked away: the notice comes as usual.
    static let presence: TimeInterval = 60

    /// True when `id` is the session you are looking at. When several sessions run in the same app, the front window's
    /// title must name the session's project, and only that one; when Nook cannot tell which one is in front, it tells
    /// you, so nothing is missed.
    static func isWatching(_ id: String, sessions: [Session], front: Front?) -> Bool {
        guard let front, front.idle < presence,
              let session = sessions.first(where: { $0.id == id }),
              sameApp(session.hostBundleID, front.bundleID) else { return false }
        let neighbours = sessions.filter { $0.id != id && sameApp($0.hostBundleID, front.bundleID) }
        if neighbours.isEmpty { return true }
        guard let title = front.windowTitle, let named = project(in: title, among: [session] + neighbours) else { return false }
        return named == key(session.project) && !neighbours.contains { key($0.project) == named }
    }

    /// The project the window title names: the longest name in it, so "nook-ios" wins over "nook".
    static func project(in title: String, among sessions: [Session]) -> String? {
        let title = title.lowercased()
        return sessions.map { key($0.project) }
            .filter { !$0.isEmpty && title.contains($0) }
            .max { $0.count < $1.count }
    }

    private static func sameApp(_ host: String, _ front: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.isEmpty && host.caseInsensitiveCompare(front) == .orderedSame
    }

    private static func key(_ project: String) -> String {
        project.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
