import SwiftUI
import os

@MainActor
final class GitHubConnector: CloudConnectorConfig {
    let id = "github"
    let title = "GitHub"
    let symbol = "chevron.left.forwardslash.chevron.right"
    let accent = Color(hex: 0xA5B4FC)
    let refreshInterval: TimeInterval = 180
    @Published private(set) var status = ConnectorStatus()

    nonisolated static let tokenAccount = "connector.github.token"
    static var fields: [ConnectorField] {
        [ConnectorField(account: GitHubConnector.tokenAccount, label: tr("connect.field.token"), placeholder: "ghp_… / github_pat_…", secret: true)]
    }
    static var helpText: String { tr("connect.github.help") }
    static let signupURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org,read:user&description=Nook")

    enum CI { case unknown, pending, passing, failing }

    private struct PullRequest {
        let repo: String
        let number: Int
        let title: String
        let url: URL?
        let draft: Bool
        let updated: Date?
        var ci: CI = .unknown

        var ref: String { "\(repo)#\(number)" }
    }

    private struct Snapshot {
        let login: String
        let mine: [PullRequest]
        let mineTotal: Int
        let reviews: [PullRequest]
        let reviewTotal: Int
    }

    /// Latest data per account (key: account id).
    private var snapshots: [String: Snapshot] = [:]

    /// Accounts with a token, primary first. One GitHub connection can hold several accounts ("Werk", "Persoonlijk").
    var accounts: [ServiceAccount] {
        AccountRegistry.shared.accounts(for: id).filter { CloudHelp.secret($0.key("token")) != nil }
    }

    var isConfigured: Bool { !accounts.isEmpty }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    /// The account a tool call is for. Without `account` a read uses the primary account; an action with several accounts
    /// has `account` as a required field, so the review screen never runs it on a guessed account.
    func credentials(_ input: [String: Any]) throws -> (account: ServiceAccount, token: String) {
        guard ConnectorToggle.isOn(id) else { throw CloudHelp.notSetUp("GitHub") }
        let available = accounts
        guard !available.isEmpty else { throw CloudHelp.notSetUp("GitHub") }
        let account: ServiceAccount
        if let reference = (input["account"] as? String)?.trimmingCharacters(in: .whitespaces), !reference.isEmpty {
            guard let match = AccountRegistry.match(reference, in: available) else {
                throw NookError("There is no GitHub account \"\(reference)\". Accounts: \(available.map(Self.accountName).joined(separator: ", ")).")
            }
            account = match
        } else {
            account = available[0]
        }
        guard let token = CloudHelp.secret(account.key("token")) else { throw CloudHelp.notSetUp("GitHub") }
        return (account, token)
    }

    /// How an account is named to the model and in plans: its label, else its login.
    static func accountName(_ account: ServiceAccount) -> String {
        if !account.label.isEmpty { return account.label }
        return account.identity ?? account.id
    }

