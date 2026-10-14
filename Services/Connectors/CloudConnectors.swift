import SwiftUI

// Koppelingen met online diensten: GitHub, Vercel, Stripe, Notion, Cal.com, n8n en Resend.
// Elke koppeling leest alleen. Sleutels staan in de Keychain onder "connector.<id>.<veld>".
// Endpoints en velden naar het voorbeeld van Coucou (MIT), opnieuw geschreven in de stijl van Nook.

// MARK: Instellingen-velden

/// Eén invulveld voor een koppeling in de instellingen (token, adres…). De waarde gaat naar de Keychain onder `account`.
struct ConnectorField {
    let account: String
    let label: String
    let placeholder: String
    let secret: Bool

    /// Plakken geeft vaak spaties, regeleinden of aanhalingstekens mee.
    static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
    }
}

/// Wat de instellingen van een online koppeling moeten weten: welke velden, uitleg en waar je een sleutel maakt.
@MainActor
protocol CloudConnectorConfig: ContextSource, ObservableObject {
    static var fields: [ConnectorField] { get }
    static var helpText: String { get }
    static var signupURL: URL? { get }
    /// Alle verplichte sleutels staan in de Keychain (los van aan/uit).
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
    /// Eén exemplaar van elke online koppeling, in de volgorde van de instellingen.
    @MainActor
    static func makeAll() -> [ContextSource] {
        [
            GitHubConnector(),
            VercelConnector(),
            StripeConnector(),
            NotionConnector(),
            CalcomConnector(),
            N8nConnector(),
            ResendConnector()
        ]
    }
}

// MARK: Hulpjes

enum CloudHelp {
    /// Een opgeschoonde waarde uit de Keychain, of nil als hij leeg is.
    static func secret(_ account: String) -> String? {
        guard let value = Keychain.read(account) else { return nil }
        let cleaned = ConnectorField.clean(value)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func url(_ string: String) throws -> URL {
        guard let url = URL(string: string) else { throw NookError("Ongeldig adres: \(string)") }
        return url
    }

    static func url(_ base: String, _ path: String, query: [(String, String)]) throws -> URL {
        guard var components = URLComponents(string: base + path) else { throw NookError("Ongeldig adres: \(base)") }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        guard let url = components.url else { throw NookError("Ongeldig adres: \(base)") }
        return url
    }

    /// Haalt JSON op en geeft nil bij elke fout; voor extra's die mogen ontbreken.
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

    /// Id's zijn soms tekst, soms een getal.
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return NookDates.parse(text)
    }

    /// Alleen https-links worden klikbaar.
    static func link(_ string: String?) -> URL? {
        guard let string = string, let url = URL(string: string),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    static func errorText(_ error: Error, service: String) -> String {
        if let nook = error as? NookError { return nook.message }
        if error is URLError { return "Geen verbinding met \(service). Nook probeert het straks opnieuw." }
        return "\(service) gaf een onverwacht antwoord."
    }

    /// "5 min. geleden"
    static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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

    /// Valuta's zonder centen bij Stripe.
    static let zeroDecimal: Set<String> = [
        "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga", "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf"
    ]

    /// Bedrag in de kleinste eenheid (centen) als "€ 1.240,50".
    static func money(_ minor: Int, currency: String) -> String {
        let code = currency.lowercased()
        let amount = zeroDecimal.contains(code) ? Double(minor) : Double(minor) / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "nl_NL")
        formatter.currencyCode = code.uppercased()
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount) \(code.uppercased())"
    }

    /// JSON-schema voor een lees-tool.
    static func schema(_ properties: [String: [String: Any]] = [:]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": [String]()]
    }

    static func notSetUp(_ service: String) -> NookError {
        NookError("\(service) is nog niet ingesteld of staat uit (Instellingen › Koppelingen).")
    }
}

// MARK: GitHub

@MainActor
final class GitHubConnector: CloudConnectorConfig {
    let id = "github"
    let title = "GitHub"
    let symbol = "chevron.left.forwardslash.chevron.right"
    let accent = Color(hex: 0xA5B4FC)
    let refreshInterval: TimeInterval = 180
    @Published private(set) var status = ConnectorStatus()

