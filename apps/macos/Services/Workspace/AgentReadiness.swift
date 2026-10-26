import Foundation

// The "Coding agents" step of the first-run flow: whether each agent is ready to start a session, and which folders you
// worked in recently that could become projects. Pure decisions; the view reads the agent's program, its sign-in and the
// session history, and draws what comes back. Foundation only, so it is tested on its own.

enum AgentReadiness {
    /// Where an agent stands, in the order the step sorts them: what needs you first.
    enum State: String, Equatable, Sendable {
        /// Nook has not looked for the agent yet.
        case checking
        /// Installing or signing in right now (a Terminal window is open for it).
        case connecting
        /// Installed, not signed in.
        case signIn
        /// The program is not on this Mac.
        case missing
        /// Installed and signed in.
        case ready
    }

    /// What the row offers for a state. Both actions use the existing connect flow (install and sign in, in a visible
    /// Terminal window); nothing installs without that click.
    enum Action: String, Equatable, Sendable {
        case none, install, signIn
    }

    static func classify(scanned: Bool, installed: Bool, signedIn: Bool, connecting: Bool) -> State {
        if connecting { return .connecting }
        if installed { return signedIn ? .ready : .signIn }
        // A sign-in without the program (the program was removed) still needs the program first.
        return scanned ? .missing : .checking
    }

    static func action(for state: State) -> Action {
        switch state {
        case .missing: return .install
        case .signIn: return .signIn
        case .checking, .connecting, .ready: return .none
        }
    }

    /// Ready when at least one agent can start a session.
    static func anyReady(_ states: [State]) -> Bool { states.contains(.ready) }

    // MARK: Projects

    /// A folder you worked in recently, as a project you could add.
    struct ProjectCandidate: Equatable, Sendable {
        /// The repository's root folder.
        var path: String
        var name: String
        /// The folder it is in, for the line under the name ("~/Developer/").
        var parent: String
        /// How many sessions worked in it within the window.
        var sessions: Int
        var lastActive: Date
        /// Already one of Nook's projects (Settings › Workspace's recent projects).
        var added: Bool
    }

    static let recentWindow: TimeInterval = 30 * 24 * 3600

    /// The git repositories you worked in during the last 30 days, most recently used first: every session's folder
    /// is taken up to its repository's root (`gitRoot`), so two subfolders of one checkout count once. Folders that are not in a repository, the home folder and sessions outside the window are left out.
    static func projectCandidates(sessions: [(folder: String, date: Date)], known: [String], home: String, now: Date,
                                  limit: Int = 8, gitRoot: (String) -> String?) -> [ProjectCandidate] {
        let cutoff = now.addingTimeInterval(-recentWindow)
        let knownSet = Set(known.map(ProjectOverrides.normalize))
        var byRoot: [String: (count: Int, last: Date)] = [:]
        var rootOf: [String: String?] = [:]
        for session in sessions where session.date >= cutoff && session.date <= now {
            let folder = ProjectOverrides.normalize(session.folder)
            guard !folder.isEmpty, folder != ProjectOverrides.normalize(home), folder != "/" else { continue }
            let root: String?
            if let cached = rootOf[folder] { root = cached } else {
                root = gitRoot(folder).map(ProjectOverrides.normalize)
                rootOf[folder] = root
            }
            guard let root, root != ProjectOverrides.normalize(home) else { continue }
            let entry = byRoot[root] ?? (0, .distantPast)
            byRoot[root] = (entry.count + 1, max(entry.last, session.date))
        }
        let candidates = byRoot.map { root, entry in
            let split = splitPath(root)
            return ProjectCandidate(path: root, name: split.name, parent: split.parent, sessions: entry.count,
                                    lastActive: entry.last, added: knownSet.contains(root))
        }
        return Array(candidates.sorted {
            if $0.lastActive != $1.lastActive { return $0.lastActive > $1.lastActive }
            return $0.path < $1.path
        }.prefix(limit))
    }

    /// The repository a folder belongs to: the nearest folder upward that holds `.git` (a folder, or a file in a worktree).
    static func gitRoot(of folder: String, fileExists: (String) -> Bool) -> String? {
        var current = ProjectOverrides.normalize(folder)
        while current.hasPrefix("/") {
            if fileExists(current + (current == "/" ? "" : "/") + ".git") { return current }
            guard current != "/" else { return nil }
            let parent = (current as NSString).deletingLastPathComponent
            current = parent.isEmpty ? "/" : parent
        }
        return nil
    }

    /// "/Users/me/Developer/app" → ("app", "/Users/me/Developer/").
    static func splitPath(_ path: String) -> (name: String, parent: String) {
        let trimmed = ProjectOverrides.normalize(path)
        guard let slash = trimmed.lastIndex(of: "/"), trimmed != "/" else { return (trimmed, "") }
        return (String(trimmed[trimmed.index(after: slash)...]), String(trimmed[...slash]))
    }
}
