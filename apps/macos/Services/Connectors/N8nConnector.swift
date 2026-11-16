import SwiftUI
import os

@MainActor
final class N8nConnector: TokenCloudConnector {
    let id = "n8n"
    let title = "n8n"
    let symbol = "point.3.connected.trianglepath.dotted"
    let accent = Color(hex: 0xFF7A59)
    let refreshInterval: TimeInterval = 180
    @Published var status = ConnectorStatus()

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

    static var secretAccounts: [String] { [N8nConnector.urlAccount, N8nConnector.keyAccount] }

    func fetchSnapshot(secrets: [String]) async throws {
        apply(try await fetch(rawBase: secrets[0], key: secrets[1], failureCount: 10))
    }

    func clearSnapshot() {
        snapshot = nil
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
