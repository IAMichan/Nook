import SwiftUI

/// The chat apps Settings › Accounts & connections offers, in the order they show while none is linked: the apps most chats come from
/// first. Nook links those in `ownWay` itself; the others show only while a chat service on this Mac can link them (or
/// one is linked), as does any other app such a service offers.
enum ChatAppsCatalog {
    static let apps = ["whatsapp", "instagram", "messenger", "snapchat", "telegram", "signal", "teams", "slack", "discord", "linkedin",
                       "x", "messages", "mail"]

    /// Nook reads these itself as well, each in its own way (a phone link, a login, a token, this Mac's database, a
    /// website kept open out of sight, the Mail app with every account in it).
    /// Telegram links through Nook's own chat helper when this build has it, and through TDLib only without it. Slack
    /// links through the helper (signing in on slack.com) once the helper running here offers it, and with a token
    /// until then: a helper built before it had Slack would otherwise leave Slack with no way to link.
    @MainActor static var ownWay: Set<String> {
        var apps: Set<String> = ["whatsapp", "teams", "messages", "snapchat", "mail"]
        if !ChatHelper.isBuilt { apps.insert("telegram") }
        if !ChatHelper.offers("slack") { apps.insert("slack") }
        return apps
    }
}

/// One chat app on Settings › Accounts & connections: whether it is linked, how and as whom, and whether its chats are on.
struct ChatAppState: Identifiable, Equatable {
    var id: String
    var name: String
    var site: String?
    var linked: Bool
    var status: ServiceStatus
    /// How it is linked and as whom ("As Anna · live · 12 chats"), or how it links.
    var detail: String
    var detailIsError = false
    /// Its chats show in the Chats tab.
    var isOn: Bool
}

/// Where every chat app stands, from the shared bridges and the chat service's list: the page's rows and the Add sheet.
@MainActor
enum ChatAppStates {
    static func all() -> [ChatAppState] {
        let linker = ChatLinker.shared
        let offered = linker.networks.map(\.app).filter { !ChatAppsCatalog.apps.contains($0) }
        // The chats per app, counted once for every row instead of once per row.
        var chats: [String: Int] = [:]
        for thread in ChatCaptureService.shared.inbox.threads.values { chats[thread.app, default: 0] += 1 }
        return (ChatAppsCatalog.apps + offered).compactMap { state($0, chats: chats[$0] ?? 0) }.filter { app in
            // Nook's own helper links these: they show even in a build without it, whose sheet says how to add it.
            app.linked || ChatAppsCatalog.ownWay.contains(app.id) || ChatHelper.apps.contains(app.id)
                || (linker.serviceRuns && linker.networks.contains { $0.app == app.id })
        }
    }

    static func state(_ id: String, chats: Int? = nil) -> ChatAppState? {
        let capture = ChatCaptureService.shared
        let linker = ChatLinker.shared
        let linked = capture.serviceBridge
        guard let app = MessagingApps.app(id: id) else { return nil }
        let network = linker.networks.first { $0.app == id }
        let accounts = network?.accounts ?? []
        let own = ownLink(id)
        let linkedHere = !accounts.isEmpty || own != nil
        let chats = chats ?? capture.inbox.threads.values.filter { $0.app == id }.count
        let isOn = capture.enabled && capture.sources.isOn(id)
        guard linkedHere else {
            return ChatAppState(id: id, name: app.name, site: app.site, linked: false, status: .notLinked,
                                detail: ChatAppsCatalog.apps.contains(id) ? tr("chats.apps.how.\(id)") : tr("chats.apps.how"),
                                isOn: isOn)
        }
        var parts: [String] = []
        var status = ServiceStatus.connected
        var isError = false
        if let account = accounts.first {
            parts.append(accounts.count == 1 ? tr("chats.apps.as", account.name) : tr("chats.apps.accounts", accounts.count))
            if !account.isConnected {
                status = .expired
                parts = [account.status ?? tr("chats.apps.reconnect")]
            } else if linked.isLive {
                parts.append(tr("chats.linked.live").lowercased())
            }
        } else if let own {
            parts.append(own)
        }
        if let problem = capture.bridgeProblems[id] {
            status = .unreachable
            isError = true
            parts = [problem]
        } else if chats > 0 {
            parts.append(tr("chats.apps.chats", chats))
        }
        if !isOn, status == .connected { status = .off }
        return ChatAppState(id: id, name: app.name, site: app.site, linked: true, status: status,
                            detail: parts.joined(separator: " · "), detailIsError: isError, isOn: isOn)
    }

    /// How Nook links the app itself, when it does: a line for its row; nil while it is not.
    static func ownLink(_ id: String) -> String? {
        let capture = ChatCaptureService.shared
        let telegram = capture.telegramBridge
        let teams = capture.teamsBridge
        let whatsApp = WhatsAppAccounts.shared
        switch id {
        case "whatsapp":
            guard WhatsAppSettings.enabled, whatsApp.isConnected else { return nil }
            let linked = whatsApp.connected.count
            return linked > 1 ? tr("chats.apps.accounts", linked) : tr("chats.apps.own.whatsapp")
        case telegram.app:
            return telegram.isReady ? tr("chats.apps.as", telegram.account ?? "Telegram") : nil
        case teams.app:
            let labels = TeamsWebSession.shared.accounts.map { $0.label.isEmpty ? "Teams" : $0.label }
                + teams.accounts.map { $0.name.isEmpty ? $0.email : $0.name }
            guard let first = labels.first else { return nil }
            return labels.count == 1 ? tr("chats.apps.as", first) : tr("chats.apps.accounts", labels.count)
        case capture.slackBridge.app:
            if let auth = SlackWebSession.shared.auth, SlackBridge.auth != nil {
                return tr("chats.apps.as", auth.team.isEmpty ? "Slack" : auth.team)
            }
            return SlackBridge.token != nil ? tr("chats.apps.own.slack") : nil
        case capture.messagesBridge.app:
            guard capture.enabled, capture.messagesBridge.isReady, capture.status != .needsAccess else { return nil }
            return tr("chats.apps.own.messages")
        case capture.snapchatBridge.app:
            return SnapchatWebSession.shared.isSignedIn ? tr("chats.apps.own.snapchat") : nil
        case capture.mailBridge.app:
            guard capture.mailBridge.isLinked else { return nil }
            let accounts = capture.mailBridge.accounts.count
            return accounts > 1 ? tr("chats.apps.accounts", accounts) : tr("chats.apps.own.mail")
        default:
            return nil
        }
    }
}

struct ChatAppSheetItem: Identifiable {
    var id: String
}
