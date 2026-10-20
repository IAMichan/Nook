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
    /// searches the watched organizations and repositories; a pull request shows once, under the first account that has it.
    @MainActor
    static func load() async -> [AccountPullRequests] {
        guard ConnectorToggle.isOn("github") else { return [] }
        let watching = PullRequestWatchSettings.shared.entries
        let targets = accounts.compactMap { account -> (id: String, name: String, login: String, token: String)? in
            guard let token = CloudHelp.secret(account.key("token")) else { return nil }
            return (account.id, GitHubConnector.accountName(account), account.identity ?? "", token)
        }
        let loaded = await withTaskGroup(of: (Int, AccountPullRequests).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    do {
                        async let watched = fetchWatched(token: target.token, entries: watching)
                        let list = try await fetch(token: target.token)
                        let extra = await watched
                        return (index, AccountPullRequests(id: target.id, name: target.name, login: list.login.isEmpty ? target.login : list.login,
                                                           mine: list.mine, reviews: list.reviews, error: nil,
                                                           watched: extra.items, unreadable: extra.unreadable))
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
    /// do that), each entry is asked on its own, so only the entries that fail are left out.
    private static func fetchWatched(token: String, entries: [String]) async -> (items: [PullRequestItem], unreadable: [String]) {
        guard !entries.isEmpty else { return ([], []) }
        do {
            let data = try await post(PullRequestGraphQL.watchBody(entries), token: token)
            return try PullRequestGraphQL.parseWatched(data, entries: entries)
        } catch {
            // Only GitHub refusing the query points at an entry; a lost connection or a rate limit says nothing about one.
            guard ConnectorErrorKind.classify(error) == .other else { return ([], []) }
            guard entries.count > 1 else { return ([], entries) }
            return await withTaskGroup(of: (Int, [PullRequestItem], [String]).self) { group in
                for (index, entry) in entries.enumerated() {
                    group.addTask {
                        let one = await fetchWatched(token: token, entries: [entry])
                        return (index, one.items, one.unreadable)
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

    private static func fetch(token: String) async throws -> (login: String, mine: [PullRequestItem], reviews: [PullRequestItem]) {
        try PullRequestGraphQL.parse(try await post(PullRequestGraphQL.body(), token: token))
    }

    private static func post(_ body: Data, token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401, 403: throw NookError("The credentials were rejected. Check them in Settings › Integrations.", kind: .auth)
        case 429: throw NookError("Too many requests. Nook will retry shortly.", kind: .rateLimited)
        case let status: throw NookError("GitHub returned an error (\(status)).")
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

    private init() {
        entries = UserDefaults.standard.stringArray(forKey: PullRequestWatchList.defaultsKey) ?? []
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
/// restart, and is refreshed in the background when it is older than half a minute. A failed refresh keeps the rows.
@MainActor
final class PullRequestStore: ObservableObject {
    static let shared = PullRequestStore()

    @Published private(set) var accounts: [AccountPullRequests] = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var available = false
    private(set) var fetchedAt = Date.distantPast
    private static let staleAfter: TimeInterval = 30
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
        guard !loading, force || Date().timeIntervalSince(fetchedAt) > Self.staleAfter else { return }
        loading = true
        let fresh = await GitHubPullRequestList.load()
        loading = false
        loaded = true
        fetchedAt = Date()
        // An account that failed this time keeps its last rows, with the error shown.
        accounts = fresh.map { account in
            guard account.error != nil, let old = accounts.first(where: { $0.id == account.id }) else { return account }
            var kept = old
            kept.error = account.error
            kept.errorKind = account.errorKind
            return kept
        }
        let snapshot = accounts.map { var copy = $0; copy.error = nil; copy.errorKind = nil; return copy }
        let file = self.file
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: file, options: .atomic) }
        }
    }

    /// Something changed (a turn ended, a pull request opened): the next look refreshes.
    func markStale() { fetchedAt = .distantPast }
}
