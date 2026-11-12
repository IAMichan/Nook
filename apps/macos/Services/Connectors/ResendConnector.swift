import SwiftUI
import os

@MainActor
final class ResendConnector: TokenCloudConnector {
    let id = "resend"
    let title = "Resend"
    let symbol = "paperplane"
    let accent = Color(hex: 0xF5C24C)
    let refreshInterval: TimeInterval = 300
    @Published var status = ConnectorStatus()

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

    static var secretAccounts: [String] { [ResendConnector.keyAccount] }

    func fetchSnapshot(secrets: [String]) async throws {
        apply(try await fetch(key: secrets[0], count: 20))
    }

    func clearSnapshot() {
        snapshot = nil
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
