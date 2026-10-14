import Foundation

/// Herkent aan een adres welke dienst erachter zit (Slack, Discord, Teams, Telegram, een webhook…), zodat Nook
/// het juiste icoon laat zien en weet hoe een bericht erheen moet.
enum KnownService {
    enum Style {
        case slackWebhook, slackAPI, discord, teams, telegram, genericWebhook
    }

    struct Info: Equatable {
        let name: String
        /// Het domein waar het icoon (favicon) vandaan komt.
        let domain: String
        /// Hoe een bericht naar deze dienst gaat; nil = alleen lezen.
        let send: Style?
        /// Een webhook is alleen om naartoe te sturen: er valt niets uit te lezen.
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

    /// Het hoofddomein voor het icoon: api.todoist.com → todoist.com, app.example.co.uk → example.co.uk.
    static func iconDomain(for url: URL) -> String {
        let labels = (url.host ?? "").lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let secondLevel: Set<String> = ["co", "com", "org", "net", "gov", "ac"]
        let take = (labels[labels.count - 2].count <= 3 && secondLevel.contains(labels[labels.count - 2]) && labels.last!.count == 2) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }

    /// Wat er naar de dienst gaat. `to` is een kanaal, persoon of ontvanger; of die nodig is hangt van de dienst af.
    static func payload(_ style: Style, message: String, to: String) throws -> [String: Any] {
        switch style {
        case .slackWebhook:
            // Een Slack-webhook hoort bij één kanaal; een ontvanger komt dan vooraan in het bericht.
            return ["text": to.isEmpty ? message : "\(to) \(message)"]
        case .slackAPI:
            guard !to.isEmpty else { throw NookError("Naar welk Slack-kanaal of welke persoon moet het bericht? Geef bijvoorbeeld #algemeen.") }
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