    static let tokenAccount = "connector.github.token"
    static let fields = [
        ConnectorField(account: GitHubConnector.tokenAccount, label: "Token", placeholder: "ghp_… of github_pat_…", secret: true)
    ]
    static let helpText = "Maak een token met alleen leesrechten. Klassiek: scope repo (of public_repo). Fine-grained: Pull requests, Commit statuses en Checks op alleen-lezen."
    static let signupURL = URL(string: "https://github.com/settings/tokens")

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

    private var snapshot: Snapshot?

    var isConfigured: Bool { CloudHelp.secret(GitHubConnector.tokenAccount) != nil }
    var isActive: Bool { isConfigured && ConnectorToggle.isOn(id) }

    func refresh() async {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(GitHubConnector.tokenAccount) else {
            snapshot = nil
            if status != ConnectorStatus() { status = ConnectorStatus() }
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let fresh = try await fetch(token: token)
            apply(fresh)
        } catch {
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        var lines = ["GitHub (@\(s.login)): \(CloudHelp.plural(s.mineTotal, "open PR", "open PR's")) van jou, \(CloudHelp.plural(s.reviewTotal, "reviewverzoek", "reviewverzoeken"))."]
        lines += s.reviews.prefix(3).map { "Review gevraagd: \($0.ref) '\(CloudHelp.short($0.title))'" }
        lines += s.mine.filter { $0.ci == .failing }.prefix(3).map { "CI faalt op \($0.ref) '\(CloudHelp.short($0.title))'" }
        let room = max(0, 8 - lines.count)
        lines += s.mine.filter { $0.ci != .failing }.prefix(min(room, 2)).map { "Open PR van jou: \($0.ref) '\(CloudHelp.short($0.title))'" }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "github_overview",
                description: "Haalt vers de open pull requests van de gebruiker op GitHub op, de PR's waarvoor een review van de gebruiker is gevraagd en de CI-status per PR, met links.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "GitHub lezen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    return try await self.overview()
                }
            )
        ]
    }

    // MARK: Ophalen

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
            throw NookError("GitHub gaf geen gebruikersnaam terug.")
        }
        let mineResult = try await search("is:pr is:open archived:false author:\(login)", auth: auth)
        let reviewResult = try await search("is:pr is:open archived:false review-requested:\(login)", auth: auth)

        // CI alleen voor de recentste PR's, om binnen de limieten van GitHub te blijven.
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
            title: (item["title"] as? String) ?? "Zonder titel",
            url: CloudHelp.link(item["html_url"] as? String),
            draft: (item["draft"] as? Bool) ?? false,
            updated: CloudHelp.date(item["updated_at"])
        )
    }

    /// Check runs én de oude commit-statussen van de laatste commit van een PR.
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

    // MARK: Tonen

    private func apply(_ s: Snapshot) {
        snapshot = s
        let failing = s.mine.filter { $0.ci == .failing }

        var headline = CloudHelp.plural(s.mineTotal, "open PR", "open PR's")
        if s.reviewTotal > 0 {
            headline += " · " + CloudHelp.plural(s.reviewTotal, "review", "reviews") + " voor jou"
        }
        let detail: String
        if !failing.isEmpty {
            detail = "CI faalt op " + failing.prefix(3).map { $0.ref }.joined(separator: ", ")
        } else if s.mine.contains(where: { $0.ci == .pending }) {
            detail = "CI draait nog"
        } else if s.mine.isEmpty {
            detail = "Geen open PR's van jou"
        } else {
            detail = "CI is groen"
        }

        var items: [ConnectorItem] = []
        for pr in s.reviews.prefix(4) {
            items.append(ConnectorItem(id: "review-\(pr.ref)", title: pr.title,
                                       subtitle: "Review gevraagd · \(pr.ref)", tone: .attention, url: pr.url))
        }
        for pr in s.mine.prefix(max(0, 8 - items.count)) {
            var parts = [pr.ref]
            if pr.draft { parts.append("concept") }
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
        case .failing: return "CI faalt"
        case .pending: return "CI draait"
        case .passing: return "CI groen"
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

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let token = CloudHelp.secret(GitHubConnector.tokenAccount) else {
            throw CloudHelp.notSetUp("GitHub")
        }
        let s = try await fetch(token: token)
        apply(s)
        var out = ["GitHub-account: @\(s.login)", "", "Open PR's van de gebruiker (\(s.mineTotal)):"]
        if s.mine.isEmpty { out.append("- geen") }
        for pr in s.mine {
            var line = "- \(pr.ref) '\(pr.title)'"
            if pr.draft { line += " [concept]" }
            let label = ciLabel(pr.ci)
            if !label.isEmpty { line += " [\(label)]" }
            if let updated = pr.updated { line += " · bijgewerkt \(CloudHelp.ago(updated))" }
            if let url = pr.url { line += " · \(url.absoluteString)" }
            out.append(line)
        }
        out.append("")
        out.append("Review gevraagd van de gebruiker (\(s.reviewTotal)):")
        if s.reviews.isEmpty { out.append("- geen") }
        for pr in s.reviews {
            var line = "- \(pr.ref) '\(pr.title)'"
            if let updated = pr.updated { line += " · bijgewerkt \(CloudHelp.ago(updated))" }
            if let url = pr.url { line += " · \(url.absoluteString)" }
            out.append(line)
        }
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
    static let fields = [
        ConnectorField(account: VercelConnector.tokenAccount, label: "Token", placeholder: "Vercel-token", secret: true),
        ConnectorField(account: VercelConnector.teamAccount, label: "Team-ID", placeholder: "team_… (optioneel)", secret: false)
    ]
    static let helpText = "Maak een token onder Account › Tokens, met als scope alleen het team of account dat Nook mag zien. Team-ID is alleen nodig voor deploys van een team."
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
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded else { return [] }
        let latest = latestPerProject(deployments)
        if latest.isEmpty { return ["Vercel: nog geen deploys."] }
        let summary = latest.prefix(4).map { d -> String in
            var part = "\(d.project): \(stateLabel(d.state))"
            if let created = d.created { part += " (\(CloudHelp.ago(created)))" }
            return part
        }
        var lines = ["Vercel, laatste deploys: " + summary.joined(separator: ", ")]
        for d in latest where d.state == "ERROR" {
            var line = "Vercel-deploy mislukt: \(d.project)"
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
                description: "Haalt vers de recentste Vercel-deploys van de gebruiker op: project, status (live, mislukt, bouwt), branch, commit en link.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Vercel lezen" },
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

    /// De API geeft de nieuwste eerst; per project telt alleen de laatste deploy.
    private func latestPerProject(_ list: [Deployment]) -> [Deployment] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.project).inserted }
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "READY": return "live"
        case "ERROR": return "mislukt"
        case "BUILDING": return "bouwt"
        case "QUEUED": return "in de wachtrij"
        case "INITIALIZING": return "start"
        case "CANCELED": return "geannuleerd"
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
            headline = "Deploy mislukt: " + broken.prefix(2).map { $0.project }.joined(separator: ", ")
        } else if let first = busy.first {
            headline = "Bezig: \(first.project)"
        } else if latest.isEmpty {
            headline = "Nog geen deploys"
        } else {
            headline = "Alles live"
        }
        var detail = ""
        if let last = list.first {
            detail = "Laatste: \(last.project)"
            if let created = last.created { detail += " · \(CloudHelp.ago(created))" }
        }

        let items = list.prefix(8).map { d -> ConnectorItem in
            var parts = [stateLabel(d.state)]
            if d.production { parts.append("productie") }
            if let branch = d.branch { parts.append(branch) }
            if let created = d.created { parts.append(CloudHelp.ago(created)) }
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
        if list.isEmpty { return "Geen Vercel-deploys gevonden." }
        return list.map { d -> String in
            var line = "- \(d.project): \(stateLabel(d.state))"
            if d.production { line += " [productie]" }
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
    static let fields = [
        ConnectorField(account: StripeConnector.keyAccount, label: "Sleutel", placeholder: "rk_live_…", secret: true)
    ]
    static let helpText = "Gebruik bij voorkeur een beperkte sleutel (restricted key) met alleen leesrechten op Charges. Nook leest alleen; er gaat nooit geld weg."
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
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        let succeeded = s.today.filter { $0.status == "succeeded" }
        var lines = ["Stripe\(s.testMode ? " (testmodus)" : ""): \(revenueText(s)) omzet vandaag uit \(CloudHelp.plural(succeeded.count, "betaling", "betalingen"))\(s.moreToday ? " (100+)" : "")."]
        let failed = s.today.filter { $0.status == "failed" }
        if !failed.isEmpty {
            lines.append("Stripe: \(CloudHelp.plural(failed.count, "mislukte betaling", "mislukte betalingen")) vandaag.")
        }
        for p in s.recent.prefix(4) {
            lines.append("Betaling: \(CloudHelp.money(p.amount, currency: p.currency)) van \(CloudHelp.short(p.who, 40)), \(statusLabel(p.status)), \(CloudHelp.ago(p.created))")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "stripe_payments",
                description: "Haalt vers de omzet van vandaag en de recentste betalingen in Stripe op: bedrag, klant, status en tijd. Alleen lezen.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Stripe lezen" },
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
            who: name ?? description ?? email ?? "Betaling",
            failure: c["failure_message"] as? String
        )
    }

    /// Netto omzet van vandaag per valuta, de grootste eerst.
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
        case "succeeded": return "gelukt"
        case "pending": return "in behandeling"
        case "failed": return "mislukt"
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
        var detail = CloudHelp.plural(succeeded.count, "betaling", "betalingen") + (s.moreToday ? "+" : "") + " vandaag"
        if !failed.isEmpty { detail += " · \(failed.count) mislukt" }
        if s.testMode { detail += " · testmodus" }

        let items = s.recent.map { p -> ConnectorItem in
            var subtitle = "\(statusLabel(p.status)) · \(CloudHelp.ago(p.created))"
            if p.refunded > 0 { subtitle += " · \(CloudHelp.money(p.refunded, currency: p.currency)) terugbetaald" }
            return ConnectorItem(id: p.id, title: "\(CloudHelp.money(p.amount, currency: p.currency)) · \(CloudHelp.short(p.who, 40))",
                                 subtitle: subtitle, tone: tone(p), url: dashboardURL(p, testMode: s.testMode))
        }
        status = ConnectorStatus(state: .ok, headline: "\(revenueText(s)) vandaag", detail: detail, items: items,
                                 updated: Date(), needsAttention: !failed.isEmpty)
    }

    private func overview() async throws -> String {
        guard ConnectorToggle.isOn(id), let key = CloudHelp.secret(StripeConnector.keyAccount) else {
            throw CloudHelp.notSetUp("Stripe")
        }
        let s = try await fetch(key: key, recentCount: 15)
        apply(s)
        var out = ["Omzet vandaag (netto): \(revenueText(s)) · \(status.detail)", "", "Recente betalingen:"]
        if s.recent.isEmpty { out.append("- geen") }
        for p in s.recent {
            var line = "- \(CloudHelp.money(p.amount, currency: p.currency)) · \(p.who) · \(statusLabel(p.status)) · \(NookDates.short(p.created))"
            if p.refunded > 0 { line += " · \(CloudHelp.money(p.refunded, currency: p.currency)) terugbetaald" }
            if let failure = p.failure, !failure.isEmpty { line += " · reden: \(failure)" }
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
    static let fields = [
        ConnectorField(account: NotionConnector.tokenAccount, label: "Token", placeholder: "ntn_… of secret_…", secret: true)
    ]
    static let helpText = "Maak een interne integratie met alleen 'Read content'. Deel daarna de pagina's die Nook mag zien met die integratie (••• › Verbindingen)."
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
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded, !pages.isEmpty else { return [] }
        let parts = pages.prefix(5).map { p -> String in
            var part = "'\(CloudHelp.short(p.title, 50))'"
            if let edited = p.edited { part += " (\(CloudHelp.ago(edited)))" }
            return part
        }
        return ["Notion, recent bewerkt: " + parts.joined(separator: ", ")]
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "notion_search",
                description: "Zoekt in de Notion-pagina's die met Nook gedeeld zijn, de laatst bewerkte eerst. Zonder zoekterm geeft het de recent bewerkte pagina's, met links.",
                schema: CloudHelp.schema([
                    "query": ["type": "string", "description": "Zoekterm in de paginatitel. Optioneel."]
                ]),
                kind: .read,
                summarize: { _ in "Notion lezen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("Notion") }
                    let query = (input["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return try await self.overview(query: query)
                }
            )
        ]
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
        // Databases hebben "title" bovenaan, pagina's een eigenschap van het type "title".
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
            title: title.isEmpty ? "Zonder titel" : title,
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
            detail = "Laatst: \(CloudHelp.short(first.title, 40))"
            if let edited = first.edited { detail += " · \(CloudHelp.ago(edited))" }
        }
        let items = list.map { p in
            ConnectorItem(id: p.id, title: p.title,
                          subtitle: p.edited.map { "bewerkt \(CloudHelp.ago($0))" } ?? "",
                          tone: .neutral, url: p.url)
        }
        status = ConnectorStatus(state: .ok,
                                 headline: list.isEmpty ? "Geen gedeelde pagina's" : CloudHelp.plural(list.count, "pagina", "pagina's") + " recent bewerkt",
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
            return hasQuery ? "Geen Notion-pagina's gevonden voor '\(query ?? "")'." : "Geen Notion-pagina's gedeeld met Nook."
        }
        return list.map { p -> String in
            var line = "- \(p.title)"
            if let edited = p.edited { line += " · bewerkt \(NookDates.short(edited))" }
            if let url = p.url { line += " · \(url.absoluteString)" }
            return line
        }.joined(separator: "\n")
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
    static let fields = [
        ConnectorField(account: CalcomConnector.keyAccount, label: "API-sleutel", placeholder: "cal_live_…", secret: true)
    ]
    static let helpText = "Maak een API-sleutel onder Instellingen › Developer › API keys. Nook leest alleen je komende boekingen."
    static let signupURL = URL(string: "https://app.cal.com/settings/developer/api-keys")

    private struct Booking {
        let id: String
        let title: String
        let start: Date
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
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), loaded else { return [] }
        if bookings.isEmpty { return ["Cal.com: geen komende boekingen."] }
        var lines = ["Cal.com: \(CloudHelp.plural(bookings.count, "komende boeking", "komende boekingen"))."]
        for b in bookings.prefix(4) {
            lines.append("Boeking: \(line(for: b))")
        }
        let pending = bookings.filter { $0.needsConfirmation }
        if !pending.isEmpty {
            lines.append("Cal.com: \(CloudHelp.plural(pending.count, "boeking wacht", "boekingen wachten")) op bevestiging.")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "calcom_bookings",
                description: "Haalt vers de komende Cal.com-boekingen van de gebruiker op: titel, tijd, met wie, status en link.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Cal.com lezen" },
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
            title: (b["title"] as? String) ?? "Afspraak",
            start: start,
            status: ((b["status"] as? String) ?? "accepted").lowercased(),
            attendee: attendee,
            url: uid.flatMap { URL(string: "https://app.cal.com/booking/\($0)") }
        )
    }

    private func line(for b: Booking) -> String {
        var text = "'\(CloudHelp.short(b.title, 50))'"
        if let who = b.attendee { text += " met \(who)" }
        text += ", \(NookDates.short(b.start))"
        if b.needsConfirmation { text += " (wacht op bevestiging)" }
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
            headline = "Volgende: \(NookDates.short(next.start))"
        } else {
            headline = "Geen komende boekingen"
        }
        var detail = "\(today) vandaag · \(list.count) komend"
        if !pending.isEmpty { detail += " · \(pending.count) te bevestigen" }

        let items = list.prefix(8).map { b -> ConnectorItem in
            var subtitle = NookDates.short(b.start)
            if let who = b.attendee { subtitle += " · met \(who)" }
            if b.needsConfirmation { subtitle += " · bevestigen" }
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
        if list.isEmpty { return "Geen komende Cal.com-boekingen." }
        return list.map { b -> String in
            var text = "- \(line(for: b))"
            if let url = b.url { text += " · \(url.absoluteString)" }
            return text
        }.joined(separator: "\n")
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
    static let fields = [
        ConnectorField(account: N8nConnector.urlAccount, label: "Adres", placeholder: "https://n8n.jouwdomein.nl", secret: false),
        ConnectorField(account: N8nConnector.keyAccount, label: "API-sleutel", placeholder: "n8n API-sleutel", secret: true)
    ]
    static let helpText = "Maak een sleutel in n8n onder Settings › n8n API. Nook leest alleen je workflows en mislukte runs; het start of wijzigt niets."
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
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        let recent = s.recentFailures
        var lines = ["n8n: \(s.active) van \(s.workflows) workflows actief, \(CloudHelp.plural(recent.count, "mislukte run", "mislukte runs")) in 24 uur."]
        for f in recent.prefix(4) {
            var line = "n8n-run mislukt: '\(CloudHelp.short(f.workflow, 50))'"
            if let when = f.when { line += " (\(CloudHelp.ago(when)))" }
            lines.append(line)
        }
        return lines
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "n8n_status",
                description: "Haalt vers de n8n-workflows van de gebruiker op (hoeveel actief) en de recent mislukte runs met workflow, tijd en link. Alleen lezen.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "n8n lezen" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] _ in
                    guard let self = self else { throw CloudHelp.notSetUp("n8n") }
                    return try await self.overview()
                }
            )
        ]
    }

    /// "https://n8n.example.com/" of ".../api/v1" wordt "https://n8n.example.com".
    private func normalizedBase(_ raw: String) throws -> String {
        var base = raw
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/api/v1") { base = String(base.dropLast("/api/v1".count)) }
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else {
            throw NookError("Het n8n-adres moet beginnen met https://")
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
            ? "Geen fouten in 24 uur"
            : CloudHelp.plural(recent.count, "mislukte run", "mislukte runs") + " in 24 uur"
        let items = s.failures.prefix(8).map { f -> ConnectorItem in
            let isRecent = (f.when ?? .distantPast) > Date().addingTimeInterval(-24 * 3600)
            return ConnectorItem(id: f.id, title: f.workflow,
                                 subtitle: "Mislukt" + (f.when.map { " · \(CloudHelp.ago($0))" } ?? ""),
                                 tone: isRecent ? .bad : .neutral, url: f.url)
        }
        status = ConnectorStatus(state: .ok,
                                 headline: CloudHelp.plural(s.active, "actieve workflow", "actieve workflows"),
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
        var out = ["Workflows: \(s.workflows), waarvan \(s.active) actief.", "", "Recent mislukte runs:"]
        if s.failures.isEmpty { out.append("- geen") }
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
    static let fields = [
        ConnectorField(account: ResendConnector.keyAccount, label: "API-sleutel", placeholder: "re_…", secret: true)
    ]
    static let helpText = "Maak een sleutel met 'Full access': alleen daarmee kan Nook je verzonden mails en domeinen lezen. Nook verstuurt zelf nooit mail."
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
            status.state = .error(CloudHelp.errorText(error, service: title))
        }
    }

    func contextLines() -> [String] {
        guard status.state == .ok, ConnectorToggle.isOn(id), let s = snapshot else { return [] }
        var lines = ["Resend: \(CloudHelp.plural(s.domains.count, "domein", "domeinen")), \(CloudHelp.plural(s.emails.count, "recente mail", "recente mails"))."]
        for d in s.unverified.prefix(3) {
            lines.append("Resend-domein niet geverifieerd: \(d.name) (\(d.status))")
        }
        for e in s.troubled.prefix(3) {
            lines.append("Mail \(eventLabel(e.event)): '\(CloudHelp.short(e.subject, 50))' aan \(e.to)")
        }
        if let last = s.emails.first {
            lines.append("Laatste mail: '\(CloudHelp.short(last.subject, 50))' aan \(last.to), \(eventLabel(last.event))")
        }
        return Array(lines.prefix(8))
    }

    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "resend_overview",
                description: "Leest vers de recent via Resend verzonden mails (aan wie, onderwerp, afgeleverd/gebounced) en de status van de domeinen. Verstuurt nooit iets.",
                schema: CloudHelp.schema(),
                kind: .read,
                summarize: { _ in "Resend lezen" },
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
            return Domain(id: did, name: name, status: (d["status"] as? String) ?? "onbekend")
        }
        // De mail-lijst is een extra: zonder die rechten tonen we alleen de domeinen.
        let emailsObject = await CloudHelp.optionalObject(URL(string: "https://api.resend.com/emails?limit=\(count)"), headers: auth)
        let emails = CloudHelp.list(emailsObject?["data"]).compactMap { e -> Email? in
            guard let eid = CloudHelp.string(e["id"]) else { return nil }
            let to: String
            if let list = e["to"] as? [String] {
                to = list.joined(separator: ", ")
            } else {
                to = (e["to"] as? String) ?? "?"
            }
            return Email(id: eid, to: to, subject: (e["subject"] as? String) ?? "(geen onderwerp)",
                         event: (e["last_event"] as? String) ?? "", created: parseDate(e["created_at"]))
        }
        return Snapshot(domains: domains, emails: emails)
    }

    /// Resend geeft soms "2023-04-03 22:13:42.674981+00" in plaats van ISO 8601.
    private func parseDate(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let date = NookDates.parse(text) { return date }
        let head = String(text.prefix(19))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: head)
    }

    private func eventLabel(_ event: String) -> String {
        switch event {
        case "delivered": return "afgeleverd"
        case "sent": return "verstuurd"
        case "opened": return "geopend"
        case "clicked": return "aangeklikt"
        case "bounced": return "gebounced"
        case "complained": return "als spam gemeld"
        case "delivery_delayed": return "vertraagd"
        case "": return "onbekend"
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
            headline = "Domein niet klaar: \(first.name)"
        } else if s.emails.isEmpty {
            headline = CloudHelp.plural(s.domains.count, "domein", "domeinen") + " in orde"
        } else {
            headline = CloudHelp.plural(s.emails.count, "recente mail", "recente mails")
        }
        let detail = troubled.isEmpty
            ? "Geen bounces"
            : CloudHelp.plural(troubled.count, "probleem", "problemen") + " met bezorging"

        var items: [ConnectorItem] = unverified.prefix(3).map { d in
            ConnectorItem(id: "domain-\(d.id)", title: d.name, subtitle: "Domein · \(d.status)",
                          tone: d.status == "failed" ? .bad : .attention,
                          url: URL(string: "https://resend.com/domains/\(d.id)"))
        }
        for e in s.emails.prefix(max(0, 8 - items.count)) {
            var subtitle = "\(eventLabel(e.event)) · aan \(e.to)"
            if let created = e.created { subtitle += " · \(CloudHelp.ago(created))" }
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
        var out = ["Domeinen:"]
        if s.domains.isEmpty { out.append("- geen") }
        for d in s.domains { out.append("- \(d.name): \(d.status)") }
        out.append("")
        out.append("Recente mails:")
        if s.emails.isEmpty { out.append("- geen (of de sleutel mag de mail-lijst niet lezen)") }
        for e in s.emails {
            var line = "- '\(e.subject)' aan \(e.to) · \(eventLabel(e.event))"
            if let created = e.created { line += " · \(NookDates.short(created))" }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
