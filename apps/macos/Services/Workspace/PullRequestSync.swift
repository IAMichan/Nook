import Foundation

/// The pull requests of each session's branch, asked from GitHub on a schedule that follows their state (see
/// `PullRequestSettlement.syncInterval`) and kept across restarts. Feeds the badge on a row and "settle when the pull
/// request is merged". Agents Nook did not start (a terminal session, an earlier or cloud one) are followed by folder
/// and branch instead.
@MainActor
final class PullRequestSync: ObservableObject {
    static let shared = PullRequestSync()

    @Published private(set) var links: [UUID: [PullRequestLink]] = [:]
    /// Keyed by `folderKey(path:branch:)`.
    @Published private(set) var folderLinks: [String: [PullRequestLink]] = [:]
    /// The pull requests of the branches a session worked on before its current one, for the list above its composer.
    /// The ones still open are read again every `earlierInterval`, also while no composer shows them: a stack spread
    /// over a chat's branches would otherwise stay open on its row after it merged.
    @Published private(set) var earlier: [UUID: [PullRequestLink]] = [:]
    /// The pull requests you linked to a session yourself, by `sessionKey`.
    @Published private(set) var added: [String: [PullRequestLink]] = [:]
    /// The ids of the pull requests you took off a session's list, by `sessionKey`. Its branch still finds them, so
    /// the list has to remember they went.
    @Published private(set) var dismissed: [String: Set<String>] = [:]
    private var checked: [UUID: Date] = [:]
    private var folderChecked: [String: Date] = [:]
    /// Keyed by `folderKey(path:branch:)` with the session's id as the path.
    private var earlierChecked: [String: Date] = [:]
    /// The forge hosts with a round under way (`PullRequestRound`).
    private var busyLanes: Set<String> = []
    /// Branches whose pull request is on its way outside Nook's own call (GitHub's page, the agent's own `gh`), by run id
    /// or `folderKey`: asked about every round until it turns up or the time runs out.
    private var expected: [String: Date] = [:]
    private static let expectFor: TimeInterval = 15 * 60
    /// An expected pull request turned up: the session's id (nil for a folder) and its link, to open it in the side panel.
    var found: ((UUID?, URL) -> Void)?
    private let defaults = UserDefaults.standard
    private static let key = "agents.pullRequests.v1"
    private static let foldersKey = "agents.pullRequests.folders.v1"
    private static let earlierKey = "agents.pullRequests.earlier.v1"
    private static let addedKey = "agents.pullRequests.added.v1"
    private static let dismissedKey = "agents.pullRequests.dismissed.v1"

