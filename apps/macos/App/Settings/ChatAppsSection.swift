import SwiftUI

/// The chat apps Settings › Chats offers, in the order they show while none is linked: the apps most chats come from
/// first. Nook links those in `ownWay` itself; the others show only while a chat service on this Mac can link them (or
/// one is linked), as does any other app such a service offers.
enum ChatAppsCatalog {
    static let apps = ["whatsapp", "instagram", "messenger", "telegram", "signal", "teams", "slack", "discord", "linkedin", "x",
                       "messages"]

    /// Nook reads these itself as well, each in its own way (a phone link, a login, a token, this Mac's database).
    /// Telegram links through Nook's own chat helper when this build has it, and through TDLib only without it.
    @MainActor static var ownWay: Set<String> {
        let apps: Set<String> = ["whatsapp", "teams", "slack", "messages"]
        return ChatHelper.isBuilt ? apps : apps.union(["telegram"])
    }
}

/// One app on Settings › Chats: whether it is linked, how and as whom, and whether its chats are on.
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

/// The top of Settings › Chats: every chat app at a glance. The linked ones as rows (state, account, a switch and
/// Manage), the others as cards with Link; both open `ChatAppSheet`, which walks a link through its steps.
struct ChatAppsSection: View {
    @ObservedObject private var capture = ChatCaptureService.shared
    @ObservedObject private var linker = ChatLinker.shared
    @ObservedObject private var linked = ChatCaptureService.shared.beeperBridge
    @ObservedObject private var whatsApp = WhatsAppLink.shared
    @ObservedObject private var telegram = ChatCaptureService.shared.telegramBridge
    @ObservedObject private var teams = ChatCaptureService.shared.teamsBridge
    @State private var open: ChatAppSheetItem?
    let setCollecting: (Bool) -> Void

    private var states: [ChatAppState] { ChatAppStates.all() }

    var body: some View {
        let all = states
        let done = all.filter(\.linked)
        let todo = all.filter { !$0.linked }
        Section {
            IntroCard(title: tr("chats.apps.summary", done.count, all.count), text: tr("chats.apps.intro"))
            if !done.isEmpty {
                NookSectionLabel(tr("chats.apps.linked"))
                ForEach(done) { row($0) }
            }
            if !todo.isEmpty {
                NookSectionLabel(tr("chats.apps.notLinked"))
                GalleryGrid {
                    ForEach(todo) { card($0) }
                }
            }
            if let problem = linker.problem, BeeperBridge.token != nil {
                SettingNote(problem, tone: .warning)
            }
        } header: {
            Text(tr("chats.apps.title"))
        } footer: {
            Text(tr("chats.apps.footer"))
        }
        .sheet(item: $open) { item in
            ChatAppSheet(app: item.id, setCollecting: setCollecting)
        }
        .task { await linker.refresh() }
        // A token saved or removed lists what can be linked again.
        .onChange(of: linked.isWorking) { _, _ in Task { await linker.refresh() } }
    }

    private func row(_ state: ChatAppState) -> some View {
        ServiceRowLayout(domain: state.site, symbol: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, title: state.name,
                         detail: state.detail, status: state.status, detailIsError: state.detailIsError, source: state.id) {
            Toggle("", isOn: Binding(get: { state.isOn }, set: { on in
                capture.setSource(state.id, on: on)
                if on, !capture.enabled { setCollecting(true) }
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(tr("chats.apps.showInChats", state.name))
            Button(tr("chats.apps.manage")) { open = ChatAppSheetItem(id: state.id) }
                .controlSize(.small)
        }
    }

    private func card(_ state: ChatAppState) -> some View {
        GalleryCard(title: state.name, detail: state.detail) {
            ServiceTile(domain: state.site, fallback: "bubble.left.and.bubble.right.fill", tint: NookTheme.iris, size: 30,
                        source: state.id)
        } accessory: {
            ConnectMethodBadge(method: .signIn, text: tr("chats.apps.link"))
        } action: {
            open = ChatAppSheetItem(id: state.id)
        }
    }
}

/// Where every chat app stands, from the shared bridges and the chat service's list: the overview's rows and cards.
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
                || (linker.serviceRuns && BeeperBridge.token == nil)
        }
    }

    static func state(_ id: String, chats: Int? = nil) -> ChatAppState? {
        let capture = ChatCaptureService.shared
        let linker = ChatLinker.shared
        let linked = capture.beeperBridge
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
        let whatsApp = WhatsAppLink.shared
        switch id {
        case "whatsapp":
            guard WhatsAppSettings.enabled, whatsApp.isConnected else { return nil }
            return tr(WhatsAppSettings.gateway == .beeper ? "chats.apps.own.service" : "chats.apps.own.whatsapp")
        case telegram.app:
            return telegram.isReady ? tr("chats.apps.as", telegram.account ?? "Telegram") : nil
        case teams.app:
            guard let account = teams.accounts.first else { return nil }
            return teams.accounts.count == 1 ? tr("chats.apps.as", account.name.isEmpty ? account.email : account.name)
                : tr("chats.apps.accounts", teams.accounts.count)
        case capture.slackBridge.app:
            return SlackBridge.token != nil ? tr("chats.apps.own.slack") : nil
        case capture.messagesBridge.app:
            guard capture.enabled, capture.messagesBridge.isReady, capture.status != .needsAccess else { return nil }
            return tr("chats.apps.own.messages")
        default:
            return nil
        }
    }
}

struct ChatAppSheetItem: Identifiable {
    var id: String
}
