import SwiftUI

// Integrations with online services: GitHub, Vercel, Stripe, Notion, Cal.com, n8n, and Resend.
// Connectors are read-only, except GitHub: Nook can review and merge pull requests there, always subject to your approval.
// Keys are stored in the Keychain under "connector.<id>.<field>".

// MARK: - Settings Fields

/// A single input field for a connector in settings (token, address…). Value is saved in the Keychain under `account`.
struct ConnectorField {
    let account: String
    let label: String
    let placeholder: String
    let secret: Bool

    /// Pasting often introduces extraneous spaces, newlines, or quotes.
    static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
    }
}

/// What online connector settings require: fields, instructions, and signup URL.
@MainActor
protocol CloudConnectorConfig: ContextSource, ObservableObject {
    static var fields: [ConnectorField] { get }
    static var helpText: String { get }
    static var signupURL: URL? { get }
    /// All required keys are present in the Keychain (regardless of enabled toggle).
    var isConfigured: Bool { get }
    var configFields: [ConnectorField] { get }
    var helpText: String { get }
    var signupURL: URL? { get }
}

extension CloudConnectorConfig {
    var configFields: [ConnectorField] { Self.fields }
    var helpText: String { Self.helpText }
    var signupURL: URL? { Self.signupURL }
}

enum CloudConnectors {
    /// Single instance of each cloud connector, in settings display order.
    @MainActor
    static func makeAll() -> [ContextSource] {
        [
            GitHubConnector(),
            VercelConnector(),
            StripeConnector(),
            NotionConnector(),
            CalcomConnector(),
            N8nConnector(),
            ResendConnector(),
            CalendarFeedsConnector(),
            CustomSourcesConnector()
        ]
    }
}

// MARK: - Helpers

enum CloudHelp {
    /// A sanitized value from the Keychain, or nil if empty.
    static func secret(_ account: String) -> String? {
        guard let value = Keychain.read(account) else { return nil }
        let cleaned = ConnectorField.clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw NookError("Invalid address: \(string)") }
        return url
    }

    static func url(_ base: String, _ path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: base + path) else { throw NookError("Invalid address: \(base)") }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw NookError("Invalid address: \(base)") }
        return url
    }

    /// Fetches JSON, returning nil on any error; used for optional metadata.
    static func optionalObject(_ url: URL?, headers: [String: String]) async -> [String: Any]? {
        guard let url = url else { return nil }
        guard let raw = try? await ConnectorHTTP.json(url, headers: headers) else { return nil }
        return raw as? [String: Any]
    }

    static func object(_ value: Any?) -> [String: Any] {
        (value as? [String: Any]) ?? [:]
    }

    static func list(_ value: Any?) -> [[String: Any]] {
        (value as? [[String: Any]]) ?? []
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    /// IDs can be either strings or numbers.
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return NookDates.parse(text)
    }

    /// Only HTTPS URLs become clickable.
    static func link(_ string: String?) -> URL? {
        guard let string = string, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    /// Records a failed refresh: the text for the user and the kind of failure for the "Reconnect" / "Try again" action.
    static func fail(_ status: inout ConnectorStatus, _ error: Error, service: String) {
        status.state = .error(errorText(error, service: service))
        status.errorKind = ConnectorErrorKind.classify(error)
    }

    static func errorText(_ error: Error, service: String) -> String {
        if let nook = error as? NookError { return nook.message }
        if error is URLError { return "No connection to \(service). Nook will try again later." }
        return "\(service) returned an unexpected response."
    }

    static func short(_ text: String, _ max: Int = 60) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > max else { return flat }
        return String(flat.prefix(max - 1)) + "…"
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// Zero-decimal currencies in Stripe.
    static let zeroDecimal: Set<String> = [
        "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"
    ]

    /// Amount in smallest unit (cents) as "€ 1,240.50".
    static func money(_ minor: Int, currency: String) -> String {
        let code = currency.lowercased()
        let amount = zeroDecimal.contains(code) ? Double(minor) : Double(minor) / 100
        let formatter = NookDates.cached("money|\(code)") { () -> NumberFormatter in
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.locale = Locale(identifier: "nl_NL")
            formatter.currencyCode = code.uppercased()
            return formatter
        }
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(code.uppercased())"
    }

    /// JSON schema for a read tool.
    static func schema(_ properties: [String: [String: Any]] = [:]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": [String]()]
    }

    static func notSetUp(_ service: String) -> NookError {
        NookError("\(service) is not configured yet or is disabled (Settings › Connectors).")
    }
}

