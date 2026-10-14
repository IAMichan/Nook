import Foundation

/// Identifies the underlying service from an endpoint URL (Slack, Discord, Teams, Telegram, webhooks, etc.),
/// enabling Nook to display appropriate branding and format outgoing payloads.
enum KnownService {
    enum Style {
        case slackWebhook, slackAPI, discord, teams, telegram, genericWebhook
    }

    struct Info: Equatable {
        let name: String
        /// The domain providing the service icon (favicon).
        let domain: String
        /// How messages are delivered to this service; nil = read-only.
        let send: Style?
        /// A webhook is an ingest endpoint: it cannot be queried for data.
        let readable: Bool
    }

    static func detect(_ url: URL, explicit: String? = nil) -> Info? {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        let domain = iconDomain(for: url)

        if host == "hooks.slack.com" {
            return Info(name: "Slack", domain: "slack.com", send: .slackWebhook, readable: false)
        }
        if host == "slack.com" || host.hasSuffix(".slack.com"), path.hasPrefix("/api") {
            return Info(name: "Slack", domain: "slack.com", send: .slackAPI, readable: true)
        }
        if (host == "discord.com" || host == "discordapp.com" || host.hasSuffix(".discord.com")), path.contains("/webhooks/") {
            return Info(name: "Discord", domain: "discord.com", send: .discord, readable: false)
        }
        if host.hasSuffix("webhook.office.com") || (host == "outlook.office.com" && path.contains("/webhook")) {
            return Info(name: "Microsoft Teams", domain: "microsoft.com", send: .teams, readable: false)
        }
        if host == "api.telegram.org" {
            return Info(name: "Telegram", domain: "telegram.org", send: .telegram, readable: true)
        }
        if host == "hooks.zapier.com" {
            return Info(name: "Zapier", domain: "zapier.com", send: .genericWebhook, readable: false)
        }
        if host.hasPrefix("hook.") && (host.hasSuffix(".make.com") || host.hasSuffix(".integromat.com")) {
            return Info(name: "Make", domain: "make.com", send: .genericWebhook, readable: false)
        }
        if path.contains("/webhook/") || path.contains("/webhook-test/") || host.hasPrefix("hooks.") || explicit == "webhook" || explicit == "post" {
            return Info(name: "Webhook", domain: domain, send: .genericWebhook, readable: false)
        }
        return Info(name: domain, domain: domain, send: nil, readable: true)
    }

    /// Root domain for branding icons: api.todoist.com → todoist.com, app.example.co.uk → example.co.uk.
    static func iconDomain(for url: URL) -> String {
        let labels = (url.host ?? "").lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        let take = (labels[labels.count - 2].count <= 3 && secondLevel.contains(labels[labels.count - 2]) && labels.last!.count == 2) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Formats payload for delivery. `to` specifies channel, recipient, or user handle depending on service.
    static func payload(_ style: Style, message: String, to: String) throws -> [String: Any] {
        switch style {
        case .slackWebhook:
            // A Slack incoming webhook is bound to a single channel; prepend recipient if given.
            return ["text": to.isEmpty ? message : "\(to) \(message)"]
        case .slackAPI:
            guard !to.isEmpty else { throw NookError("Which Slack channel or recipient should receive the message? For example, #general.") }
            return ["channel": to, "text": message]
        case .discord:
            return ["content": to.isEmpty ? message : "\(to) \(message)"]
        case .teams:
            return ["text": to.isEmpty ? message : "\(to) \(message)"]
        case .telegram:
            var body: [String: Any] = ["text": message]
            if !to.isEmpty { body["chat_id"] = to }
            return body
        case .genericWebhook:
            var body: [String: Any] = ["text": message, "message": message]
            if !to.isEmpty { body["to"] = to }
            return body
        }
    }
}
