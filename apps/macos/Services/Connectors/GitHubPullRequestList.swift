import Foundation

/// Reads the open pull requests of every GitHub account that is connected, for the Pull requests view. Read-only.
/// One GraphQL request per account (see PullRequestGraphQL), all accounts at once, parsed off the main thread.
enum GitHubPullRequestList {
    @MainActor
    static var isAvailable: Bool {
        ConnectorToggle.isOn("github") && !accounts.isEmpty
    }

    @MainActor
    private static var accounts: [ServiceAccount] {
        AccountRegistry.shared.accounts(for: "github").filter { CloudHelp.secret($0.key("token")) != nil }
    }

    private struct Target: Sendable {
        let id: String
        let name: String
        let login: String
        let token: String
    }

    @MainActor
    private static var targets: [Target] {
        accounts.compactMap { account in
            guard let token = CloudHelp.secret(account.key("token")) else { return nil }
            return Target(id: account.id, name: GitHubConnector.accountName(account), login: account.identity ?? "", token: token)
        }
    }

    /// Each account's own list (the pull requests it wrote and the ones for its review), all accounts at once, in the
    /// order they are set up. One failing account does not hide the others. The watched rows come separately (see
    /// `loadWatched`), so a slow search across many organizations never holds these up; until then each account is
    /// marked `watchedFailed`, which keeps the watched rows it showed before.
    @MainActor
    static func loadOwn() async -> [AccountPullRequests] {
        guard ConnectorToggle.isOn("github") else { return [] }
        let targets = self.targets
        return await withTaskGroup(of: (Int, AccountPullRequests).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    do {
                        let list = try await fetch(token: target.token)
                        var account = AccountPullRequests(id: target.id, name: target.name, login: list.login.isEmpty ? target.login : list.login,
                                                          mine: list.mine, reviews: list.reviews, error: nil)
                        account.watchedFailed = true
                        return (index, account)
                    } catch {
                        return (index, AccountPullRequests(id: target.id, name: target.name, login: target.login, mine: [], reviews: [],
                                                           error: CloudHelp.errorText(error, service: "GitHub"),
                                                           errorKind: ConnectorErrorKind.classify(error)))
                    }
                }
            }
            var result: [(Int, AccountPullRequests)] = []
            for await entry in group { result.append(entry) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The pull requests in the watched organizations and repositories, and (unless turned off) the organizations each
    /// account belongs to, for the accounts given by id. An account whose search could not get through is left out, so
    /// its last watched rows can stay (see `AccountPullRequests.attaching`).
    @MainActor
    static func loadWatched(accounts ids: [String]) async -> [String: WatchedPullRequests] {
        guard ConnectorToggle.isOn("github") else { return [:] }
        let watching = PullRequestWatchSettings.shared.entries
        let ownOrganizations = PullRequestWatchSettings.shared.includeOrganizations
        let targets = self.targets.filter { ids.contains($0.id) }
        return await withTaskGroup(of: (String, WatchedPullRequests?).self) { group in
            for target in targets {
                group.addTask {
                    var organizations: [String] = []
                    if ownOrganizations { organizations = await memberOrganizations(account: target.id, token: target.token) }
                    let entries = PullRequestWatchList.including(organizations, in: watching)
                    guard let found = await fetchWatchedInParts(token: target.token, entries: entries) else { return (target.id, nil) }
                    // Only a typed entry is worth a note; an organization found on its own that cannot be searched stays quiet.
                    return (target.id, WatchedPullRequests(items: found.items, unreadable: found.unreadable.filter { watching.contains($0) }))
                }
            }
            var result: [String: WatchedPullRequests] = [:]
            for await (id, found) in group { result[id] = found }
            return result
        }
    }

    /// Up to twenty entries are forty searches. In one query GitHub can take long enough to run out of time, and then
    /// the whole query is asked again; a few entries per request, all at once, answer much sooner. Nil when a part could
    /// not get through, so the last watched rows can stay.
    private static func fetchWatchedInParts(token: String, entries: [String]) async -> (items: [PullRequestItem], unreadable: [String])? {
        let parts = PullRequestWatchList.parts(entries)
        guard parts.count > 1 else { return await fetchWatched(token: token, entries: entries) }
        let answers = await withTaskGroup(of: (Int, (items: [PullRequestItem], unreadable: [String])?).self) { group in
            for (index, part) in parts.enumerated() {
                group.addTask { (index, await fetchWatched(token: token, entries: part)) }
            }
            var answers: [(Int, (items: [PullRequestItem], unreadable: [String])?)] = []
            for await answer in group { answers.append(answer) }
            return answers.sorted { $0.0 < $1.0 }.map(\.1)
        }
        guard answers.allSatisfy({ $0 != nil }) else { return nil }
        let found = answers.compactMap { $0 }
        return (PullRequestWatchList.combined(found.map(\.items)), found.flatMap(\.unreadable))
    }

    /// The watched entries in one request. When GitHub turns the request down as a whole (one entry it cannot search can
    /// do that), each entry is asked on its own, so only the entries that fail are left out. Nil when the request could
    /// not get through at all, so the last watched rows can stay.
    private static func fetchWatched(token: String, entries: [String]) async -> (items: [PullRequestItem], unreadable: [String])? {
        guard !entries.isEmpty else { return ([], []) }
        do {
            let data = try await post(PullRequestGraphQL.watchBody(entries), token: token)
            return try PullRequestGraphQL.parseWatched(data, entries: entries)
        } catch {
            // Only GitHub refusing the query points at an entry; a lost connection or a rate limit says nothing about one.
            guard ConnectorErrorKind.classify(error) == .other else { return nil }
            guard entries.count > 1 else { return ([], entries) }
            return await withTaskGroup(of: (Int, [PullRequestItem], [String]).self) { group in
                for (index, entry) in entries.enumerated() {
                    group.addTask {
                        let one = await fetchWatched(token: token, entries: [entry])
                        return (index, one?.items ?? [], one?.unreadable ?? [])
                    }
                }
                var parts: [(Int, [PullRequestItem], [String])] = []
                for await part in group { parts.append(part) }
                parts.sort { $0.0 < $1.0 }
                return (PullRequestWatchList.combined(parts.map(\.1)), parts.flatMap(\.2))
            }
        }
    }

    /// The organizations an account belongs to, read again at most every half hour: they hardly ever change, and asking
    /// on every refresh put two more requests in front of the watched search.
    private static func memberOrganizations(account: String, token: String) async -> [String] {
        if let known = await OrganizationCache.shared.organizations(account: account) { return known }
        let found = await fetchOrganizations(token: token)
        // An empty answer may be a request that failed: asked again next time rather than kept.
        if !found.isEmpty { await OrganizationCache.shared.store(found, account: account) }
        return found
    }

    private actor OrganizationCache {
        static let shared = OrganizationCache()
        private static let lifetime: TimeInterval = 30 * 60
        private var known: [String: (organizations: [String], read: Date)] = [:]

        func organizations(account: String) -> [String]? {
            guard let hit = known[account], Date().timeIntervalSince(hit.read) < Self.lifetime else { return nil }
            return hit.organizations
        }

        func store(_ organizations: [String], account: String) { known[account] = (organizations, Date()) }
    }

    /// The organizations this account belongs to (see PullRequestGraphQL.organizationBodies). Best effort: a request
    /// that fails only means fewer organizations, never a failed list.
    private static func fetchOrganizations(token: String) async -> [String] {
        let answers = await withTaskGroup(of: (Int, [String]).self) { group in
            for (index, body) in PullRequestGraphQL.organizationBodies().enumerated() {
                group.addTask {
                    guard let data = try? await send(body, token: token) else { return (index, []) }
                    return (index, PullRequestGraphQL.parseOrganizations(data))
                }
            }
            var parts: [(Int, [String])] = []
            for await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen = Set<String>()
        return answers.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func fetch(token: String) async throws -> (login: String, mine: [PullRequestItem], reviews: [PullRequestItem]) {
        try PullRequestGraphQL.parse(try await post(PullRequestGraphQL.body(), token: token))
    }

    /// One GraphQL request, asked again when it failed on something passing (see ConnectorRetry).
    private static func post(_ body: Data, token: String) async throws -> Data {
        try await ConnectorRetry.run {
            let data = try await send(body, token: token)
            // GitHub answers a query that ran out of time with 200 and no data: that one is worth asking again too.
            if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], root["data"] == nil || root["data"] is NSNull {
                let failure = PullRequestGraphQL.failure(root)
                if failure.kind == .network { throw failure }
            }
            return data
        }
    }

    private static func send(_ body: Data, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.patientSession.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401, 403: throw NookError("The credentials were rejected. Check them in Settings › Integrations.", kind: .auth)
        case 429: throw NookError("Too many requests. Nook will retry shortly.", kind: .rateLimited)
        case let status: throw NookError("GitHub returned an error (\(status)).", kind: ConnectorErrorKind.forHTTP(status: status))
        }
    }
}

/// The watched organizations and repositories, as set in Settings › Apps & accounts (see PullRequestWatchList).
@MainActor
final class PullRequestWatchSettings: ObservableObject {
    static let shared = PullRequestWatchSettings()

