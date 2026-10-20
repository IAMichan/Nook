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

    /// The pull request with its checks, conversation, commits and files. Only the pull request itself must load; a part
    /// that fails (no access to checks, say) stays empty instead of hiding the rest.
    static func load(repo: String, number: Int, token: String) async throws -> PullRequestDetail {
        let auth = headers(token)
        let base = "https://api.github.com/repos/\(repo)"
        @Sendable func get(_ path: String) async throws -> Any {
            guard let url = URL(string: base + path) else { throw NookError("Invalid GitHub address.") }
            return try await ConnectorHTTP.json(url, headers: auth)
        }
        @Sendable func list(_ path: String) async -> [[String: Any]] { ((try? await get(path)) as? [[String: Any]]) ?? [] }
        /// Every page of a list (100 per page), up to `pages` pages.
        @Sendable func all(_ path: String, pages: Int) async -> [[String: Any]] {
            var result: [[String: Any]] = []
            for page in 1...pages {
                let chunk = await list(path + (path.contains("?") ? "&" : "?") + "per_page=100&page=\(page)")
                result += chunk
                if chunk.count < 100 { break }
            }
            return result
        }

        guard let pull = try await get("/pulls/\(number)") as? [String: Any] else {
            throw NookError("GitHub returned an unexpected response.")
        }
        async let repository = (try? await get("")) as? [String: Any]
        async let reviews = all("/pulls/\(number)/reviews", pages: 3)
        async let comments = all("/issues/\(number)/comments", pages: 3)
        async let lineComments = all("/pulls/\(number)/comments", pages: 3)
        async let commits = all("/pulls/\(number)/commits", pages: 3)
        async let files = all("/pulls/\(number)/files", pages: 30)
        async let timeline = all("/issues/\(number)/timeline", pages: 5)
        guard var detail = PullRequestDetailParser.detail(pull: pull, repository: await repository) else {
            throw NookError("GitHub returned an unexpected response.")
        }
        let sha = detail.headSHA
        if !sha.isEmpty {
            async let runs = (try? await get("/commits/\(sha)/check-runs?per_page=100")) as? [String: Any]
            async let status = (try? await get("/commits/\(sha)/status?per_page=100")) as? [String: Any]
            detail.checks = PullRequestDetailParser.checks(runs: ((await runs)?["check_runs"] as? [[String: Any]]) ?? [],
                                                           statuses: ((await status)?["statuses"] as? [[String: Any]]) ?? [])
        }
        detail.commits = PullRequestDetailParser.commits(await commits)
        detail.events = PullRequestDetailParser.events(reviews: await reviews, comments: await comments, lineComments: await lineComments,
                                                       timeline: await timeline, commits: detail.commits)
        detail.files = PullRequestDetailParser.files(await files)
        return detail
    }

    /// Merges exactly the head the view showed (`sha`): when someone pushed since, GitHub refuses instead of merging
    /// commits you have not seen. Returns the merge commit's sha.
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
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), (object["merged"] as? Bool) != false else {
            throw NookError(PullRequestDetailParser.mergeError(status: status, object: object),
                            kind: status == 401 ? .auth : .other)
        }
        return (object["sha"] as? String) ?? ""
    }
}