// MARK: - GitHub

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
    static let signupURL = URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:user&description=Nook")

    private enum CI { case unknown, pending, passing, failing }

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
    fileprivate func credentials(_ input: [String: Any]) throws -> (account: ServiceAccount, token: String) {
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

    private func headers(_ token: String) -> [String: String] {
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
    private func ciState(repo: String, number: Int, auth: [String: String]) async -> CI {
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

    private func ciLabel(_ ci: CI) -> String {
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

// MARK: GitHub: Review and merge pull requests

/// Input for PR tools: which repo and which pull request. Outside the main actor so tool summaries can use it.
enum GitHubPR {
    static let repoPattern = "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"

    static func target(_ input: [String: Any]) throws -> (repo: String, number: Int) {
        let repo = ((input["repo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ActionGate.isRepository(repo) else {
            throw NookError("The repository must be owner/name, for example IAMichan/nook.")
        }
        guard let number = CloudHelp.int(input["number"]), number > 0 else {
            throw NookError("The pull request number is missing.")
        }
        return (repo, number)
    }

    /// "IAMichan/nook#23", for use in the plan.
    static func ref(_ input: [String: Any]) -> String {
        guard let parsed = try? GitHubPR.target(input) else { return "pull request" }
        return "\(parsed.repo)#\(parsed.number)"
    }

    static func text(_ input: [String: Any], _ key: String) -> String? {
        let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func schema(_ extra: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        var properties: [String: [String: Any]] = [
            "repo": ["type": "string", "description": "Repository as owner/name, for example IAMichan/nook."],
            "number": ["type": "integer", "description": "Pull request number."]
        ]
        for (key, value) in extra { properties[key] = value }
        return ["type": "object", "properties": properties, "required": ["repo", "number"] + required]
    }
}

extension GitHubConnector {
    /// Reads run immediately; anything modifying GitHub goes through the user as a plan first.
    var pullRequestTools: [ToolSpec] {
        [
            ToolSpec(
                name: "github_pr_details",
                description: "Reads a single pull request completely: title, description, author, status, CI, existing reviews, and changed files with their diff. ALWAYS use this first when the user wants to review, approve, or merge a PR, and actually read the diff before rendering a verdict.",
                schema: GitHubPR.schema(),
                kind: .read,
                summarize: { input in "Read GitHub: \(GitHubPR.ref(input))" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    return try await self.pullRequestDetails(repo: target.repo, number: target.number, input: input)
                }
            ),
            ToolSpec(
                name: "github_review_pr",
                description: "Submits a review on a pull request: approve (APPROVE), request changes (REQUEST_CHANGES), or comment only (COMMENT). Inspect the diff with github_pr_details first. A comment body is required for REQUEST_CHANGES and COMMENT. You cannot approve your own pull request.",
                schema: GitHubPR.schema([
                    "event": ["type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"], "description": "The review action."],
                    "body": ["type": "string", "description": "The review text. Required for REQUEST_CHANGES and COMMENT."]
                ], required: ["event"]),
                kind: .action,
                summarize: { input in
                    let ref = GitHubPR.ref(input)
                    let note = GitHubPR.text(input, "body").map { " · " + CloudHelp.short($0, 50) } ?? ""
                    switch ((input["event"] as? String) ?? "").uppercased() {
                    case "APPROVE": return "GitHub: approve \(ref)" + note
                    case "REQUEST_CHANGES": return "GitHub: request changes on \(ref)" + note
                    default: return "GitHub: review on \(ref)" + note
                    }
                },
                tag: { input in
                    ((input["event"] as? String) ?? "").uppercased() == "REQUEST_CHANGES" ? ("Blocks", .caution) : ("", .good)
                },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    let event = ((input["event"] as? String) ?? "").uppercased()
                    guard ["APPROVE", "REQUEST_CHANGES", "COMMENT"].contains(event) else {
                        throw NookError("The review action must be APPROVE, REQUEST_CHANGES, or COMMENT.")
                    }
                    let body = GitHubPR.text(input, "body")
                    if event != "APPROVE" && body == nil { throw NookError("A comment body is required for this review action.") }
                    var payload: [String: Any] = ["event": event]
                    if let body = body { payload["body"] = body }
                    _ = try await self.send("POST", "/repos/\(target.repo)/pulls/\(target.number)/reviews", body: payload, input: input)
                    switch event {
                    case "APPROVE": return "Approved: \(target.repo)#\(target.number)"
                    case "REQUEST_CHANGES": return "Requested changes on: \(target.repo)#\(target.number)"
                    default: return "Review submitted on \(target.repo)#\(target.number)"
                    }
                }
            ),
            ToolSpec(
                name: "github_comment_pr",
                description: "Posts a regular comment on a pull request, without a review verdict.",
                schema: GitHubPR.schema([
                    "body": ["type": "string", "description": "The comment text."]
                ], required: ["body"]),
                kind: .action,
                summarize: { input in
                    "GitHub: comment on \(GitHubPR.ref(input)) · " + CloudHelp.short(GitHubPR.text(input, "body") ?? "", 50)
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    guard let body = GitHubPR.text(input, "body") else { throw NookError("Comment text is missing.") }
                    _ = try await self.send("POST", "/repos/\(target.repo)/issues/\(target.number)/comments", body: ["body": body], input: input)
                    return "Comment posted on \(target.repo)#\(target.number)"
                }
            ),
            ToolSpec(
                name: "github_merge_pr",
                description: "Merges a pull request. This is difficult to undo: only use when the user clearly asks, and check with github_pr_details first whether CI is green and the PR is not a draft. Choose the method requested by the user; default to 'merge'. To merge several pull requests at once, use github_merge_prs instead.",
                schema: GitHubPR.schema([
                    "method": ["type": "string", "enum": ["merge", "squash", "rebase"], "description": "Merge method. Defaults to merge."]
                ]),
                kind: .action,
                summarize: { input in
                    let method = (GitHubPR.text(input, "method") ?? "merge").lowercased()
                    return "GitHub: merge \(GitHubPR.ref(input)) (\(method))"
                },
                tag: { _ in ("Merge", .caution) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    let method = (GitHubPR.text(input, "method") ?? "merge").lowercased()
                    guard ["merge", "squash", "rebase"].contains(method) else {
                        throw NookError("The method must be merge, squash, or rebase.")
                    }
                    let result = try await self.send("PUT", "/repos/\(target.repo)/pulls/\(target.number)/merge",
                                                     body: ["merge_method": method], input: input)
                    if (result["merged"] as? Bool) == false {
                        throw NookError((result["message"] as? String) ?? "GitHub did not merge the pull request.")
                    }
                    return "Merged (\(method)): \(target.repo)#\(target.number)"
                }
            ),
            ToolSpec(
                name: "github_merge_prs",
                description: "Merges several pull requests in one action, for 'merge all my PRs' or 'merge these PRs'. First list the pull requests the user means with github_overview (their open PRs) or github_search (for example \"is:pr is:open repo:owner/name\"), then pass every one of them here; no need to read each with github_pr_details. Right before merging, Nook checks each pull request itself and skips the ones that are a draft, closed, conflicted, or whose CI is failing, and reports why. CI that is still running does not stop a merge: approving the plan is the user's choice to merge now, so the report notes it instead. Choose the method requested by the user; without one, the repository's default (merge when allowed).",
                schema: [
                    "type": "object",
                    "properties": [
                        "pulls": ["type": "string", "description": "The pull requests, comma-separated, each as owner/name#number, for example \"IAMichan/nook#12, IAMichan/nook#14\"."],
                        "method": ["type": "string", "enum": ["merge", "squash", "rebase"], "description": "Merge method. Optional."] as [String: Any]
                    ] as [String: Any],
                    "required": ["pulls"]
                ],
                kind: .action,
                summarize: { input in
                    PullRequestBatchMerge.summary(input["pulls"], method: GitHubPR.text(input, "method")?.lowercased() ?? "repository default")
                },
                tag: { _ in ("Merge", .caution) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    return try await self.mergePullRequests(input)
                }
            ),
            ToolSpec(
                name: "github_close_pr",
                description: "Closes a pull request without merging. Only use when explicitly requested by the user.",
                schema: GitHubPR.schema(),
                kind: .action,
                summarize: { input in "GitHub: close \(GitHubPR.ref(input))" },
                tag: { _ in ("Close", .caution) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    _ = try await self.send("PATCH", "/repos/\(target.repo)/pulls/\(target.number)", body: ["state": "closed"], input: input)
                    return "Closed: \(target.repo)#\(target.number)"
                }
            )
        ]
    }

    // MARK: Writing

    /// Merges the approved pull requests one by one. Each is read again first and merged at the head that was checked, so
    /// nothing pushed in between gets merged unseen; what is not ready is skipped and the rest still goes ahead.
    fileprivate func mergePullRequests(_ input: [String: Any]) async throws -> String {
        let problems = PullRequestBatchMerge.problems(input["pulls"])
        guard problems.isEmpty else { throw NookError(problems.joined(separator: " ")) }
        let requested = GitHubPR.text(input, "method").map { $0.lowercased() }
        let method = requested.flatMap(PullRequestMergeMethod.init(rawValue:))
        if requested != nil, method == nil { throw NookError("The method must be merge, squash, or rebase.") }
        let token = try credentials(input).token
        var outcomes: [(PullRequestBatchMerge.Target, PullRequestBatchMerge.Outcome)] = []
        for target in PullRequestBatchMerge.targets(input["pulls"]).targets {
            do {
                let detail = try await GitHubPullRequestDetail.loadForMerge(repo: target.repo, number: target.number, token: token)
                if let reason = PullRequestBatchMerge.skipReason(detail) {
                    outcomes.append((target, .skipped(reason)))
                    continue
                }
                guard let chosen = PullRequestBatchMerge.method(requested: method, allowed: detail.methods) else {
                    outcomes.append((target, .skipped("\(requested ?? "merge") not allowed in this repository")))
                    continue
                }
                _ = try await GitHubPullRequestDetail.merge(repo: target.repo, number: target.number, method: chosen,
                                                            sha: detail.headSHA, token: token)
                outcomes.append((target, .merged(PullRequestBatchMerge.mergedLabel(chosen, detail))))
            } catch {
                outcomes.append((target, .failed(error.localizedDescription)))
            }
        }
        let report = PullRequestBatchMerge.report(outcomes)
        // Nothing merged at all: the step failed, with every reason, so the plan does not show it as done.
        guard outcomes.contains(where: { if case .merged = $0.1 { return true }; return false }) else { throw NookError(report) }
        return report
    }

    /// Performs a write action on GitHub and forwards GitHub's error message so Nook can explain why an action failed.
    fileprivate func send(_ method: String, _ path: String, body: [String: Any], input: [String: Any]) async throws -> [String: Any] {
        let token = try credentials(input).token
        let url = try CloudHelp.url("https://api.github.com" + path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in headers(token) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (object["message"] as? String) ?? "GitHub returned an error (\(status))."
            switch status {
            case 401:
                throw NookError("GitHub rejected the connection (401). Reconnect in Settings › Connectors.")
            case 403, 404:
                throw NookError("GitHub did not permit this (\(status)): \(message) Does the connection have write access to pull requests? Otherwise reconnect using 'Connect with GitHub'.")
            default:
                throw NookError("GitHub: \(message)")
            }
        }
        return object
    }

    // MARK: Reading

    /// The PR with all context needed to review it. Truncated so a large diff does not flood the conversation.
    fileprivate func pullRequestDetails(repo: String, number: Int, input: [String: Any]) async throws -> String {
        let auth = headers(try credentials(input).token)
        let base = "https://api.github.com/repos/\(repo)/pulls/\(number)"
        let pull = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url(base), headers: auth))
        let files = CloudHelp.list(try await ConnectorHTTP.json(try CloudHelp.url(base, "/files", query: [("per_page", "30")]), headers: auth))
        var reviews: [[String: Any]] = []
        if let raw = try? await ConnectorHTTP.json(try CloudHelp.url(base, "/reviews", query: [("per_page", "30")]), headers: auth) {
            reviews = CloudHelp.list(raw)
        }
        let ci = await ciState(repo: repo, number: number, auth: auth)

        let author = (CloudHelp.object(pull["user"])["login"] as? String) ?? "?"
        let head = CloudHelp.object(pull["head"])
        let baseRef = CloudHelp.object(pull["base"])
        let merged = (pull["merged"] as? Bool) ?? false
        let state = merged ? "merged" : ((pull["state"] as? String) == "open" ? "open" : "closed")

        var out = ["\(repo)#\(number) '\((pull["title"] as? String) ?? "Untitled")' by @\(author)"]
        var facts = ["status: \(state)"]
        if (pull["draft"] as? Bool) == true { facts.append("draft") }
        if let mergeable = pull["mergeable"] as? Bool {
            facts.append(mergeable ? "no conflicts" : "conflicts")
        }
        if let mergeState = pull["mergeable_state"] as? String, mergeState != "unknown" { facts.append("mergeable_state: \(mergeState)") }
        let label = ciLabel(ci)
        if !label.isEmpty { facts.append(label) }
        out.append(facts.joined(separator: " · "))
        let fromRef = (head["ref"] as? String) ?? "?"
        let toRef = (baseRef["ref"] as? String) ?? "?"
        let added = CloudHelp.int(pull["additions"]) ?? 0
        let removed = CloudHelp.int(pull["deletions"]) ?? 0
        let changed = CloudHelp.int(pull["changed_files"]) ?? files.count
        let fileCount = CloudHelp.plural(changed, "file", "files")
        out.append("From \(fromRef) to \(toRef) · +\(added) −\(removed) in \(fileCount)")
        if let url = pull["html_url"] as? String { out.append(url) }

        if let body = (pull["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            out.append("")
            out.append("Description:")
            out.append(String(body.prefix(1500)))
        }

        if !reviews.isEmpty {
            out.append("")
            out.append("Reviews:")
            for review in reviews.suffix(10) {
                let who = (CloudHelp.object(review["user"])["login"] as? String) ?? "?"
                var line = "- @\(who): \((review["state"] as? String) ?? "?")"
                if let text = (review["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    line += " · " + CloudHelp.short(text, 160)
                }
                out.append(line)
            }
        }

        out.append("")
        out.append("Changed files:")
        var budget = 12000
        for file in files {
            let name = (file["filename"] as? String) ?? "?"
            var block = "### \(name) (\((file["status"] as? String) ?? "modified"), +\(CloudHelp.int(file["additions"]) ?? 0) −\(CloudHelp.int(file["deletions"]) ?? 0))"
            if let patch = file["patch"] as? String, budget > 0 {
                let cut = String(patch.prefix(min(1500, budget)))
                budget -= cut.count
                block += "\n" + cut + (cut.count < patch.count ? "\n… (diff truncated)" : "")
            } else if file["patch"] == nil {
                block += "\n(no diff available: binary or too large)"
            } else {
                block += "\n(diff omitted for brevity)"
            }
            out.append(block)
        }
        if (CloudHelp.int(pull["changed_files"]) ?? 0) > files.count {
            out.append("… and more files (only the first \(files.count) were fetched)")
        }
        return out.joined(separator: "\n")
    }
}

// MARK: GitHub: Search, read, and update issues

extension GitHubConnector {
    private static func issueSchema(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    var issueTools: [ToolSpec] {
        [
            ToolSpec(
                name: "github_search",
                description: "Searches issues and pull requests on GitHub using a GitHub query, most recently updated first, with status, labels, and links. Example queries: \"launch repo:IAMichan/nook\", \"is:issue is:open label:bug\", \"involves:@me deadline\". Use this to find requirements, decisions, or outstanding work in issues.",
                schema: Self.issueSchema([
                    "query": ["type": "string", "description": "GitHub search query (same syntax as on github.com)."],
                    "type": ["type": "string", "enum": ["issue", "pr", "all"], "description": "Issues only, PRs only, or both (default)."] as [String: Any]
                ], required: ["query"]),
                kind: .read,
                summarize: { input in "Search GitHub: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Search query is missing.") }
                    return try await self.searchIssues(query, type: (input["type"] as? String) ?? "all", input: input)
                }
            ),
            ToolSpec(
                name: "github_issue_details",
                description: "Reads a single issue (or the discussion on a pull request): title, status, labels, description, and recent comments.",
                schema: GitHubPR.schema(),
                kind: .read,
                summarize: { input in "Read GitHub: \(GitHubPR.ref(input))" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    return try await self.issueDetails(repo: target.repo, number: target.number, input: input)
                }
            ),
            ToolSpec(
                name: "github_create_issue",
                description: "Creates a new issue in a repository. Write a clear title and description (Markdown). Labels are optional, comma-separated, and must already exist in the repository.",
                schema: Self.issueSchema([
                    "repo": ["type": "string", "description": "Repository as owner/name."],
                    "title": ["type": "string", "description": "Issue title."],
                    "body": ["type": "string", "description": "Description (Markdown)."],
                    "labels": ["type": "string", "description": "Labels, comma-separated. Optional."]
                ], required: ["repo", "title"]),
                kind: .action,
                summarize: { input in
                    "GitHub: issue in \((input["repo"] as? String) ?? "?") · \(CloudHelp.short((input["title"] as? String) ?? "", 60))"
                },
                tag: { _ in ("Create", .caution) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let repo = ((input["repo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard ActionGate.isRepository(repo) else { throw NookError("The repository must be owner/name.") }
                    guard let title = GitHubPR.text(input, "title") else { throw NookError("Title is missing.") }
                    var payload: [String: Any] = ["title": title]
                    if let body = GitHubPR.text(input, "body") { payload["body"] = body }
                    let labels = Self.labels(input)
                    if !labels.isEmpty { payload["labels"] = labels }
                    let result = try await self.send("POST", "/repos/\(repo)/issues", body: payload, input: input)
                    let number = CloudHelp.int(result["number"]).map { "#\($0)" } ?? ""
                    let url = (result["html_url"] as? String).map { " · \($0)" } ?? ""
                    return "Issue created: \(repo)\(number)\(url)"
                }
            ),
            ToolSpec(
                name: "github_comment_issue",
                description: "Posts a comment on an issue (or the discussion of a pull request).",
                schema: GitHubPR.schema(["body": ["type": "string", "description": "The comment text."]], required: ["body"]),
                kind: .action,
                summarize: { input in "GitHub: comment on \(GitHubPR.ref(input)) · " + CloudHelp.short(GitHubPR.text(input, "body") ?? "", 50) },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    guard let body = GitHubPR.text(input, "body") else { throw NookError("Comment text is missing.") }
                    let result = try await self.send("POST", "/repos/\(target.repo)/issues/\(target.number)/comments", body: ["body": body], input: input)
                    return "Comment posted on \(target.repo)#\(target.number)" + ((result["html_url"] as? String).map { " · \($0)" } ?? "")
                }
            ),
            ToolSpec(
                name: "github_update_issue",
                description: "Updates an issue: close or reopen, change title, or add labels. Only provided fields are updated.",
                schema: GitHubPR.schema([
                    "state": ["type": "string", "enum": ["open", "closed"], "description": "open or closed. Optional."] as [String: Any],
                    "title": ["type": "string", "description": "New title. Optional."],
                    "labels": ["type": "string", "description": "Labels to add, comma-separated. Optional."]
                ]),
                kind: .action,
                summarize: { input in
                    var parts: [String] = []
                    if let state = GitHubPR.text(input, "state") { parts.append(state == "closed" ? "close" : "reopen") }
                    if let title = GitHubPR.text(input, "title") { parts.append("title \"\(CloudHelp.short(title, 40))\"") }
                    if let labels = GitHubPR.text(input, "labels") { parts.append("labels \(labels)") }
                    return "GitHub: \(GitHubPR.ref(input)) " + (parts.isEmpty ? "update" : parts.joined(separator: ", "))
                },
                tag: { input in GitHubPR.text(input, "state") == "closed" ? ("Close", .caution) : ("Update", .caution) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    var payload: [String: Any] = [:]
                    if let state = GitHubPR.text(input, "state") {
                        guard ["open", "closed"].contains(state) else { throw NookError("Status must be open or closed.") }
                        payload["state"] = state
                    }
                    if let title = GitHubPR.text(input, "title") { payload["title"] = title }
                    if !payload.isEmpty {
                        _ = try await self.send("PATCH", "/repos/\(target.repo)/issues/\(target.number)", body: payload, input: input)
                    }
                    let labels = Self.labels(input)
                    if !labels.isEmpty {
                        _ = try await self.send("POST", "/repos/\(target.repo)/issues/\(target.number)/labels", body: ["labels": labels], input: input)
                    }
                    guard !payload.isEmpty || !labels.isEmpty else { throw NookError("There is nothing to update.") }
                    return "Updated: \(target.repo)#\(target.number)"
                }
            )
        ]
    }

    fileprivate static func labels(_ input: [String: Any]) -> [String] {
        (GitHubPR.text(input, "labels") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func readHeaders(_ input: [String: Any]) throws -> [String: String] {
        let token = try credentials(input).token
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }

    fileprivate func searchIssues(_ query: String, type: String, input: [String: Any]) async throws -> String {
        var q = query
        if type == "issue", !q.contains("is:issue") { q += " is:issue" }
        if type == "pr", !q.contains("is:pr") { q += " is:pr" }
        let url = try CloudHelp.url("https://api.github.com", "/search/issues", query: [
            ("q", q), ("sort", "updated"), ("order", "desc"), ("per_page", "15")
        ])
        let root = CloudHelp.object(try await ConnectorHTTP.json(url, headers: try readHeaders(input)))
        let items = CloudHelp.list(root["items"])
        if items.isEmpty { return "No issues or pull requests found for \"\(query)\"." }
        var lines = ["\(CloudHelp.int(root["total_count"]) ?? items.count) results, \(items.count) most recently updated:"]
        var refs: [String] = []
        for item in items {
            let repoURL = (item["repository_url"] as? String) ?? ""
            let repo = repoURL.replacingOccurrences(of: "https://api.github.com/repos/", with: "")
            let number = CloudHelp.int(item["number"]) ?? 0
            let kind = item["pull_request"] != nil ? "PR" : "issue"
            let labels = CloudHelp.list(item["labels"]).compactMap { $0["name"] as? String }
            let title = (item["title"] as? String) ?? "Untitled"
            var line = "- \(repo)#\(number) [\(kind), \((item["state"] as? String) ?? "?")] '\(title)'"
            if !labels.isEmpty { line += " · labels: \(labels.joined(separator: ", "))" }
            if let updated = CloudHelp.date(item["updated_at"]) { line += " · updated \(NookDates.short(updated))" }
            if let author = CloudHelp.object(item["user"])["login"] as? String { line += " · by @\(author)" }
            lines.append(line)
            refs.append(ReferenceParser.line(title: "\(repo)#\(number) \(title)", url: CloudHelp.link(item["html_url"] as? String)?.absoluteString,
                                             detail: "\(kind) · \((item["state"] as? String) ?? "")"))
        }
        return (lines + refs).joined(separator: "\n")
    }

    fileprivate func issueDetails(repo: String, number: Int, input: [String: Any]) async throws -> String {
        let auth = try readHeaders(input)
        let base = "https://api.github.com/repos/\(repo)/issues/\(number)"
        let issue = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url(base), headers: auth))
        let comments = CloudHelp.list(try? await ConnectorHTTP.json(try CloudHelp.url(base, "/comments", query: [("per_page", "30")]), headers: auth))
        let title = (issue["title"] as? String) ?? "Untitled"
        let labels = CloudHelp.list(issue["labels"]).compactMap { $0["name"] as? String }
        var out = ["\(repo)#\(number) '\(title)' by @\((CloudHelp.object(issue["user"])["login"] as? String) ?? "?")"]
        var facts = ["status: \((issue["state"] as? String) ?? "?")"]
        if !labels.isEmpty { facts.append("labels: \(labels.joined(separator: ", "))") }
        if let created = CloudHelp.date(issue["created_at"]) { facts.append("opened \(NookDates.short(created))") }
        if let updated = CloudHelp.date(issue["updated_at"]) { facts.append("updated \(NookDates.short(updated))") }
        let assignees = CloudHelp.list(issue["assignees"]).compactMap { $0["login"] as? String }
        if !assignees.isEmpty { facts.append("assigned to: \(assignees.map { "@\($0)" }.joined(separator: ", "))") }
        out.append(facts.joined(separator: " · "))
        if let body = (issue["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            out.append("")
            out.append("Description:")
            out.append(String(body.prefix(4000)))
        }
        if !comments.isEmpty {
            out.append("")
            out.append("Comments (last \(min(comments.count, 15))):")
            for comment in comments.suffix(15) {
                let who = (CloudHelp.object(comment["user"])["login"] as? String) ?? "?"
                let when = CloudHelp.date(comment["created_at"]).map { NookDates.short($0) } ?? ""
                out.append("- @\(who) \(when): " + CloudHelp.short((comment["body"] as? String) ?? "", 600))
            }
        }
        out.append(ReferenceParser.line(title: "\(repo)#\(number) \(title)", url: CloudHelp.link(issue["html_url"] as? String)?.absoluteString,
                                        detail: (issue["state"] as? String) ?? ""))
        return out.joined(separator: "\n")
    }
}

// MARK: Vercel

@MainActor
final class VercelConnector: CloudConnectorConfig {
    let id = "vercel"
    let title = "Vercel"
    let symbol = "triangle.fill"
    let accent = Color(hex: 0xE8E8EE)
    let refreshInterval: TimeInterval = 150
    @Published private(set) var status = ConnectorStatus()

    static let tokenAccount = "connector.vercel.token"
    static let teamAccount = "connector.vercel.team"
    static var fields: [ConnectorField] {
        [
            ConnectorField(account: VercelConnector.tokenAccount, label: tr("connect.field.token"), placeholder: tr("connect.vercel.tokenPlaceholder"), secret: true),
            ConnectorField(account: VercelConnector.teamAccount, label: tr("connect.vercel.teamId"), placeholder: tr("connect.vercel.teamPlaceholder"), secret: false)
        ]
    }
    static var helpText: String { tr("connect.vercel.help") }
    static let signupURL = URL(string: "https://vercel.com/account/tokens")

    private struct Deployment {
        let id: String
        let project: String
        let state: String
        let created: Date?
        let branch: String?
        let message: String?
        let production: Bool
        let url: URL?
    }

    private var deployments: [Deployment] = []
    private var loaded = false

    var isConfigured: Bool { CloudHelp.secret(VercelConnector.tokenAccount) != nil }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(VercelConnector.tokenAccount) else {
            deployments = []
            loaded = false
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await fetch(token: token, limit: 12)
            apply(fresh)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded else { return [] }
        let latest = latestPerProject(deployments)
        if latest.isEmpty { return ["Vercel: no deployments yet."] }
        let summary = latest.prefix(4).map { d -> String in
            var part = "\(d.project): \(stateLabel(d.state))"
            if let created = d.created { part += " (\(NookDates.ago(created)))" }
            return part
        }
        var lines = ["Vercel, latest deployments: " + summary.joined(separator: ", ")]
        for d in latest where d.state == "ERROR" {
            var line = "Vercel deployment failed: \(d.project)"
            if let branch = d.branch { line += " (\(branch))" }
            if let message = d.message { line += " '\(CloudHelp.short(message))'" }
            lines.append(line)
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "vercel_deployments",
                description: "Fetches the user's latest Vercel deployments: project, status (live, failed, building), branch, commit, and link.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read Vercel" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("Vercel") }
                    return try await self.overview()
                }
            )
        ]
    }

    private func fetch(token: String, limit: Int) async throws -> [Deployment] {
        var query: [(String, String)] = [("limit", String(limit))]
        if let team = CloudHelp.secret(VercelConnector.teamAccount) { query.append(("teamId", team)) }
        let url = try CloudHelp.url("https://api.vercel.com", "/v6/deployments", query: query)
        let raw = try await ConnectorHTTP.json(url, headers: ["Authorization": "Bearer \(token)"])
        let root = CloudHelp.object(raw)
        return CloudHelp.list(root["deployments"]).compactMap { parse($0) }
    }

    private func parse(_ d: [String: Any]) -> Deployment? {
        guard let uid = d["uid"] as? String else { return nil }
        let meta = CloudHelp.object(d["meta"])
        let state = ((d["state"] as? String) ?? (d["readyState"] as? String) ?? "UNKNOWN").uppercased()
        let millis = CloudHelp.double(d["created"]) ?? CloudHelp.double(d["createdAt"])
        let message = (meta["githubCommitMessage"] as? String)
            ?? (meta["gitlabCommitMessage"] as? String)
            ?? (meta["bitbucketCommitMessage"] as? String)
        let branch = (meta["githubCommitRef"] as? String)
            ?? (meta["gitlabCommitRef"] as? String)
            ?? (meta["bitbucketCommitRef"] as? String)
        var link = CloudHelp.link(d["inspectorUrl"] as? String)
        if link == nil, let host = d["url"] as? String, !host.isEmpty {
            link = CloudHelp.link(host.hasPrefix("https://") ? host : "https://\(host)")
        }
        return Deployment(
            id: uid,
            project: (d["name"] as? String) ?? "Project",
            state: state,
            created: millis.map { Date(timeIntervalSince1970: $0 / 1000) },
            branch: branch,
            message: message,
            production: (d["target"] as? String) == "production",
            url: link
        )
    }

    /// The API returns newest first; only the latest deploy per project is considered.
    private func latestPerProject(_ list: [Deployment]) -> [Deployment] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.project).inserted }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "READY": return "live"
        case "ERROR": return "failed"
        case "BUILDING": return "building"
        case "QUEUED": return "queued"
        case "INITIALIZING": return "initializing"
        case "CANCELED": return "canceled"
        default: return state.lowercased()
        }
    }

    private func tone(_ state: String) -> ConnectorTone {
        switch state {
        case "READY": return .good
        case "ERROR": return .bad
        default: return .neutral
        }
    }

    private func apply(_ list: [Deployment]) {
        deployments = list
        loaded = true
        let latest = latestPerProject(list)
        let broken = latest.filter { $0.state == "ERROR" }
        let busy = latest.filter { ["BUILDING", "QUEUED", "INITIALIZING"].contains($0.state) }

        let headline: String
        if !broken.isEmpty {
            headline = tr("connect.vercel.deployFailed", broken.prefix(2).map { $0.project }.joined(separator: ", "))
        } else if let first = busy.first {
            headline = tr("connect.vercel.deployBusy", first.project)
        } else if latest.isEmpty {
            headline = tr("connect.vercel.noDeploys")
        } else {
            headline = tr("connect.vercel.allLive")
        }
        var detail = ""
        if let last = list.first {
            detail = "Latest: \(last.project)"
            if let created = last.created { detail += " · \(NookDates.ago(created))" }
        }

        let items = list.prefix(8).map { d -> ConnectorItem in
            var parts = [stateLabel(d.state)]
            if d.production { parts.append("production") }
            if let branch = d.branch { parts.append(branch) }
            if let created = d.created { parts.append(NookDates.ago(created)) }
            let title = d.message.map { "\(d.project): \(CloudHelp.short($0, 50))" } ?? d.project
            return ConnectorItem(id: d.id, title: title, subtitle: parts.joined(separator: " · "), tone: tone(d.state), url: d.url)
        }

        status = ConnectorStatus(state: .ok, headline: headline, detail: detail, items: Array(items),
                                 updated: Date(), needsAttention: !broken.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(VercelConnector.tokenAccount) else {
            throw CloudHelp.notSetUp("Vercel")
        }
        let list = try await fetch(token: token, limit: 20)
        apply(list)
        if list.isEmpty { return "No Vercel deployments found." }
        return list.map { d -> String in
            var line = "- \(d.project): \(stateLabel(d.state))"
            if d.production { line += " [production]" }
            if let branch = d.branch { line += " · branch \(branch)" }
            if let message = d.message { line += " · '\(CloudHelp.short(message, 100))'" }
            if let created = d.created { line += " · \(NookDates.short(created))" }
            if let url = d.url { line += " · \(url.absoluteString)" }
            return line
        }.joined(separator: "\n")
    }
}

// MARK: Stripe

@MainActor
final class StripeConnector: CloudConnectorConfig {
    let id = "stripe"
    let title = "Stripe"
    let symbol = "creditcard"
    let accent = Color(hex: 0x8F86FF)
    let refreshInterval: TimeInterval = 240
    @Published private(set) var status = ConnectorStatus()

    static let keyAccount = "connector.stripe.key"
    static var fields: [ConnectorField] {
        [ConnectorField(account: StripeConnector.keyAccount, label: tr("connect.field.key"), placeholder: "rk_live_…", secret: true)]
    }
    static var helpText: String { tr("connect.stripe.help") }
    static let signupURL = URL(string: "https://dashboard.stripe.com/apikeys")

    private struct Payment {
        let id: String
        let amount: Int
        let refunded: Int
        let currency: String
        let status: String
        let created: Date
        let who: String
        let failure: String?
    }

    private struct Snapshot {
        let today: [Payment]
        let moreToday: Bool
        let recent: [Payment]
        let testMode: Bool
    }

    private var snapshot: Snapshot?

    var isConfigured: Bool { CloudHelp.secret(StripeConnector.keyAccount) != nil }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(StripeConnector.keyAccount) else {
            snapshot = nil
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await fetch(key: key, recentCount: 5)
            apply(fresh)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        let succeeded = s.today.filter { $0.status == "succeeded" }
        var lines = ["Stripe\(s.testMode ? " (test mode)" : ""): \(revenueText(s)) revenue today from \(CloudHelp.plural(succeeded.count, "payment", "payments"))\(s.moreToday ? " (100+)" : "")."]
        let failed = s.today.filter { $0.status == "failed" }
        if !failed.isEmpty {
            lines.append("Stripe: \(CloudHelp.plural(failed.count, "failed payment", "failed payments")) today.")
        }
        for p in s.recent.prefix(4) {
            lines.append("Payment: \(CloudHelp.money(p.amount, currency: p.currency)) from \(CloudHelp.short(p.who, 40)), \(statusLabel(p.status)), \(NookDates.ago(p.created))")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "stripe_payments",
                description: "Fetches today's revenue and the most recent payments in Stripe: amount, customer, status, and time. Read only.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read Stripe" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("Stripe") }
                    return try await self.overview()
                }
            )
        ]
    }

    private func fetch(key: String, recentCount: Int) async throws -> Snapshot {
        let auth = ["Authorization": "Bearer \(key)"]
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let todayURL = try CloudHelp.url("https://api.stripe.com", "/v1/charges", query: [
            ("limit", "100"), ("created[gte]", String(Int(startOfDay.timeIntervalSince1970)))
        ])
        let todayRaw = try await ConnectorHTTP.json(todayURL, headers: auth)
        let todayRoot = CloudHelp.object(todayRaw)
        let recentURL = try CloudHelp.url("https://api.stripe.com", "/v1/charges", query: [("limit", String(recentCount))])
        let recentRaw = try await ConnectorHTTP.json(recentURL, headers: auth)
        let recentRoot = CloudHelp.object(recentRaw)
        return Snapshot(
            today: CloudHelp.list(todayRoot["data"]).compactMap { parse($0) },
            moreToday: (todayRoot["has_more"] as? Bool) ?? false,
            recent: CloudHelp.list(recentRoot["data"]).compactMap { parse($0) },
            testMode: key.hasPrefix("sk_test") || key.hasPrefix("rk_test")
        )
    }

    private func parse(_ c: [String: Any]) -> Payment? {
        guard let id = c["id"] as? String,
              let amount = CloudHelp.int(c["amount"]),
              let currency = c["currency"] as? String else { return nil }
        let billing = CloudHelp.object(c["billing_details"])
        let description = (c["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = (billing["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let email = (c["receipt_email"] as? String) ?? (billing["email"] as? String)
        return Payment(
            id: id,
            amount: amount,
            refunded: CloudHelp.int(c["amount_refunded"]) ?? 0,
            currency: currency,
            status: (c["status"] as? String) ?? "",
            created: Date(timeIntervalSince1970: CloudHelp.double(c["created"]) ?? 0),
            who: name ?? description ?? email ?? "Payment",
            failure: c["failure_message"] as? String
        )
    }

    /// Net revenue today per currency, largest first.
    private func revenueText(_ s: Snapshot) -> String {
        var totals: [String: Int] = [:]
        for p in s.today where p.status == "succeeded" {
            totals[p.currency, default: 0] += p.amount - p.refunded
        }
        if totals.isEmpty {
            return CloudHelp.money(0, currency: s.recent.first?.currency ?? "eur")
        }
        return totals.sorted { $0.value > $1.value }
            .map { CloudHelp.money($0.value, currency: $0.key) }
            .joined(separator: " + ")
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "succeeded": return "succeeded"
        case "pending": return "pending"
        case "failed": return "failed"
        default: return status
        }
    }

    private func tone(_ p: Payment) -> ConnectorTone {
        switch p.status {
        case "succeeded": return p.refunded > 0 ? .neutral : .good
        case "failed": return .bad
        default: return .neutral
        }
    }

    private func dashboardURL(_ p: Payment, testMode: Bool) -> URL? {
        URL(string: "https://dashboard.stripe.com/\(testMode ? "test/" : "")payments/\(p.id)")
    }

    private func apply(_ s: Snapshot) {
        snapshot = s
        let succeeded = s.today.filter { $0.status == "succeeded" }
        let failed = s.today.filter { $0.status == "failed" }
        var detail = CloudHelp.plural(succeeded.count, "payment", "payments") + (s.moreToday ? "+" : "") + " today"
        if !failed.isEmpty { detail += " · \(failed.count) failed" }
        if s.testMode { detail += " · test mode" }

        let items = s.recent.map { p -> ConnectorItem in
            var subtitle = "\(statusLabel(p.status)) · \(NookDates.ago(p.created))"
            if p.refunded > 0 { subtitle += " · \(CloudHelp.money(p.refunded, currency: p.currency)) refunded" }
            return ConnectorItem(id: p.id, title: "\(CloudHelp.money(p.amount, currency: p.currency)) · \(CloudHelp.short(p.who, 40))",
                                 subtitle: subtitle, tone: tone(p), url: dashboardURL(p, testMode: s.testMode))
        }
        status = ConnectorStatus(state: .ok, headline: tr("connect.stripe.revenueToday", revenueText(s)), detail: detail, items: items,
                                 updated: Date(), needsAttention: !failed.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(StripeConnector.keyAccount) else {
            throw CloudHelp.notSetUp("Stripe")
        }
        let s = try await fetch(key: key, recentCount: 15)
        apply(s)
        var out = ["Today's revenue (net): \(revenueText(s)) · \(status.detail)", "", "Recent payments:"]
        if s.recent.isEmpty { out.append("- none") }
        for p in s.recent {
            var line = "- \(CloudHelp.money(p.amount, currency: p.currency)) · \(p.who) · \(statusLabel(p.status)) · \(NookDates.short(p.created))"
            if p.refunded > 0 { line += " · \(CloudHelp.money(p.refunded, currency: p.currency)) refunded" }
            if let failure = p.failure, !failure.isEmpty { line += " · reason: \(failure)" }
            if let url = dashboardURL(p, testMode: s.testMode) { line += " · \(url.absoluteString)" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: Notion

@MainActor
final class NotionConnector: CloudConnectorConfig {
    let id = "notion"
    let title = "Notion"
    let symbol = "doc.text"
    let accent = Color(hex: 0xD9D4C7)
    let refreshInterval: TimeInterval = 300
    @Published private(set) var status = ConnectorStatus()

    static let tokenAccount = "connector.notion.token"
    static var fields: [ConnectorField] {
        [ConnectorField(account: NotionConnector.tokenAccount, label: tr("connect.field.token"), placeholder: "ntn_… / secret_…", secret: true)]
    }
    static var helpText: String { tr("connect.notion.help") }
    static let signupURL = URL(string: "https://www.notion.so/profile/integrations")

    private struct Page {
        let id: String
        let title: String
        let edited: Date?
        let url: URL?
    }

    private var pages: [Page] = []
    private var loaded = false

    var isConfigured: Bool { CloudHelp.secret(NotionConnector.tokenAccount) != nil }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(NotionConnector.tokenAccount) else {
            pages = []
            loaded = false
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await search(token: token, query: nil, count: 8)
            apply(fresh)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded, !pages.isEmpty else { return [] }
        let parts = pages.prefix(5).map { p -> String in
            var part = "'\(CloudHelp.short(p.title, 50))'"
            if let edited = p.edited { part += " (\(NookDates.ago(edited)))" }
            return part
        }
        return ["Notion, recently edited: " + parts.joined(separator: ", ")]
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "notion_search",
                description: "Searches Notion pages shared with Nook, most recently edited first. Without a search term, returns recently edited pages with links.",
                schema: CloudHelp.schema([
                    "query": ["type": "string", "description": "Search term in page title. Optional."]
                ]),
                kind: .read,
                summarize: { _ in "Read Notion" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("Notion") }
                    let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return try await self.overview(query: query)
                }
            ),
            ToolSpec(
                name: "notion_read_page",
                description: "Reads the text of a single Notion page (headings, paragraphs, lists, to-dos, quotes, code). Provide the ID or link from notion_search. Use this to actually read a document before summarizing or comparing it.",
                schema: ["type": "object", "properties": ["page": ["type": "string", "description": "Page ID or link."]], "required": ["page"]],
                kind: .read,
                summarize: { _ in "Read Notion page" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("Notion") }
                    return try await self.readPage((input["page"] as? String) ?? "")
                }
            )
        ]
    }

    /// The ID from an ID or link: the trailing 32 hex characters (with or without hyphens).
    nonisolated static func pageID(_ raw: String) -> String? {
        let hex = raw.lowercased().replacingOccurrences(of: "-", with: "")
        guard let range = hex.range(of: #"[0-9a-f]{32}(?![0-9a-f])"#, options: [.regularExpression, .backwards]) else { return nil }
        let id = String(hex[range])
        let parts = [id.prefix(8), id.dropFirst(8).prefix(4), id.dropFirst(12).prefix(4), id.dropFirst(16).prefix(4), id.dropFirst(20)]
        return parts.map(String.init).joined(separator: "-")
    }

    private func readPage(_ raw: String) async throws -> String {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(NotionConnector.tokenAccount) else {
            throw CloudHelp.notSetUp("Notion")
        }
        guard let pageID = Self.pageID(raw) else { throw NookError("Invalid Notion ID or link: \(raw)") }
        let headers = ["Authorization": "Bearer \(token)", "Notion-Version": "2022-06-28"]
        let page = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url("https://api.notion.com/v1/pages/\(pageID)"), headers: headers))
        let info = parse(page)
        var lines: [String] = []
        var cursor: String?
        var pages = 0
        repeat {
            var query = [("page_size", "100")]
            if let cursor { query.append(("start_cursor", cursor)) }
            let root = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url("https://api.notion.com/v1/blocks/\(pageID)", "/children", query: query), headers: headers))
            for block in CloudHelp.list(root["results"]) {
                if let line = blockText(block) { lines.append(line) }
            }
            cursor = (root["has_more"] as? Bool) == true ? root["next_cursor"] as? String : nil
            pages += 1
        } while cursor != nil && pages < 5
        var text = lines.joined(separator: "\n")
        if text.count > 15_000 { text = String(text.prefix(15_000)) + "\n… (truncated)" }
        var out = ["\(info?.title ?? "Notion page")" + (info?.edited.map { " · edited \(NookDates.short($0))" } ?? ""), ""]
        out.append(text.isEmpty ? "(No text on this page, or only unsupported blocks such as databases and images.)" : text)
        out.append(ReferenceParser.line(title: info?.title ?? "Notion page", url: info?.url?.absoluteString,
                                        detail: info?.edited.map { "edited \(NookDates.short($0))" } ?? ""))
        return out.joined(separator: "\n")
    }

    private func blockText(_ block: [String: Any]) -> String? {
        guard let type = block["type"] as? String else { return nil }
        let content = CloudHelp.object(block[type])
        guard let text = plainText(content["rich_text"]) else {
            if type == "child_page", let title = content["title"] as? String { return "[subpage] \(title)" }
            return nil
        }
        switch type {
        case "heading_1": return "# " + text
        case "heading_2": return "## " + text
        case "heading_3": return "### " + text
        case "bulleted_list_item": return "- " + text
        case "numbered_list_item": return "1. " + text
        case "to_do": return ((content["checked"] as? Bool) == true ? "- [x] " : "- [ ] ") + text
        case "quote", "callout": return "> " + text
        case "code": return "```\n" + text + "\n```"
        default: return text
        }
    }

    private func search(token: String, query: String?, count: Int) async throws -> [Page] {
        var body: [String: Any] = [
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "filter": ["property": "object", "value": "page"],
            "page_size": count
        ]
        if let query = query, !query.isEmpty { body["query"] = query }
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = try CloudHelp.url("https://api.notion.com/v1/search")
        let raw = try await ConnectorHTTP.json(url, headers: [
            "Authorization": "Bearer \(token)",
            "Notion-Version": "2022-06-28"
        ], method: "POST", body: data)
        return CloudHelp.list(CloudHelp.object(raw)["results"]).compactMap { parse($0) }
    }

    private func parse(_ obj: [String: Any]) -> Page? {
        guard let id = obj["id"] as? String else { return nil }
        var title = ""
        // Databases have "title" at root; pages have a property of type "title".
        if let text = plainText(obj["title"]) { title = text }
        if title.isEmpty {
            for (_, value) in CloudHelp.object(obj["properties"]) {
                let property = CloudHelp.object(value)
                if (property["type"] as? String) == "title", let text = plainText(property["title"]) {
                    title = text
                    break
                }
            }
        }
        return Page(
            id: id,
            title: title.isEmpty ? "Untitled" : title,
            edited: CloudHelp.date(obj["last_edited_time"]),
            url: CloudHelp.link(obj["url"] as? String)
        )
    }

    private func plainText(_ value: Any?) -> String? {
        let text = CloudHelp.list(value).compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }

    private func apply(_ list: [Page]) {
        pages = list
        loaded = true
        var detail = ""
        if let first = list.first {
            detail = "Latest: \(CloudHelp.short(first.title, 40))"
            if let edited = first.edited { detail += " · \(NookDates.ago(edited))" }
        }
        let items = list.map { p in
            ConnectorItem(id: p.id, title: p.title,
                          subtitle: p.edited.map { "edited \(NookDates.ago($0))" } ?? "",
                          tone: .neutral, url: p.url)
        }
        status = ConnectorStatus(state: .ok,
                                 headline: list.isEmpty ? tr("connect.notion.noPages") : tr("connect.notion.recentlyEdited", list.count),
                                 detail: detail, items: items, updated: Date(), needsAttention: false)
    }

    private func overview(query: String?) async throws -> String {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(NotionConnector.tokenAccount) else {
            throw CloudHelp.notSetUp("Notion")
        }
        let hasQuery = !(query ?? "").isEmpty
        let list = try await search(token: token, query: query, count: 20)
        if !hasQuery { apply(Array(list.prefix(8))) }
        if list.isEmpty {
            return hasQuery ? "No Notion pages found for '\(query ?? "")'." : "No Notion pages shared with Nook."
        }
        let lines = list.map { p -> String in
            var line = "- \(p.title) (id \(p.id))"
            if let edited = p.edited { line += " · edited \(NookDates.short(edited))" }
            return line
        }
        let refs = list.prefix(10).map { p in
            ReferenceParser.line(title: p.title, url: p.url?.absoluteString, detail: p.edited.map { "edited \(NookDates.short($0))" } ?? "")
        }
        return (lines + refs).joined(separator: "\n")
    }
}

