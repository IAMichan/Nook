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

    /// All accounts, in the order they are set up. One failing account does not hide the others. Each account also
    /// searches the watched organizations and repositories, and (unless turned off) the organizations it belongs to;
    /// a pull request shows once, under the first account that has it.
    @MainActor
    static func load() async -> [AccountPullRequests] {
        guard ConnectorToggle.isOn("github") else { return [] }
        let watching = PullRequestWatchSettings.shared.entries
        let ownOrganizations = PullRequestWatchSettings.shared.includeOrganizations
        let targets = accounts.compactMap { account -> (id: String, name: String, login: String, token: String)? in
            guard let token = CloudHelp.secret(account.key("token")) else { return nil }
            return (account.id, GitHubConnector.accountName(account), account.identity ?? "", token)
        }
        let loaded = await withTaskGroup(of: (Int, AccountPullRequests).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    do {
                        async let fetched = fetch(token: target.token)
                        var organizations: [String] = []
                        if ownOrganizations { organizations = await fetchOrganizations(token: target.token) }
                        let extra = await fetchWatched(token: target.token, entries: PullRequestWatchList.including(organizations, in: watching))
                        let list = try await fetched
                        // Only a typed entry is worth a note; an organization found on its own that cannot be searched stays quiet.
                        let unreadable = (extra?.unreadable ?? []).filter { watching.contains($0) }
                        var account = AccountPullRequests(id: target.id, name: target.name, login: list.login.isEmpty ? target.login : list.login,
                                                          mine: list.mine, reviews: list.reviews, error: nil,
                                                          watched: extra?.items ?? [], unreadable: unreadable)
                        account.watchedFailed = extra == nil
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
        // Yours and your reviews stay where they are; a watched one only shows where nothing lists it yet.
        var seen = Set(loaded.flatMap { ($0.mine + $0.reviews).map(\.id) })
        return loaded.map { account in
            var account = account
            account.watched = account.watched.filter { seen.insert($0.id).inserted }
            return account
        }
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
                var seen = Set<String>()
                let items = parts.flatMap(\.1).filter { seen.insert($0.id).inserted }
                let open = items.filter { $0.state == .open }
                return (open + items.filter { $0.state != .open }, parts.flatMap(\.2))
            }
        }
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
        let fresh = await Task { await GitHubPullRequestList.load() }.value
        loading = false
        loaded = true
        fetchedAt = Date()
        if fresh.contains(where: { $0.error == nil }) { lastRead = fetchedAt }
        let cutoff = Date().addingTimeInterval(-Self.mergeGrace)
        mergedHere = mergedHere.filter { $0.value > cutoff }
        accounts = fresh.map(merge).map(settled)
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