    func refresh() async {
        let available = accounts
        guard ConnectorToggle.isOn(id), !available.isEmpty else {
            snapshots = [:]
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        var fresh: [String: Snapshot] = [:]
        var failures: [String] = []
        var failureKind: ConnectorErrorKind?
        for account in available {
            guard let token = CloudHelp.secret(account.key("token")) else { continue }
            do {
                let snapshot = try await fetch(token: token)
                fresh[account.id] = snapshot
                AccountRegistry.shared.setIdentity("@" + snapshot.login, for: account.id)
            } catch {
                failureKind = failureKind ?? ConnectorErrorKind.classify(error)
                failures.append((available.count > 1 ? Self.accountName(account) + ": " : "") + CloudHelp.errorText(error, service: title))
            }
        }
        snapshots = fresh
        if let first = available.compactMap({ fresh[$0.id] }).first {
            apply(first)
            if !failures.isEmpty { status.detail = failures.joined(separator: " · ") }
        } else {
            status.state = .error(failures.joined(separator: " · "))
            status.errorKind = failureKind
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id) else { return [] }
        let available = accounts
        var lines: [String] = []
        for account in available {
            guard let s = snapshots[account.id] else { continue }
            let who = available.count > 1 ? "GitHub account \"\(Self.accountName(account))\" (@\(s.login))" : "GitHub (@\(s.login))"
            lines.append("\(who): \(CloudHelp.plural(s.mineTotal, "open PR", "open PRs")) authored by you, \(CloudHelp.plural(s.reviewTotal, "review request", "review requests")).")
            lines += s.reviews.prefix(3).map { "Review requested: \($0.ref) '\(CloudHelp.short($0.title))'" }
            lines += s.mine.filter { $0.ci == .failing }.prefix(3).map { "CI failing on \($0.ref) '\(CloudHelp.short($0.title))'" }
            let room = max(0, 8 - lines.count)
            lines += s.mine.filter { $0.ci != .failing }.prefix(min(room, 2)).map { "Open PR authored by you: \($0.ref) '\(CloudHelp.short($0.title))'" }
        }
        return Array(lines.prefix(12))
    }

    /// With several accounts, every GitHub tool gets an `account` field (required for actions).
    fileprivate func withAccount(_ schema: [String: Any], required: Bool) -> [String: Any] {
        let names = accounts.map(Self.accountName)
        guard names.count > 1 else { return schema }
        var copy = schema
        var properties = (schema["properties"] as? [String: Any]) ?? [:]
        properties["account"] = [
            "type": "string", "enum": names,
            "description": "Which GitHub account: \(names.joined(separator: " or ")). Pick the one that has access to the repository; ask the user if unclear."
        ] as [String: Any]
        copy["properties"] = properties
        if required { copy["required"] = ((schema["required"] as? [String]) ?? []) + ["account"] }
        return copy
    }

    var tools: [ToolSpec] {
        let all = [
            ToolSpec(
                name: "github_overview",
                description: "Freshly fetches the user's open pull requests on GitHub, pull requests requesting the user's review, and CI status per PR, with links.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read GitHub" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    return try await self.overview(input)
                }
            )
        ] + pullRequestTools + issueTools
        // Plans show which account an action uses.
        return all.map { spec in
            let summarize = spec.summarize
            return ToolSpec(
                name: spec.name, description: spec.description, schema: withAccount(spec.schema, required: spec.kind == .action),
                kind: spec.kind,
                summarize: { input in
                    let line = summarize(input)
                    guard let account = (input["account"] as? String), !account.isEmpty else { return line }
                    return line + " · " + account
                },
                tag: spec.tag, run: spec.run
            )
        }
    }

    // MARK: - Fetching

