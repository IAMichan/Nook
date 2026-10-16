import Foundation

/// One pull request in the list under Agents › Pull requests.
struct PullRequestItem: Identifiable, Equatable, Sendable {
    enum CI: Equatable, Sendable { case unknown, pending, passing, failing }

    let repo: String
    let number: Int
    let title: String
    let url: URL?
    let draft: Bool
    let updated: Date?
    let author: String
    var ci: CI = .unknown

    var id: String { "\(repo)#\(number)" }
}

/// The open pull requests of one GitHub account: the ones you wrote and the ones waiting for your review.
struct AccountPullRequests: Identifiable, Equatable, Sendable {
    /// The account's id in `AccountRegistry` ("github", "github.werk").
    let id: String
    /// How the account is named in Nook: its label, else its login.
    let name: String
    let login: String
    var mine: [PullRequestItem]
    var reviews: [PullRequestItem]
    /// Set when this account could not be read (token rejected, no connection).
    var error: String?
}

/// Reads the open pull requests of every GitHub account that is connected, for the Pull requests view. Read-only.
@MainActor
enum GitHubPullRequestList {
    static var isAvailable: Bool {
        ConnectorToggle.isOn("github") && !accounts.isEmpty
    }

    private static var accounts: [ServiceAccount] {
        AccountRegistry.shared.accounts(for: "github").filter { CloudHelp.secret($0.key("token")) != nil }
    }

    /// All accounts, in the order they are set up. One failing account does not hide the others.
    static func load() async -> [AccountPullRequests] {
        guard ConnectorToggle.isOn("github") else { return [] }
        var result: [AccountPullRequests] = []
        for account in accounts {
            guard let token = CloudHelp.secret(account.key("token")) else { continue }
            let name = GitHubConnector.accountName(account)
            do {
                result.append(try await fetch(account: account, name: name, token: token))
            } catch {
                result.append(AccountPullRequests(id: account.id, name: name, login: account.identity ?? "", mine: [], reviews: [],
                                                  error: CloudHelp.errorText(error, service: "GitHub")))
            }
        }
        return result
    }

    private static func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }

    private static func fetch(account: ServiceAccount, name: String, token: String) async throws -> AccountPullRequests {
        let auth = headers(token)
        let userRaw = try await ConnectorHTTP.json(try CloudHelp.url("https://api.github.com/user"), headers: auth)
        guard let login = CloudHelp.object(userRaw)["login"] as? String, !login.isEmpty else {
            throw NookError("GitHub returned no username.")
        }
        async let mineRaw = search("is:pr is:open archived:false author:\(login)", auth: auth)
        async let reviewRaw = search("is:pr is:open archived:false review-requested:\(login)", auth: auth)
        var mine = try await mineRaw
        let reviews = try await reviewRaw
        // CI only for the most recent ones, to stay within GitHub's rate limits.
        for index in mine.indices.prefix(10) {
            mine[index].ci = await ciState(repo: mine[index].repo, number: mine[index].number, auth: auth)
        }
        return AccountPullRequests(id: account.id, name: name, login: login, mine: mine, reviews: reviews, error: nil)
    }

    private static func search(_ query: String, auth: [String: String]) async throws -> [PullRequestItem] {
        let url = try CloudHelp.url("https://api.github.com", "/search/issues", query: [
            ("q", query), ("sort", "updated"), ("order", "desc"), ("per_page", "30")
        ])
        let root = CloudHelp.object(try await ConnectorHTTP.json(url, headers: auth))
        return CloudHelp.list(root["items"]).compactMap(parse)
    }

    private static func parse(_ item: [String: Any]) -> PullRequestItem? {
        guard let number = CloudHelp.int(item["number"]), let repoURL = item["repository_url"] as? String else { return nil }
        let prefix = "https://api.github.com/repos/"
        let repo = repoURL.hasPrefix(prefix) ? String(repoURL.dropFirst(prefix.count)) : repoURL
        return PullRequestItem(
            repo: repo,
            number: number,
            title: (item["title"] as? String) ?? "Untitled",
            url: CloudHelp.link(item["html_url"] as? String),
            draft: (item["draft"] as? Bool) ?? false,
            updated: CloudHelp.date(item["updated_at"]),
            author: (CloudHelp.object(item["user"])["login"] as? String) ?? ""
        )
    }

    /// Check runs and commit statuses of the latest commit of a pull request.
    private static func ciState(repo: String, number: Int, auth: [String: String]) async -> PullRequestItem.CI {
        let base = "https://api.github.com/repos/\(repo)"
        guard let pull = await CloudHelp.optionalObject(URL(string: "\(base)/pulls/\(number)"), headers: auth),
              let sha = CloudHelp.object(pull["head"])["sha"] as? String else { return .unknown }
        var seen = false
        var pending = false
        var failing = false
        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]
        if let runs = await CloudHelp.optionalObject(URL(string: "\(base)/commits/\(sha)/check-runs?per_page=50"), headers: auth) {
            for run in CloudHelp.list(runs["check_runs"]) {
                seen = true
                if (run["status"] as? String) != "completed" {
                    pending = true
                } else if bad.contains((run["conclusion"] as? String) ?? "") {
                    failing = true
                }
            }
        }
        if let combined = await CloudHelp.optionalObject(URL(string: "\(base)/commits/\(sha)/status"), headers: auth),
           (CloudHelp.int(combined["total_count"]) ?? 0) > 0 {
            seen = true
            switch (combined["state"] as? String) ?? "" {
            case "failure", "error": failing = true
            case "pending": pending = true
            default: break
            }
        }
        if failing { return .failing }
        if pending { return .pending }
        return seen ? .passing : .unknown
    }
}