// MARK: Cal.com

@MainActor
final class CalcomConnector: CloudConnectorConfig {
    let id = "calcom"
    let title = "Cal.com"
    let symbol = "calendar.badge.clock"
    let accent = Color(hex: 0x5FD3F3)
    let refreshInterval: TimeInterval = 300
    @Published private(set) var status = ConnectorStatus()

    static let keyAccount = "connector.calcom.key"
    static var fields: [ConnectorField] {
        [ConnectorField(account: CalcomConnector.keyAccount, label: tr("connect.field.apiKey"), placeholder: "cal_live_…", secret: true)]
    }
    static var helpText: String { tr("connect.calcom.help") }
    static let signupURL = URL(string: "https://app.cal.com/settings/developer/api-keys")

    private struct Booking {
        let id: String
        let title: String
        let start: Date
        let end: Date?
        let status: String
        let attendee: String?
        let url: URL?

        var needsConfirmation: Bool { status == "pending" || status == "unconfirmed" }
    }

    private var bookings: [Booking] = []
    private var loaded = false

    var isConfigured: Bool { CloudHelp.secret(CalcomConnector.keyAccount) != nil }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(CalcomConnector.keyAccount) else {
            bookings = []
            loaded = false
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await fetch(key: key, count: 20)
            apply(fresh)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded else { return [] }
        if bookings.isEmpty { return ["Cal.com: no upcoming bookings."] }
        var lines = ["Cal.com: \(CloudHelp.plural(bookings.count, "upcoming booking", "upcoming bookings"))."]
        for b in bookings.prefix(4) {
            lines.append("Booking: \(line(for: b))")
        }
        let pending = bookings.filter { $0.needsConfirmation }
        if !pending.isEmpty {
            lines.append("Cal.com: \(CloudHelp.plural(pending.count, "booking awaiting", "bookings awaiting")) confirmation.")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "calcom_bookings",
                description: "Fetches upcoming Cal.com bookings for the user: title, time, attendee, status, and link.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read Cal.com" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("Cal.com") }
                    return try await self.overview()
                }
            )
        ]
    }

    private func fetch(key: String, count: Int) async throws -> [Booking] {
        let url = try CloudHelp.url("https://api.cal.com", "/v2/bookings", query: [
            ("status", "upcoming"), ("take", String(count))
        ])
        let raw = try await ConnectorHTTP.json(url, headers: [
            "Authorization": "Bearer \(key)",
            "cal-api-version": "2024-08-13"
        ])
        let skip: Set<String> = ["cancelled", "rejected"]
        return CloudHelp.list(CloudHelp.object(raw)["data"])
            .compactMap { parse($0) }
            .filter { !skip.contains($0.status) }
            .sorted { $0.start < $1.start }
    }

    private func parse(_ b: [String: Any]) -> Booking? {
        guard let start = CloudHelp.date(b["start"]) ?? CloudHelp.date(b["startTime"]) else { return nil }
        let uid = CloudHelp.string(b["uid"])
        let attendee = CloudHelp.list(b["attendees"]).first.flatMap { ($0["name"] as? String) ?? ($0["email"] as? String) }
        return Booking(
            id: uid ?? CloudHelp.string(b["id"]) ?? UUID().uuidString,
            title: (b["title"] as? String) ?? "Appointment",
            start: start,
            end: CloudHelp.date(b["end"]) ?? CloudHelp.date(b["endTime"]),
            status: ((b["status"] as? String) ?? "accepted").lowercased(),
            attendee: attendee,
            url: uid.flatMap { URL(string: "https://app.cal.com/booking/\($0)") }
        )
    }

    private func line(for b: Booking) -> String {
        var text = "'\(CloudHelp.short(b.title, 50))'"
        if let who = b.attendee { text += " with \(who)" }
        text += ", \(NookDates.short(b.start))"
        if b.needsConfirmation { text += " (awaiting confirmation)" }
        return text
    }

    private func apply(_ list: [Booking]) {
        bookings = list
        loaded = true
        let calendar = Calendar.current
        let today = list.filter { calendar.isDateInToday($0.start) }.count
        let pending = list.filter { $0.needsConfirmation }

        let headline: String
        if let next = list.first {
            headline = tr("connect.calcom.next", NookDates.short(next.start))
        } else {
            headline = tr("connect.calcom.noBookings")
        }
        var detail = "\(today) today · \(list.count) upcoming"
        if !pending.isEmpty { detail += " · \(pending.count) to confirm" }

        let items = list.prefix(8).map { b -> ConnectorItem in
            var subtitle = NookDates.short(b.start)
            if let who = b.attendee { subtitle += " · with \(who)" }
            if b.needsConfirmation { subtitle += " · confirm" }
            return ConnectorItem(id: b.id, title: b.title, subtitle: subtitle,
                                 tone: b.needsConfirmation ? .attention : .neutral, url: b.url)
        }
        status = ConnectorStatus(state: .ok, headline: headline, detail: detail, items: Array(items),
                                 updated: Date(), needsAttention: !pending.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(CalcomConnector.keyAccount) else {
            throw CloudHelp.notSetUp("Cal.com")
        }
        let list = try await fetch(key: key, count: 40)
        apply(list)
        if list.isEmpty { return "No upcoming Cal.com bookings." }
        return list.map { b -> String in
            var text = "- \(line(for: b))"
            if let url = b.url { text += " · \(url.absoluteString)" }
            return text
        }.joined(separator: "\n")
    }
}