    @Published private(set) var entries: [String] {
        didSet {
            UserDefaults.standard.set(entries, forKey: PullRequestWatchList.defaultsKey)
            PullRequestStore.shared.markStale()
        }
    }

    /// Whether the organizations of each connected account show as well, without typing them. On by default.
    @Published var includeOrganizations: Bool {
        didSet {
            UserDefaults.standard.set(includeOrganizations, forKey: Self.organizationsKey)
            PullRequestStore.shared.markStale()
        }
    }

    private static let organizationsKey = "pulls.watchOrganizations"

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: PullRequestWatchList.defaultsKey) ?? []
        includeOrganizations = UserDefaults.standard.object(forKey: Self.organizationsKey) as? Bool ?? true
    }

    /// Adds what was typed (one or more entries, separated by commas or spaces); false when nothing in it was a valid new entry.
    @discardableResult
    func add(_ text: String) -> Bool {
        let updated = PullRequestWatchList.adding(text, to: entries)
        guard updated != entries else { return false }
        entries = updated
        return true
    }

    func remove(_ entry: String) { entries.removeAll { $0 == entry } }
}

/// The pull request list kept between visits: the last list shows at once, also after a
/// restart, and is refreshed in the background when it is older than 15 seconds. A failed refresh keeps the rows; a
/// passing failure (no connection for a moment, GitHub slow to answer) only shows once it happened twice in a row.
@MainActor
final class PullRequestStore: ObservableObject {
    static let shared = PullRequestStore()

