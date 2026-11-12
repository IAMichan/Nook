import SwiftUI
import os

@MainActor
final class StripeConnector: TokenCloudConnector {
    let id = "stripe"
    let title = "Stripe"
    let symbol = "creditcard"
    let accent = Color(hex: 0x8F86FF)
    let refreshInterval: TimeInterval = 240
    @Published var status = ConnectorStatus()

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

    static var secretAccounts: [String] { [StripeConnector.keyAccount] }

    func fetchSnapshot(secrets: [String]) async throws {
        apply(try await fetch(key: secrets[0], recentCount: 5))
    }

    func clearSnapshot() {
        snapshot = nil
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