extension CalcomConnector: AgendaSource {
    func agendaNames() -> [String] { ["Cal.com bookings"] }

    func agendaEntries(from: Date, to: Date) async throws -> AgendaResult {
        guard let key = CloudHelp.secret(CalcomConnector.keyAccount) else { throw CloudHelp.notSetUp("Cal.com") }
        let list = try await fetch(key: key, count: 100)
        let entries = list.compactMap { booking -> AgendaEntry? in
            let end = booking.end ?? booking.start.addingTimeInterval(1800)
            guard booking.start < to, end > from else { return nil }
            return AgendaEntry(title: booking.title, start: booking.start, end: end, busy: true, calendar: "Cal.com")
        }
        return AgendaResult(entries: entries)
    }
}

// MARK: n8n

@MainActor
final class N8nConnector: CloudConnectorConfig {
    let id = "n8n"
    let title = "n8n"
    let symbol = "point.3.connected.trianglepath.dotted"
    let accent = Color(hex: 0xFF7A59)
    let refreshInterval: TimeInterval = 180
    @Published private(set) var status = ConnectorStatus()

    static let urlAccount = "connector.n8n.url"
    static let keyAccount = "connector.n8n.key"
    static var fields: [ConnectorField] {
        [
            ConnectorField(account: N8nConnector.urlAccount, label: tr("connect.n8n.address"), placeholder: "https://n8n.example.com", secret: false),
            ConnectorField(account: N8nConnector.keyAccount, label: tr("connect.field.apiKey"), placeholder: tr("connect.n8n.keyPlaceholder"), secret: true)
        ]
    }
    static var helpText: String { tr("connect.n8n.help") }
    static let signupURL = URL(string: "https://docs.n8n.io/api/authentication/")