    @Published private(set) var accounts: [AccountPullRequests] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var available = false
    private(set) var fetchedAt = Date.distantPast
    /// When the list was last read from GitHub; the panel says how long ago. Unlike `fetchedAt`, never reset by `markStale`.
    @Published private(set) var lastRead: Date?
    /// A forced refresh asked for while one was running: it runs right after, so a change made meanwhile is not missed.
    private var again = false
    /// Passing failures in a row per account; the error shows from the second one, or at once without rows to show.
    private var failures: [String: Int] = [:]
    private static let staleAfter: TimeInterval = 15
    /// Pull requests merged from Nook, with when. GitHub's search takes a while to see a merge; until it does (or for
    /// ten minutes at most) the list shows them merged anyway, instead of open again after the next refresh.
    private var mergedHere: [String: Date] = [:]
    private static let mergeGrace: TimeInterval = 600
    private let file = NookPaths.supportDirectory.appendingPathComponent("pull-requests.json")

    private init() {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([AccountPullRequests].self, from: data) {
            accounts = saved
            loaded = !saved.isEmpty
        }
    }

    /// Refreshes when stale (or always with `force`); returns at once while a refresh is already running.
    func refresh(force: Bool = false) async {
        available = GitHubPullRequestList.isAvailable
        guard available else {
            // GitHub was disconnected: no old rows from an account Nook can no longer read.
            loaded = true
            if !accounts.isEmpty {
                accounts = []
                try? FileManager.default.removeItem(at: file)
            }
            return
        }
        if loading {
            if force { again = true }
            return
        }
        guard force || Date().timeIntervalSince(fetchedAt) > Self.staleAfter else { return }
        loading = true
        // Not tied to the view that asked: closing the panel halfway must not end the refresh as a failed one.
        let fresh = await Task { await GitHubPullRequestList.loadOwn() }.value
        loaded = true
        fetchedAt = Date()
        if fresh.contains(where: { $0.error == nil }) { lastRead = fetchedAt }
        let cutoff = Date().addingTimeInterval(-Self.mergeGrace)
        mergedHere = mergedHere.filter { $0.value > cutoff }
        // Yours and your reviews show as soon as they are in; the watched rows from last time stay until their own
        // search, which can take a lot longer, has answered.
        accounts = AccountPullRequests.attaching([:], to: fresh.map(merge)).map(settled)
        let readable = fresh.filter { $0.error == nil }.map(\.id)
        let watched = await Task { await GitHubPullRequestList.loadWatched(accounts: readable) }.value
        accounts = AccountPullRequests.attaching(watched, to: accounts).map(settled)
        loading = false
        if again {
            again = false
            await refresh(force: true)
            return
        }
        let snapshot = accounts.map { var copy = $0; copy.error = nil; copy.errorKind = nil; return copy }
        let file = self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// An account that failed this time keeps its last rows, with the error shown unless it was a first passing failure.
    /// Watched rows that could not be fetched this time stay as well.
    private func merge(_ account: AccountPullRequests) -> AccountPullRequests {
        let old = accounts.first(where: { $0.id == account.id })
        guard account.error != nil else {
            failures[account.id] = nil
            guard account.watchedFailed, let old else { return account }
            var kept = account
            let listed = Set((account.mine + account.reviews).map(\.id))
            kept.watched = old.watched.filter { !listed.contains($0.id) }
            kept.unreadable = old.unreadable
            return kept
        }
        let passing = account.errorKind.map { $0 == .network || $0 == .rateLimited } ?? false
        let count = passing ? (failures[account.id] ?? 0) + 1 : 0
        failures[account.id] = count
        guard let old, !old.isEmpty else { return account }
        var kept = old
        if passing && count < 2 {
            // Shown rows stay as they are; the next refresh (half a minute away while the list is open) tries again.
            kept.error = old.error
            kept.errorKind = old.errorKind
        } else {
            kept.error = account.error
            kept.errorKind = account.errorKind
        }
        return kept
    }

    /// A pull request was read in full (see PullRequestDetailModel): its row takes the title, state and checks GitHub
    /// gave just now, so the list never lags behind the page.
    func update(with detail: PullRequestDetail) {
        let state: PullRequestItem.State = detail.state == .merged ? .merged : detail.state == .closed ? .closed : .open
        func refreshed(_ items: [PullRequestItem]) -> [PullRequestItem] {
            items.map { item in
                guard item.id == detail.id else { return item }
                return PullRequestItem(repo: item.repo, number: item.number, title: detail.title, url: detail.url ?? item.url,
                                       draft: detail.state == .draft, updated: detail.updated ?? item.updated, author: item.author,
                                       ci: detail.checks.isEmpty ? item.ci : detail.checkSummary,
                                       state: mergedHere[item.id] != nil && state == .open ? .merged : state,
                                       additions: detail.additions, deletions: detail.deletions,
                                       review: item.review, conflict: detail.mergeState == "dirty", labels: detail.labels,
                                       labelColors: detail.labelColors, headBranch: detail.headBranch.isEmpty ? item.headBranch : detail.headBranch,
                                       baseBranch: detail.baseBranch.isEmpty ? item.baseBranch : detail.baseBranch,
                                       nodeID: detail.nodeID.isEmpty ? item.nodeID : detail.nodeID)
            }
        }
        let updated = accounts.map { account -> AccountPullRequests in
            var account = account
            account.mine = refreshed(account.mine)
            account.reviews = refreshed(account.reviews)
            account.watched = refreshed(account.watched)
            return account
        }
        if updated != accounts { accounts = updated }
    }

    /// Something changed (a turn ended, a pull request opened): the next look refreshes.
    func markStale() { fetchedAt = .distantPast }

    /// A pull request was merged from Nook (`repo#number`): its row shows merged at once, and keeps doing so until
    /// GitHub's search has caught up.
    func markMerged(_ id: String) {
        mergedHere[id] = Date()
        accounts = accounts.map(settled)
        fetchedAt = .distantPast
    }

    private func settled(_ account: AccountPullRequests) -> AccountPullRequests {
        guard !mergedHere.isEmpty else { return account }
        func settle(_ items: [PullRequestItem]) -> [PullRequestItem] {
            items.map { item in
                guard item.state == .open, mergedHere[item.id] != nil else { return item }
                var item = item
                item.state = .merged
                return item
            }
        }
        var account = account
        account.mine = settle(account.mine)
        account.reviews = settle(account.reviews)
        account.watched = settle(account.watched)
        return account
    }
}
