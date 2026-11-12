import SwiftUI
import os

@MainActor
final class VercelConnector: TokenCloudConnector {
    let id = "vercel"
    let title = "Vercel"
    let symbol = "triangle.fill"
    let accent = Color(hex: 0xE8E8EE)
    let refreshInterval: TimeInterval = 150
    @Published var status = ConnectorStatus()

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

    static var secretAccounts: [String] { [VercelConnector.tokenAccount] }

    func fetchSnapshot(secrets: [String]) async throws {
        apply(try await fetch(token: secrets[0], limit: 12))
    }

    func clearSnapshot() {
        deployments = []
        loaded = false
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