    private struct Failure {
        let id: String
        let workflowID: String
        let workflow: String
        let when: Date?
        let url: URL?
    }

    private struct Snapshot {
        let workflows: Int
        let active: Int
        let failures: [Failure]

        var recentFailures: [Failure] {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            return failures.filter { ($0.when ?? .distantPast) > cutoff }
        }
    }

    private var snapshot: Snapshot?

    var isConfigured: Bool {
        CloudHelp.secret(N8nConnector.urlAccount) != nil && CloudHelp.secret(N8nConnector.keyAccount) != nil
    }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id),
              let rawBase = CloudHelp.secret(N8nConnector.urlAccount),
              let key = CloudHelp.secret(N8nConnector.keyAccount) else {
            snapshot = nil
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await fetch(rawBase: rawBase, key: key, failureCount: 10)
            apply(fresh)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        let recent = s.recentFailures
        var lines = ["n8n: \(s.active) of \(s.workflows) workflows active, \(CloudHelp.plural(recent.count, "failed run", "failed runs")) in 24 hours."]
        for f in recent.prefix(4) {
            var line = "n8n run failed: '\(CloudHelp.short(f.workflow, 50))'"
            if let when = f.when { line += " (\(NookDates.ago(when)))" }
            lines.append(line)
        }
        return lines
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "n8n_status",
                description: "Fetches the user's n8n workflows (active count) and recent failed runs with workflow, time, and link. Read only.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read n8n" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("n8n") }
                    return try await self.overview()
                }
            )
        ]
    }

    /// "https://n8n.example.com/" or ".../api/v1" becomes "https://n8n.example.com".
    private func normalizedBase(_ raw: String) throws -> String {
        var base = raw
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/api/v1") { base = String(base.dropLast("/api/v1".count)) }
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw NookError("The n8n address must start with https://")
        }
        return base
    }

    private func fetch(rawBase: String, key: String, failureCount: Int) async throws -> Snapshot {
        let base = try normalizedBase(rawBase)
        let auth = ["X-N8N-API-KEY": key]

        let workflowsURL = try CloudHelp.url(base, "/api/v1/workflows", query: [("limit", "250")])
        let workflowsRaw = try await ConnectorHTTP.json(workflowsURL, headers: auth)
        let workflows = CloudHelp.list(CloudHelp.object(workflowsRaw)["data"])
        var names: [String: String] = [:]
        var active = 0
        for workflow in workflows {
            if let wid = CloudHelp.string(workflow["id"]) { names[wid] = (workflow["name"] as? String) ?? "Workflow" }
            if (workflow["active"] as? Bool) == true { active += 1 }
        }

        let executionsURL = try CloudHelp.url(base, "/api/v1/executions", query: [
            ("status", "error"), ("limit", String(failureCount))
        ])
        let executionsRaw = try await ConnectorHTTP.json(executionsURL, headers: auth)
        let executions = CloudHelp.list(CloudHelp.object(executionsRaw)["data"])
        let failures = executions.compactMap { e -> Failure? in
            guard let eid = CloudHelp.string(e["id"]) else { return nil }
            let wid = CloudHelp.string(e["workflowId"]) ?? ""
            return Failure(
                id: eid,
                workflowID: wid,
                workflow: names[wid] ?? (wid.isEmpty ? "Workflow" : "Workflow \(wid)"),
                when: CloudHelp.date(e["stoppedAt"]) ?? CloudHelp.date(e["startedAt"]),
                url: wid.isEmpty ? nil : URL(string: "\(base)/workflow/\(wid)/executions/\(eid)")
            )
        }
        return Snapshot(workflows: workflows.count, active: active, failures: failures)
    }

    private func apply(_ s: Snapshot) {
        snapshot = s
        let recent = s.recentFailures
        let detail = recent.isEmpty
            ? "No errors in 24 hours"
            : CloudHelp.plural(recent.count, "failed run", "failed runs") + " in 24 hours"
        let items = s.failures.prefix(8).map { f -> ConnectorItem in
            let isRecent = (f.when ?? .distantPast) > Date().addingTimeInterval(-24 * 3600)
            return ConnectorItem(id: f.id, title: f.workflow,
                                 subtitle: "Failed" + (f.when.map { " · \(NookDates.ago($0))" } ?? ""),
                                 tone: isRecent ? .bad : .neutral, url: f.url)
        }
        status = ConnectorStatus(state: .ok,
                                 headline: tr("connect.n8n.activeWorkflows", s.active),
                                 detail: detail, items: Array(items), updated: Date(), needsAttention: !recent.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id),
              let rawBase = CloudHelp.secret(N8nConnector.urlAccount),
              let key = CloudHelp.secret(N8nConnector.keyAccount) else {
            throw CloudHelp.notSetUp("n8n")
        }
        let s = try await fetch(rawBase: rawBase, key: key, failureCount: 25)
        apply(s)
        var out = ["Workflows: \(s.workflows), with \(s.active) active.", "", "Recent failed runs:"]
        if s.failures.isEmpty { out.append("- none") }
        for f in s.failures {
            var line = "- \(f.workflow) (run \(f.id))"
            if let when = f.when { line += " · \(NookDates.short(when))" }
            if let url = f.url { line += " · \(url.absoluteString)" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: Resend

@MainActor
final class ResendConnector: CloudConnectorConfig {
    let id = "resend"
    let title = "Resend"
    let symbol = "paperplane"
    let accent = Color(hex: 0xF5C24C)
    let refreshInterval: TimeInterval = 300
    @Published private(set) var status = ConnectorStatus()

    static let keyAccount = "connector.resend.key"
    static var fields: [ConnectorField] {
        [ConnectorField(account: ResendConnector.keyAccount, label: tr("connect.field.apiKey"), placeholder: "re_…", secret: true)]
    }
    static var helpText: String { tr("connect.resend.help") }
    static let signupURL = URL(string: "https://resend.com/api-keys")

    private struct Domain {
        let id: String
        let name: String
        let status: String
    }

    private struct Email {
        let id: String
        let to: String
        let subject: String
        let event: String
        let created: Date?
    }

    private struct Snapshot {
        let domains: [Domain]
        let emails: [Email]

        var unverified: [Domain] { domains.filter { $0.status != "verified" } }
        var troubled: [Email] { emails.filter { $0.event == "bounced" || $0.event == "complained" } }
    }

    private var snapshot: Snapshot?

    var isConfigured: Bool { CloudHelp.secret(ResendConnector.keyAccount) != nil }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(ResendConnector.keyAccount) else {
            snapshot = nil
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await fetch(key: key, count: 20)
            apply(fresh)
        } catch {
            CloudHelp.fail(&status, error, service: title)
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        var lines = ["Resend: \(CloudHelp.plural(s.domains.count, "domain", "domains")), \(CloudHelp.plural(s.emails.count, "recent email", "recent emails"))."]
        for d in s.unverified.prefix(3) {
            lines.append("Resend domain not verified: \(d.name) (\(d.status))")
        }
        for e in s.troubled.prefix(3) {
            lines.append("Email \(eventLabel(e.event)): '\(CloudHelp.short(e.subject, 50))' to \(e.to)")
        }
        if let last = s.emails.first {
            lines.append("Latest email: '\(CloudHelp.short(last.subject, 50))' to \(last.to), \(eventLabel(last.event))")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "resend_overview",
                description: "Fetches emails recently sent via Resend (recipient, subject, delivered/bounced) and domain status. Never sends anything.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Read Resend" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("Resend") }
                    return try await self.overview()
                }
            )
        ]
    }

    private func fetch(key: String, count: Int) async throws -> Snapshot {
        let auth = ["Authorization": "Bearer \(key)"]
        let domainsURL = try CloudHelp.url("https://api.resend.com/domains")
        let domainsRaw = try await ConnectorHTTP.json(domainsURL, headers: auth)
        let domains = CloudHelp.list(CloudHelp.object(domainsRaw)["data"]).compactMap { d -> Domain? in
            guard let did = CloudHelp.string(d["id"]), let name = d["name"] as? String else { return nil }
            return Domain(id: did, name: name, status: (d["status"] as? String) ?? "unknown")
        }
        // The email list is optional: without those permissions we only display domains.
        let emailsObject = await CloudHelp.optionalObject(URL(string: "https://api.resend.com/emails?limit=\(count)"), headers: auth)
        let emails = CloudHelp.list(emailsObject?["data"]).compactMap { e -> Email? in
            guard let eid = CloudHelp.string(e["id"]) else { return nil }
            let to: String
            if let list = e["to"] as? [String] {
                to = list.joined(separator: ", ")
            } else {
                to = (e["to"] as? String) ?? "?"
            }
            return Email(id: eid, to: to, subject: (e["subject"] as? String) ?? "(no subject)",
                         event: (e["last_event"] as? String) ?? "", created: parseDate(e["created_at"]))
        }
        return Snapshot(domains: domains, emails: emails)
    }

    /// Resend sometimes returns "2023-04-03 22:13:42.674981+00" instead of ISO 8601.
    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = NookDates.parse(text) { return date }
        return Self.resendFormat.date(from: String(text.prefix(19)))
    }

    private static let resendFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func eventLabel(_ event: String) -> String {
        switch event {
        case "delivered": return "delivered"
        case "sent": return "sent"
        case "opened": return "opened"
        case "clicked": return "clicked"
        case "bounced": return "bounced"
        case "complained": return "reported as spam"
        case "delivery_delayed": return "delayed"
        case "": return "unknown"
        default: return event
        }
    }

    private func tone(_ event: String) -> ConnectorTone {
        switch event {
        case "delivered", "opened", "clicked": return .good
        case "bounced", "complained": return .bad
        case "delivery_delayed": return .attention
        default: return .neutral
        }
    }

    private func apply(_ s: Snapshot) {
        snapshot = s
        let unverified = s.unverified
        let troubled = s.troubled

        let headline: String
        if let first = unverified.first {
            headline = tr("connect.resend.domainNotReady", first.name)
        } else if s.emails.isEmpty {
            headline = tr("connect.resend.domainsOk", s.domains.count)
        } else {
            headline = tr("connect.resend.recentMails", s.emails.count)
        }
        let detail = troubled.isEmpty
            ? "No bounces"
            : CloudHelp.plural(troubled.count, "delivery issue", "delivery issues")

        var items: [ConnectorItem] = unverified.prefix(3).map { d in
            ConnectorItem(id: "domain-\(d.id)", title: d.name, subtitle: "Domain · \(d.status)",
                          tone: d.status == "failed" ? .bad : .attention,
                          url: URL(string: "https://resend.com/domains/\(d.id)"))
        }
        for e in s.emails.prefix(max(0, 8 - items.count)) {
            var subtitle = "\(eventLabel(e.event)) · to \(e.to)"
            if let created = e.created { subtitle += " · \(NookDates.ago(created))" }
            items.append(ConnectorItem(id: "email-\(e.id)", title: e.subject, subtitle: subtitle,
                                       tone: tone(e.event), url: URL(string: "https://resend.com/emails/\(e.id)")))
        }
        status = ConnectorStatus(state: .ok, headline: headline, detail: detail, items: items,
                                 updated: Date(), needsAttention: !unverified.isEmpty || !troubled.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(ResendConnector.keyAccount) else {
            throw CloudHelp.notSetUp("Resend")
        }
        let s = try await fetch(key: key, count: 50)
        apply(s)
        var out = ["Domains:"]
        if s.domains.isEmpty { out.append("- none") }
        for d in s.domains { out.append("- \(d.name): \(d.status)") }
        out.append("")
        out.append("Recent emails:")
        if s.emails.isEmpty { out.append("- none (or the key does not have permission to read emails)") }
        for e in s.emails {
            var line = "- '\(e.subject)' to \(e.to) · \(eventLabel(e.event))"
            if let created = e.created { line += " · \(NookDates.short(created))" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}

// MARK: Pull requests from workspace

/// Open a pull request using the existing GitHub connection. Only after explicit user action in the workspace.
enum GitHubPullRequests {
    /// Whether the GitHub connector is active and has a token. Otherwise Nook opens the compare page on github.com.
    static var isAvailable: Bool {
        ConnectorToggle.isOn("github") && !tokens.isEmpty
    }

    /// Tokens of all GitHub accounts, primary first.
    private static var tokens: [String] {
        AccountRegistry.shared.accounts(for: "github").compactMap { CloudHelp.secret($0.key("token")) }
    }

    /// "owner/repo" and the number of a pull request link ("https://github.com/owner/repo/pull/12").
    static func parse(_ url: URL) -> (repo: String, number: Int)? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.host?.hasSuffix("github.com") == true, parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        return (parts[0] + "/" + parts[1], number)
    }

    /// A pull request's state, checks, reviews and comments, for a session that watches it. Nil when
    /// no connected account can read it.
    static func snapshot(url: URL) async -> PullRequestSnapshot? {
        guard isAvailable, let target = parse(url) else { return nil }
        let repo = target.repo, number = target.number
        for token in tokens {
            let auth = ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
            let base = "https://api.github.com/repos/\(repo)"
            func get(_ path: String) async -> Any? {
                guard let url = URL(string: base + path) else { return nil }
                return try? await ConnectorHTTP.json(url, headers: auth)
            }
            guard let pull = await get("/pulls/\(number)") as? [String: Any] else { continue }
            let merged = (pull["merged"] as? Bool) ?? false
            let state = merged ? "merged" : ((pull["state"] as? String) == "open" ? "open" : "closed")
            var checks = ""
            var failed: [String] = []
            if let sha = (pull["head"] as? [String: Any])?["sha"] as? String,
               let runs = (await get("/commits/\(sha)/check-runs?per_page=100") as? [String: Any])?["check_runs"] as? [[String: Any]],
               !runs.isEmpty {
                failed = runs.filter { ["failure", "timed_out", "cancelled", "action_required"].contains(($0["conclusion"] as? String) ?? "") }
                    .compactMap { $0["name"] as? String }
                let pending = runs.contains { ($0["status"] as? String) != "completed" }
                checks = !failed.isEmpty ? "failure" : pending ? "pending" : "success"
            }
            func author(_ item: [String: Any]) -> String { ((item["user"] as? [String: Any])?["login"] as? String) ?? "?" }
            let reviews = ((await get("/pulls/\(number)/reviews?per_page=100")) as? [[String: Any]] ?? [])
                .filter { ($0["state"] as? String) != "PENDING" }
                .map { PullRequestSnapshot.Note(author: author($0), verdict: ($0["state"] as? String) ?? "", text: ($0["body"] as? String) ?? "") }
            let issueComments = (await get("/issues/\(number)/comments?per_page=100")) as? [[String: Any]] ?? []
            let lineComments = (await get("/pulls/\(number)/comments?per_page=100")) as? [[String: Any]] ?? []
            let comments = (issueComments + lineComments)
                .sorted { (($0["created_at"] as? String) ?? "") < (($1["created_at"] as? String) ?? "") }
                .map { item -> PullRequestSnapshot.Note in
                    var text = (item["body"] as? String) ?? ""
                    if let path = item["path"] as? String { text = path + ": " + text }
                    return PullRequestSnapshot.Note(author: author(item), verdict: "", text: text)
                }
            return PullRequestSnapshot(state: state, checks: checks, failedChecks: failed, reviews: reviews, comments: comments)
        }
        return nil
    }

    /// Tries the accounts in order: the first one with access to the repository opens the pull request.
    static func create(repo: String, title: String, body: String, head: String, base: String, draft: Bool) async throws -> URL {
        let available = tokens
        guard ConnectorToggle.isOn("github"), !available.isEmpty else { throw CloudHelp.notSetUp("GitHub") }
        var lastError: Error = CloudHelp.notSetUp("GitHub")
        for token in available {
            do {
                return try await create(repo: repo, title: title, body: body, head: head, base: base, draft: draft, token: token)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// The open pull request whose head is `branch` (for the git button), asked with the first account that can see the
    /// repository. Nil when there is none, or GitHub is not connected.
    static func openPullRequest(repo: String, branch: String) async -> URL? {
        guard isAvailable, let owner = repo.split(separator: "/").first.map(String.init) else { return nil }
        for token in tokens {
            guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls") else { return nil }
            components.queryItems = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "head", value: owner + ":" + branch),
                                     URLQueryItem(name: "per_page", value: "1")]
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            return (list.first?["html_url"] as? String).flatMap(URL.init(string:))
        }
        return nil
    }

    /// The open pull requests of a repository (newest first, at most 30), for the `#` list in a message. Asked with the first
    /// account that can see the repository; empty when GitHub is not connected.
    static func openPullRequests(repo: String) async -> [(number: Int, title: String)] {
        guard isAvailable else { return [] }
        for token in tokens {
            guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls") else { return [] }
            components.queryItems = [URLQueryItem(name: "state", value: "open"), URLQueryItem(name: "per_page", value: "30"),
                                     URLQueryItem(name: "sort", value: "updated"), URLQueryItem(name: "direction", value: "desc")]
            guard let url = components.url else { return [] }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            return list.compactMap { item in
                guard let number = item["number"] as? Int, let title = item["title"] as? String else { return nil }
                return (number, title)
            }
        }
        return []
    }

    /// The pull requests (any state) whose head is `branch` in `repo`, for the badge on a session. nil when GitHub cannot
    /// be asked (not connected, offline), so a failed check never looks like "no pull request".
    static func pullRequests(repo: String, branch: String) async -> [PullRequestLink]? {
        guard isAvailable, let owner = repo.split(separator: "/").first else { return nil }
        for token in tokens {
            guard var components = URLComponents(string: "https://api.github.com/repos/\(repo)/pulls") else { return nil }
            components.queryItems = [URLQueryItem(name: "state", value: "all"), URLQueryItem(name: "per_page", value: "10"),
                                     URLQueryItem(name: "head", value: "\(owner):\(branch)")]
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Nook", forHTTPHeaderField: "User-Agent")
            guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            let iso = ISO8601DateFormatter()
            var links: [PullRequestLink] = list.compactMap { item in
                guard let number = item["number"] as? Int, let html = item["html_url"] as? String else { return nil }
                let merged = (item["merged_at"] as? String) != nil
                let open = (item["state"] as? String) == "open"
                let state: PullRequestState = merged ? .merged : open ? ((item["draft"] as? Bool) == true ? .draft : .open) : .closed
                return PullRequestLink(host: .github, repository: repo, number: number, url: html, title: item["title"] as? String,
                                       state: state, updatedAt: (item["updated_at"] as? String).flatMap(iso.date(from:)),
                                       baseBranch: (item["base"] as? [String: Any])?["ref"] as? String,
                                       headBranch: branch)
            }
            // The list leaves out mergeability: ask each open one on its own.
            for index in links.indices where links[index].state.isOpen {
                links[index].conflicted = await conflicted(repo: repo, number: links[index].number, token: token)
            }
            return links
        }
        return nil
    }

    /// Whether an open pull request has a merge conflict with its base. False when GitHub cannot say (yet).
    private static func conflicted(repo: String, number: Int, token: String) async -> Bool {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/pulls/\(number)") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await ConnectorHTTP.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let pull = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return PullRequestMergeability.githubConflicted(pull)
    }

    private static func create(repo: String, title: String, body: String, head: String, base: String, draft: Bool, token: String) async throws -> URL {
        let url = try CloudHelp.url("https://api.github.com/repos/\(repo)/pulls")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "title": title, "body": body, "head": head, "base": base, "draft": draft
        ])
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let link = object["html_url"] as? String, let result = URL(string: link) else {
            var message = (object["message"] as? String) ?? "GitHub returned an error (\(status))."
            if let errors = object["errors"] as? [[String: Any]] {
                let details = errors.compactMap { $0["message"] as? String }
                if !details.isEmpty { message += " " + details.joined(separator: " ") }
            }
            throw NookError("GitHub: \(message)")
        }
        return result
    }
}