    func headers(_ token: String) -> [String: String] {
        [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }

    private func fetch(token: String) async throws -> Snapshot {
        let auth = headers(token)
        let userURL = try CloudHelp.url("https://api.github.com/user")
        let userRaw = try await ConnectorHTTP.json(userURL, headers: auth)
        guard let login = CloudHelp.object(userRaw)["login"] as? String, !login.isEmpty else {
            throw NookError("GitHub returned no username.")
        }
        let mineResult = try await search("is:pr is:open archived:false author:\(login)", auth: auth)
        let reviewResult = try await search("is:pr is:open archived:false review-requested:\(login)", auth: auth)

        // CI check only for most recent PRs to stay within GitHub rate limits.
        var mine = mineResult.items
        for index in mine.indices.prefix(6) {
            mine[index].ci = await ciState(repo: mine[index].repo, number: mine[index].number, auth: auth)
        }
        return Snapshot(login: login, mine: mine, mineTotal: mineResult.total,
                        reviews: reviewResult.items, reviewTotal: reviewResult.total)
    }

    private func search(_ query: String, auth: [String: String]) async throws -> (items: [PullRequest], total: Int) {
        let url = try CloudHelp.url("https://api.github.com", "/search/issues", query: [
            ("q", query), ("sort", "updated"), ("order", "desc"), ("per_page", "20")
        ])
        let raw = try await ConnectorHTTP.json(url, headers: auth)
        let root = CloudHelp.object(raw)
        let items = CloudHelp.list(root["items"]).compactMap { parsePullRequest($0) }
        return (items, CloudHelp.int(root["total_count"]) ?? items.count)
    }

    private func parsePullRequest(_ item: [String: Any]) -> PullRequest? {
        guard let number = CloudHelp.int(item["number"]),
              let repoURL = item["repository_url"] as? String else { return nil }
        let prefix = "https://api.github.com/repos/"
        let repo = repoURL.hasPrefix(prefix) ? String(repoURL.dropFirst(prefix.count)) : repoURL
        return PullRequest(
            repo: repo,
            number: number,
            title: (item["title"] as? String) ?? "Untitled",
            url: CloudHelp.link(item["html_url"] as? String),
            draft: (item["draft"] as? Bool) ?? false,
            updated: CloudHelp.date(item["updated_at"])
        )
    }

    /// Check runs and legacy commit statuses for the latest commit of a PR.
    func ciState(repo: String, number: Int, auth: [String: String]) async -> CI {
        let base = "https://api.github.com/repos/\(repo)"
        guard let pull = await CloudHelp.optionalObject(URL(string: "\(base)/pulls/\(number)"), headers: auth),
              let sha = CloudHelp.object(pull["head"])["sha"] as? String else { return .unknown }

        var seen = false
        var pending = false
        var failing = false
        let bad: Set<String> = ["failure", "timed_out", "action_required", "startup_failure"]

        if let runs = await CloudHelp.optionalObject(URL(string: "\(base)/commits/\(sha)/check-runs?per_page=50"), headers: auth) {
            // The newest run of each check: a cancelled or re-run workflow leaves its old failures behind.
            for run in PullRequestDetailParser.latestRuns(CloudHelp.list(runs["check_runs"])) {
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

    // MARK: - Display

    private func apply(_ s: Snapshot) {
        let failing = s.mine.filter { $0.ci == .failing }

        var headline = s.mineTotal == 1 ? tr("connect.github.openPr") : tr("connect.github.openPrs", s.mineTotal)
        if s.reviewTotal > 0 {
            headline += " · " + (s.reviewTotal == 1 ? tr("connect.github.reviewForYou") : tr("connect.github.reviewsForYou", s.reviewTotal))
        }
        let detail: String
        if !failing.isEmpty {
            detail = tr("connect.github.ciFailing", failing.prefix(3).map { $0.ref }.joined(separator: ", "))
        } else if s.mine.contains(where: { $0.ci == .pending }) {
            detail = tr("connect.github.ciPending")
        } else if s.mine.isEmpty {
            detail = tr("connect.github.noOpenPrs")
        } else {
            detail = tr("connect.github.ciGreen")
        }

        var items: [ConnectorItem] = []
        for pr in s.reviews.prefix(4) {
            items.append(ConnectorItem(id: "review-\(pr.ref)", title: pr.title,
                                       subtitle: "Review requested · \(pr.ref)", tone: .attention, url: pr.url))
        }
        for pr in s.mine.prefix(max(0, 8 - items.count)) {
            var parts = [pr.ref]
            if pr.draft { parts.append("draft") }
            let label = ciLabel(pr.ci)
            if !label.isEmpty { parts.append(label) }
            items.append(ConnectorItem(id: "pr-\(pr.ref)", title: pr.title,
                                       subtitle: parts.joined(separator: " · "), tone: ciTone(pr.ci), url: pr.url))
        }

        status = ConnectorStatus(state: .ok, headline: headline, detail: detail, items: items,
                                 updated: Date(), needsAttention: s.reviewTotal > 0 || !failing.isEmpty)
    }

    func ciLabel(_ ci: CI) -> String {
        switch ci {
        case .failing: return "CI failing"
        case .pending: return "CI running"
        case .passing: return "CI green"
        case .unknown: return ""
        }
    }

    private func ciTone(_ ci: CI) -> ConnectorTone {
        switch ci {
        case .failing: return .bad
        case .passing: return .good
        case .pending, .unknown: return .neutral
        }
    }

    private func overview(_ input: [String: Any]) async throws -> String {
        let (account, token) = try credentials(input)
        let s = try await fetch(token: token)
        snapshots[account.id] = s
        if account == accounts.first { apply(s) }
        let label = accounts.count > 1 ? " (account \(Self.accountName(account)))" : ""
        var out = ["GitHub account: @\(s.login)\(label)", "", "Open PRs authored by user (\(s.mineTotal)):"]
        if s.mine.isEmpty { out.append("- none") }
        for pr in s.mine {
            var line = "- \(pr.ref) '\(pr.title)'"
            if pr.draft { line += " [draft]" }
            let label = ciLabel(pr.ci)
            if !label.isEmpty { line += " [\(label)]" }
            if let updated = pr.updated { line += " · updated \(NookDates.ago(updated))" }
            if let url = pr.url { line += " · \(url.absoluteString)" }
            out.append(line)
        }
        out.append("")
        out.append("Review requested from user (\(s.reviewTotal)):")
        if s.reviews.isEmpty { out.append("- none") }
        for pr in s.reviews {
            var line = "- \(pr.ref) '\(pr.title)'"
            if let updated = pr.updated { line += " · updated \(NookDates.ago(updated))" }
            if let url = pr.url { line += " · \(url.absoluteString)" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
