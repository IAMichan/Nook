import Foundation

/// Reads one pull request completely for the detail view, and merges it after you confirmed that there. Uses the token of
/// the account the pull request was listed under, so a work account's pull request is never read or merged with another.
enum GitHubPullRequestDetail {
    /// The token of the account with this id; without one (or when it lost its token) the first account that has a token.
    @MainActor
    static func token(accountID: String?) -> String? {
        guard ConnectorToggle.isOn("github") else { return nil }
        let accounts = AccountRegistry.shared.accounts(for: "github")
        if let accountID, let account = accounts.first(where: { $0.id == accountID }), let token = CloudHelp.secret(account.key("token")) {
            return token
        }
        return accounts.lazy.compactMap { CloudHelp.secret($0.key("token")) }.first
    }

    private static func headers(_ token: String) -> [String: String] {
        ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    /// The pull request with its checks, conversation, commits and files: `summary` and `activity` together.
    static func load(repo: String, number: Int, token: String) async throws -> PullRequestDetail {
        async let activity = loadActivity(repo: repo, number: number, token: token, counts: nil)
        var detail = try await summary(repo: repo, number: number, token: token)
        detail.apply(await activity)
        return detail
    }

    /// What the top of the page and the merge bar need, in two rounds of requests: the pull request with its
    /// repository, then the checks of its head. Its `activityLoaded` is false; `loadActivity` fills in the rest.
    static func summary(repo: String, number: Int, token: String) async throws -> PullRequestDetail {
        let get = getter(repo: repo, token: token)
        async let repository = (try? await get("")) as? [String: Any]
        guard let pull = try await get("/pulls/\(number)") as? [String: Any] else {
            throw NookError("GitHub returned an unexpected response.")
        }
        guard var detail = PullRequestDetailParser.detail(pull: pull, repository: await repository) else {
            throw NookError("GitHub returned an unexpected response.")
        }
        detail.activityLoaded = false
        let sha = detail.headSHA
        if !sha.isEmpty {
            async let runs = (try? await get("/commits/\(sha)/check-runs?per_page=100")) as? [String: Any]
            async let status = (try? await get("/commits/\(sha)/status?per_page=100")) as? [String: Any]
            detail.checks = PullRequestDetailParser.checks(runs: ((await runs)?["check_runs"] as? [[String: Any]]) ?? [],
                                                           statuses: ((await status)?["statuses"] as? [[String: Any]]) ?? [])
        }
        return detail
    }

    /// The timeline, commits and files. A part that fails (no access, say) stays empty instead of hiding the rest.
    /// With the counts of a summary every page of a list is asked at once; without them one after the other.
    static func loadActivity(repo: String, number: Int, token: String, counts: PullRequestDetail?) async -> PullRequestActivity {
        let get = getter(repo: repo, token: token)
        @Sendable func list(_ path: String) async -> [[String: Any]] { ((try? await get(path)) as? [[String: Any]]) ?? [] }
        @Sendable func page(_ path: String, _ page: Int) -> String { path + (path.contains("?") ? "&" : "?") + "per_page=100&page=\(page)" }
        /// Every page of a list (100 per page), up to `limit` pages.
        @Sendable func all(_ path: String, count: Int?, limit: Int) async -> [[String: Any]] {
            if let pages = PullRequestDetailParser.pages(count: count, limit: limit) {
                return await withTaskGroup(of: JSONPage.self) { group in
                    for index in 1...pages { group.addTask { JSONPage(number: index, items: await list(page(path, index))) } }
                    var parts: [JSONPage] = []
                    for await part in group { parts.append(part) }
                    return parts.sorted { $0.number < $1.number }.flatMap(\.items)
                }
            }
            var result: [[String: Any]] = []
            for index in 1...limit {
                let chunk = await list(page(path, index))
                result += chunk
                if chunk.count < 100 { break }
            }
            return result
        }

        async let reviews = all("/pulls/\(number)/reviews", count: nil, limit: 3)
        async let comments = all("/issues/\(number)/comments", count: counts?.commentCount, limit: 3)
        async let lineComments = all("/pulls/\(number)/comments", count: counts?.lineCommentCount, limit: 3)
        async let commitList = all("/pulls/\(number)/commits", count: counts?.commitCount, limit: 3)
        async let fileList = all("/pulls/\(number)/files", count: counts?.changedFiles, limit: 30)
        async let timeline = all("/issues/\(number)/timeline", count: nil, limit: 5)
        let commits = PullRequestDetailParser.commits(await commitList)
        let events = PullRequestDetailParser.events(reviews: await reviews, comments: await comments, lineComments: await lineComments,
                                                    timeline: await timeline, commits: commits)
        return PullRequestActivity(events: events, commits: commits, files: PullRequestDetailParser.files(await fileList))
    }

    /// One page of a list, handed from the task that read it. Parsed JSON is only read after the group is done.
    private struct JSONPage: @unchecked Sendable {
        let number: Int
        let items: [[String: Any]]
    }

    /// A GET on the repository's REST address, asked again when it failed on something passing.
    private static func getter(repo: String, token: String) -> @Sendable (String) async throws -> Any {
        let auth = headers(token)
        let base = "https://api.github.com/repos/\(repo)"
        return { path in
            guard let url = URL(string: base + path) else { throw NookError("Invalid GitHub address.") }
            return try await ConnectorRetry.run { try await ConnectorHTTP.json(url, headers: auth) }
        }
    }

    /// Only what deciding on a merge needs: the pull request, the repository's merge methods and access, and the checks
    /// of its head. Much lighter than `load`, for merging several pull requests at once.
    static func loadForMerge(repo: String, number: Int, token: String) async throws -> PullRequestDetail {
        let auth = headers(token)
        let base = "https://api.github.com/repos/\(repo)"
        @Sendable func get(_ path: String) async throws -> Any {
            guard let url = URL(string: base + path) else { throw NookError("Invalid GitHub address.") }
            return try await ConnectorHTTP.json(url, headers: auth)
        }
        guard let pull = try await get("/pulls/\(number)") as? [String: Any] else {
            throw NookError("GitHub returned an unexpected response.")
        }
        let repository = (try? await get("")) as? [String: Any]
        guard var detail = PullRequestDetailParser.detail(pull: pull, repository: repository) else {
            throw NookError("GitHub returned an unexpected response.")
        }
        let sha = detail.headSHA
        if !sha.isEmpty, detail.state == .open {
            async let runs = (try? await get("/commits/\(sha)/check-runs?per_page=100")) as? [String: Any]
            async let status = (try? await get("/commits/\(sha)/status?per_page=100")) as? [String: Any]
            detail.checks = PullRequestDetailParser.checks(runs: ((await runs)?["check_runs"] as? [[String: Any]]) ?? [],
                                                           statuses: ((await status)?["statuses"] as? [[String: Any]]) ?? [])
        }
        return detail
    }

    /// Merges exactly the head the view showed (`sha`): when someone pushed since, GitHub refuses instead of merging
    /// commits you have not seen. Returns the merge commit's sha. On the patient session: GitHub can take longer than
    /// the usual timeout to merge a large pull request, and a timeout would report a merge that still went through.
    static func merge(repo: String, number: Int, method: PullRequestMergeMethod, sha: String, token: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)/merge") else {
            throw NookError("Invalid GitHub address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try JSONSerialization.data(withJSONObject: PullRequestDetailParser.mergeBody(method: method, sha: sha))
        for (key, value) in headers(token) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.patientSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), (object["merged"] as? Bool) != false else {
            throw NookError(PullRequestDetailParser.mergeError(status: status, object: object),
                            kind: status == 401 ? .auth : .other)
        }
        return (object["sha"] as? String) ?? ""
    }
}