    init() {
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            links = Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                               uniquingKeysWith: { first, _ in first })
        }
        if let data = defaults.data(forKey: Self.foldersKey),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            folderLinks = stored
        }
        if let data = defaults.data(forKey: Self.earlierKey),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            earlier = Dictionary(stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                                 uniquingKeysWith: { first, _ in first })
        }
        if let data = defaults.data(forKey: Self.addedKey),
           let stored = try? JSONDecoder().decode([String: [PullRequestLink]].self, from: data) {
            added = stored
        }
        if let data = defaults.data(forKey: Self.dismissedKey),
           let stored = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            dismissed = stored
        }
    }

    // MARK: A session's own list

    /// Where a session's own list is kept: a session Nook runs by its id, one it only sees by its folder.
    nonisolated static func sessionKey(run: UUID?, directory: String) -> String { run?.uuidString ?? directory }

    /// Everything linked to a session, with the newest status of each: what its branch found, what its earlier branches
    /// found, and what you linked yourself.
    func linked(run: UUID?, directory: String, branch: String?) -> [LinkedPullRequest] {
        let key = Self.sessionKey(run: run, directory: directory)
        let current = run.flatMap { links[$0] } ?? branch.flatMap { folderLinks[Self.folderKey(path: directory, branch: $0)] } ?? []
        let store = PullRequestStatusStore.shared
        return LinkedPullRequests.lines(branch: store.current(current), earlier: store.current(run.flatMap { earlier[$0] } ?? []),
                                        yours: store.current(added[key] ?? []), dismissed: dismissed[key] ?? [])
    }

    /// When the list of a session was last compared with its forge.
    func syncedAt(run: UUID?, directory: String, branch: String?) -> Date? {
        if let run { return checked[run] }
        return branch.flatMap { folderChecked[Self.folderKey(path: directory, branch: $0)] }
    }

    /// Links a pull request to a session by hand; one you took off before comes back.
    func add(_ link: PullRequestLink, session key: String) {
        dismissed[key]?.remove(link.id)
        added[key] = (added[key] ?? []).filter { $0.id != link.id } + [link]
        save()
    }

    /// Links a pull request the session works on (`PullRequestMentions`): unlike `add`, one you took off stays off,
    /// and one already linked keeps its place.
    func mention(_ link: PullRequestLink, session key: String) {
        guard dismissed[key]?.contains(link.id) != true, !(added[key] ?? []).contains(where: { $0.id == link.id }) else { return }
        added[key] = (added[key] ?? []) + [link]
        PullRequestStatusStore.shared.seed([(link.url, PullRequestStatus.glyph(state: link.state, conflicted: link.conflicted))])
        save()
    }

    /// The pull requests linked to a session besides its branches' (by you, or because it works on them), newest status
    /// first, the ones you took off left out: for the tray above its composer.
    func others(run: UUID) -> [PullRequestLink] {
        let key = run.uuidString
        let gone = dismissed[key] ?? []
        return PullRequestStatusStore.shared.current(added[key] ?? []).filter { !gone.contains($0.id) }
    }

    /// Whether a session's list already has a pull request, or you took it off: then it is not looked up again.
    func knows(_ id: String, session key: String) -> Bool {
        dismissed[key]?.contains(id) == true || (added[key] ?? []).contains { $0.id == id }
    }

    /// Takes a pull request off a session's list: one you linked goes, one a branch found stays away.
    func remove(_ link: PullRequestLink, session key: String) {
        let yours = added[key] ?? []
        if yours.contains(where: { $0.id == link.id }) {
            added[key] = yours.filter { $0.id != link.id }
        }
        dismissed[key, default: []].insert(link.id)
        save()
    }

    /// The forge repository of a session's folder, for a link given as "#12".
    func repository(directory: String) async -> RemoteRepository? {
        await remote(directory, read: { await Self.repository(path: directory) })
    }

    /// The badge with the newest status of each request (see `PullRequestStatusStore`): a look by a watch or the pull
    /// request page since this sync's last round shows here too.
    func badge(_ id: UUID) -> PullRequestBadge? { PullRequestBadge.text(links: PullRequestStatusStore.shared.current(links[id] ?? [])) }

    func badge(path: String, branch: String?) -> PullRequestBadge? {
        guard let branch else { return nil }
        return PullRequestBadge.text(links: PullRequestStatusStore.shared.current(folderLinks[Self.folderKey(path: path, branch: branch)] ?? []))
    }

    /// Hands the states kept across restarts, and those of the sessions' `watches`, to the shared status, so a pull request
    /// shows the state it had from the first frame after a launch instead of "open" until its first read.
    func seedStatuses(watches: [PullRequestWatch]) {
        let kept = Array(links.values.joined()) + folderLinks.values.joined() + earlier.values.joined()
        let watched = watches.compactMap { watch in
            PullRequestState(rawValue: watch.state).map { (url: watch.url, glyph: PullRequestStatus.glyph(state: $0, conflicted: watch.conflicted ?? false)) }
        }
        PullRequestStatusStore.shared.seed(kept.map { ($0.url, PullRequestStatus.glyph(state: $0.state, conflicted: $0.conflicted)) } + watched)
    }

    nonisolated static func folderKey(path: String, branch: String) -> String { path + "\n" + branch }

    func merged(_ id: UUID) -> Bool { PullRequestSettlement.shouldSettle(links: links[id] ?? []) }

    /// Merged (or closed) at or after `since`: the session's start or your latest message to it. A request that landed
    /// before you wrote again does not settle the session you are busy in. The request's last update stands in for the
    /// moment it merged; without one it counts.
    func merged(_ id: UUID, since: Date?) -> Bool {
        guard merged(id) else { return false }
        guard let since, let landed = (links[id] ?? []).compactMap(\.updatedAt).max() else { return true }
        return landed >= since
    }

    /// What the session's requests say to the auto-settle rules (`PullRequestSettlement.autoSettleState`).
    func autoSettleState(_ id: UUID, since: Date?) -> AutoSettlePolicy.PullRequestState {
        PullRequestSettlement.autoSettleState(links: links[id] ?? [], since: since)
    }

    /// The session moved on to a new branch: its old pull requests no longer say anything about it (a merged one would
    /// settle it), and the new branch is asked about in the next round. They stay listed above its composer.
    func forget(_ id: UUID) {
        guard links[id] != nil || checked[id] != nil else { return }
        retire(id, links[id] ?? [])
        links[id] = nil
        checked[id] = nil
        save()
    }

    /// A GitHub pull request merged from Nook:the badges of its sessions turn merged at once, not at the next round.
    func markMerged(repository: String, number: Int) {
        mark(repository: repository, number: number, state: .merged)
    }

    /// GitHub said what a pull request is now, in its answer to an action from Nook: the badges follow at once.
    func mark(repository: String, number: Int, state: PullRequestState) {
        func settle(_ list: [PullRequestLink]) -> [PullRequestLink] {
            list.map { link in
                guard link.host == .github, link.number == number, link.state != .merged, link.state != state,
                      link.repository.lowercased() == repository.lowercased() else { return link }
                var link = link
                link.state = state
                return link
            }
        }
        let next = (links.mapValues(settle), folderLinks.mapValues(settle), earlier.mapValues(settle))
        let changed = next.0 != links || next.1 != folderLinks || next.2 != earlier
        if changed { (links, folderLinks, earlier) = next }
        // An open pull request that conflicts still does: an edit's answer says nothing about that.
        let key = PullRequestStatusStore.key(repo: repository, number: number)
        let conflicted = state.isOpen && PullRequestStatusStore.shared.statuses[key]?.glyph == .conflict
        PullRequestStatusStore.shared.record(key: key, glyph: PullRequestStatus.glyph(state: state, conflicted: conflicted), checks: nil)
        if changed { save() }
    }

    /// The session's agent merged or closed a pull request from the shell (`PullRequestToolCall.closesPullRequest`): its
    /// branch, earlier branches and the requests you linked are read again now, not at the next round.
    func recheck(_ id: UUID, now: Date = Date()) {
        checked[id] = nil
        let session = id.uuidString
        for link in (earlier[id] ?? []) + (added[session] ?? []) where link.state.isOpen {
            earlierChecked[Self.folderKey(path: session, branch: link.id)] = nil
        }
        refresh(now: now)
    }

    /// A pull request for the session's branch is being made where Nook cannot see it (GitHub's page in the browser):
    /// the tray above its composer shows it as soon as GitHub has it, not a minute later.
    func expect(_ id: UUID, now: Date = Date()) {
        expected[id.uuidString] = now.addingTimeInterval(Self.expectFor)
        checked[id] = nil
        refresh(now: now)
    }

    /// The session's git button just opened this pull request for its branch: its row lists it at once. The round would
    /// find it too, but only after every other due branch had its turn, and the button's own record of it is gone as
    /// soon as it merges (it only remembers open ones), so a pull request merged right away showed on no row at all.
    /// Expected as well, so a list from GitHub that does not have it yet is asked again in the next round.
    func opened(_ id: UUID, url: URL, branch: String?, now: Date = Date()) {
        guard var link = PullRequestLink(url: url) else { return }
        if link.headBranch == nil { link.headBranch = branch }
        expected[id.uuidString] = now.addingTimeInterval(Self.expectFor)
        checked[id] = nil
        if !(links[id] ?? []).contains(where: { $0.id == link.id }) {
            links[id] = (links[id] ?? []) + [link]
            save()
        }
        refresh(now: now)
    }

    /// The same for a session Nook only sees, by its folder and branch.
    func expect(path: String, branch: String, now: Date = Date()) {
        let key = Self.folderKey(path: path, branch: branch)
        expected[key] = now.addingTimeInterval(Self.expectFor)
        folderChecked[key] = nil
        if !folders.contains(where: { $0.path == path && $0.branch == branch }) {
            folders.append(Folder(path: path, branch: branch, busy: true, quietSince: now))
        }
        refresh(now: now)
    }

    /// How long a branch's answer stays fresh: at once while a pull request is expected and none is known yet.
    private func interval(_ key: String, _ known: [PullRequestLink], now: Date, quietSince: Date? = nil) -> TimeInterval {
        if known.isEmpty, let until = expected[key] {
            if until > now { return 0 }
            expected[key] = nil
        }
        return PullRequestSettlement.syncInterval(links: known, quietSince: quietSince, now: now)
    }

    /// One branch to ask about: a session Nook runs, or another agent's folder.
    private enum Job {
        case run(UUID, branch: String)
        case folder(key: String, path: String, branch: String)
        /// A branch the session left before Nook saw its pull request (the agent opened it and moved on within a round):
        /// asked until one turns up, so the list above the composer shows every pull request the chat made.
        case earlier(UUID, branch: String)
        /// An open pull request of a branch the session left: read again to see whether it landed.
        case earlierLink(UUID, PullRequestLink)
        /// An open pull request you linked: read again like one of an earlier branch.
        case addedLink(String, PullRequestLink)
    }

    /// How often a branch the session left is asked about while no pull request of it is known, and how often an open
    /// pull request of such a branch is read again.
    private static let earlierInterval: TimeInterval = 300

    /// At most this many branches per round, so one round stays short and never holds up the next.
    private static let perRound = 8
    private static let tick: Duration = .seconds(15)
    private weak var workspace: WorkspaceManager?
    private var folders: [Folder] = []

    /// Another agent's folder and branch, with how lively its session is: a busy one is asked first and every minute
    /// while it has no pull request, so the one it opens shows at once; one quiet for a day is asked far less often,
    /// so the hundreds of old sessions never keep a new pull request waiting behind them.
    struct Folder: Equatable {
        var path: String
        var branch: String
        var busy = false
        /// The session's last activity; nil when not known (asked as a lively one).
        var quietSince: Date? = nil
    }
    private var loop: Task<Void, Never>?

    /// Keeps the badges current from now on, also while the list is off screen: a merged pull request shows as merged
    /// without opening anything. `folders` are the other agents' folders and branches, replaced on every call.
    func follow(workspace: WorkspaceManager, folders: [Folder], now: Date = Date()) {
        self.workspace = workspace
        self.folders = folders
        if !nobodyHere { refresh(now: now) }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                // Away from the Mac or saving power, every git process and GitHub request can come less often.
                try? await Task.sleep(for: Self.tick * EnergyMonitor.shared.plan.slowdown)
                guard let self else { return }
                if self.nobodyHere { continue }
                self.refresh(now: Date())
            }
        }
    }

    /// Nobody at the Mac or its displays asleep: the first tick back catches up (as `PullRequestBackgroundRefresh`).
    private var nobodyHere: Bool {
        let signals = EnergyMonitor.shared.signals
        return signals.idle
    }

    /// The lane of a folder: the host of its remote, also when that was read a while ago (it hardly ever changes).
    private func lane(_ directory: String) -> String { remotes[directory]?.repo?.hostName.lowercased() ?? "" }

    /// Asks for the branches that are due, open requests first and then the longest unasked: one after the other per
    /// forge host, so a long list never floods one and a slow one holds up only its own branches.
    private func refresh(now: Date) {
        guard let workspace else { return }
        typealias Due = PullRequestRound.Due<Job>
        var due: [Due] = []
        for run in workspace.runs where !run.archived {
            guard let branch = run.branch, !branch.isEmpty, !BranchPolicy.isDefaultBranch(branch, detectedDefault: run.baseBranch) else { continue }
            let known = links[run.id] ?? []
            guard PullRequestSettlement.needsSync(lastChecked: checked[run.id], now: now,
                                                  interval: interval(run.id.uuidString, known, now: now, quietSince: run.updatedAt)) else { continue }
            due.append(Due(lane: lane(run.workingDirectory), job: .run(run.id, branch: branch),
                           open: PullRequestSettlement.anyOpen(links: known), last: checked[run.id] ?? .distantPast))
        }
        for run in workspace.runs where !run.archived {
            let known = Set((earlier[run.id] ?? []).compactMap(\.headBranch))
            for branch in run.earlierBranches ?? [] where !known.contains(branch) && branch != run.branch {
                let key = Self.folderKey(path: run.id.uuidString, branch: branch)
                guard PullRequestSettlement.needsSync(lastChecked: earlierChecked[key], now: now, interval: Self.earlierInterval) else { continue }
                due.append(Due(lane: lane(run.workingDirectory), job: .earlier(run.id, branch: branch), open: false,
                               last: earlierChecked[key] ?? .distantPast))
            }
            for link in earlier[run.id] ?? [] where link.state.isOpen {
                let key = Self.folderKey(path: run.id.uuidString, branch: link.id)
                guard PullRequestSettlement.needsSync(lastChecked: earlierChecked[key], now: now, interval: Self.earlierInterval) else { continue }
                due.append(Due(lane: URL(string: link.url)?.host?.lowercased() ?? "", job: .earlierLink(run.id, link), open: false,
                               last: earlierChecked[key] ?? .distantPast))
            }
        }
        for (session, list) in added {
            for link in list where link.state.isOpen {
                let key = Self.folderKey(path: session, branch: link.id)
                guard PullRequestSettlement.needsSync(lastChecked: earlierChecked[key], now: now, interval: Self.earlierInterval) else { continue }
                due.append(Due(lane: URL(string: link.url)?.host?.lowercased() ?? "", job: .addedLink(session, link), open: false,
                               last: earlierChecked[key] ?? .distantPast))
            }
        }
        var seen = Set<String>()
        for folder in folders {
            guard !folder.path.isEmpty, !folder.branch.isEmpty, !BranchPolicy.isDefaultBranch(folder.branch) else { continue }
            let key = Self.folderKey(path: folder.path, branch: folder.branch)
            guard seen.insert(key).inserted else { continue }
            let known = folderLinks[key] ?? []
            let quietSince = folder.busy ? now : folder.quietSince
            guard PullRequestSettlement.needsSync(lastChecked: folderChecked[key], now: now,
                                                  interval: interval(key, known, now: now, quietSince: quietSince)) else { continue }
            due.append(Due(lane: lane(folder.path), job: .folder(key: key, path: folder.path, branch: folder.branch),
                           open: folder.busy || PullRequestSettlement.anyOpen(links: known),
                           last: folderChecked[key] ?? .distantPast))
        }
        for (lane, jobs) in PullRequestRound.plan(due, busy: busyLanes, perRound: Self.perRound) {
            busyLanes.insert(lane)
            Task {
                defer { busyLanes.remove(lane) }
                // Most answers repeat what is shown: publish (and store) only the ones that changed, so the session list
                // does not redraw after every round.
                var changed = false
                for job in jobs {
                    if await ask(job, now: now, workspace: workspace) { changed = true }
                }
                if changed { save() }
            }
        }
    }

    /// Asks about one branch; true when the answer changed what is shown.
    private func ask(_ job: Job, now: Date, workspace: WorkspaceManager) async -> Bool {
        var changed = false
        switch job {
        case .run(let id, let branch):
            checked[id] = now
            let directory = workspace.run(id)?.workingDirectory ?? id.uuidString
            guard let repo = await remote(directory, read: { await workspace.remoteRepository(id) }),
                  let found = await SourceForge.requests(repo: repo, branch: branch) else { return changed }
            PullRequestStatusStore.shared.record(found, at: now)
            let next: [PullRequestLink]? = found.isEmpty ? nil : found
            // The requests of a branch the session has since left move to its earlier ones.
            let left = (links[id] ?? []).filter { $0.headBranch.map { $0 != branch } ?? false }
            if !left.isEmpty { retire(id, left); changed = true }
            if next != nil, expected.removeValue(forKey: id.uuidString) != nil,
               let url = PullRequestLink.shown(in: found) { self.found?(id, url) }
            if links[id] != next {
                links[id] = next
                changed = true
            }
            workspace.carryFinishedWatch(id, links: found)
        case .earlier(let id, let branch):
            earlierChecked[Self.folderKey(path: id.uuidString, branch: branch)] = now
            // A branch with no work left (an empty or removed worktree) has no pull request to find: its row goes.
            if await workspace.dropEarlierBranchIfEmpty(id, branch: branch) { return changed }
            let directory = workspace.run(id)?.workingDirectory ?? id.uuidString
            guard let repo = await remote(directory, read: { await workspace.remoteRepository(id) }),
                  let found = await SourceForge.requests(repo: repo, branch: branch), !found.isEmpty else { return changed }
            PullRequestStatusStore.shared.record(found, at: now)
            // The row finds them by branch name, so each carries the one it was asked for.
            let mine = found.map { link -> PullRequestLink in
                var link = link
                if link.headBranch == nil { link.headBranch = branch }
                return link
            }
            if retire(id, mine) { changed = true }
        case .earlierLink(let id, let link):
            earlierChecked[Self.folderKey(path: id.uuidString, branch: link.id)] = now
            guard let url = URL(string: link.url) else { return changed }
            await PullRequestStatusStore.shared.refresh(url)
            // Replaces the kept link by its url, so the state survives a restart; the status store does not.
            if retire(id, PullRequestStatusStore.shared.current([link])) { changed = true }
        case .addedLink(let session, let link):
            earlierChecked[Self.folderKey(path: session, branch: link.id)] = now
            guard let url = URL(string: link.url) else { return changed }
            await PullRequestStatusStore.shared.refresh(url)
            let read = PullRequestStatusStore.shared.current([link])
            guard let list = added[session], read != [link] else { return changed }
            added[session] = list.map { $0.id == link.id ? read[0] : $0 }
            changed = true
        case .folder(let key, let path, let branch):
            folderChecked[key] = now
            guard let repo = await remote(path, read: { await Self.repository(path: path) }),
                  let found = await SourceForge.requests(repo: repo, branch: branch) else { return changed }
            PullRequestStatusStore.shared.record(found, at: now)
            let next: [PullRequestLink]? = found.isEmpty ? nil : found
            if next != nil, expected.removeValue(forKey: key) != nil,
               let url = PullRequestLink.shown(in: found) { self.found?(nil, url) }
            if folderLinks[key] != next {
                folderLinks[key] = next
                changed = true
            }
        }
        return changed
    }

    /// The forge repository of a folder on this Mac; nil when it is gone or has no remote.
    /// Each folder's remote, read with `git remote get-url` at most every `remoteLifetime`: every round asked again for every
    /// branch, a git process each time, for an answer that hardly ever changes.
    private var remotes: [String: (repo: RemoteRepository?, read: Date)] = [:]
    private static let remoteLifetime: TimeInterval = 30 * 60

    private func remote(_ directory: String, read: () async -> RemoteRepository?) async -> RemoteRepository? {
        if let hit = remotes[directory], Date().timeIntervalSince(hit.read) < Self.remoteLifetime { return hit.repo }
        let repo = await read()
        remotes[directory] = (repo, Date())
        return repo
    }

    private nonisolated static func repository(path: String) async -> RemoteRepository? {
        await Task.detached { () -> RemoteRepository? in
            guard let git = GitService.shared, FileManager.default.fileExists(atPath: path) else { return nil }
            return SourceForge.repository(remoteURL: git.remoteURL(path))
        }.value
    }

    @discardableResult
    private func retire(_ id: UUID, _ left: [PullRequestLink]) -> Bool {
        let next = SessionBranches.keeping(left, in: earlier[id] ?? [])
        guard next != earlier[id] ?? [] else { return false }
        earlier[id] = next
        return true
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: links.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
        if let data = try? JSONEncoder().encode(folderLinks) { defaults.set(data, forKey: Self.foldersKey) }
        let kept = Dictionary(uniqueKeysWithValues: earlier.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: Self.earlierKey) }
        if let data = try? JSONEncoder().encode(added) { defaults.set(data, forKey: Self.addedKey) }
        if let data = try? JSONEncoder().encode(dismissed) { defaults.set(data, forKey: Self.dismissedKey) }
    }
}
