import SwiftUI
import AppKit

/// Settings › Accounts & connections › WhatsApp, live: link the phone through a local gateway so Nook can show new
/// messages in the notch, answer them and send messages after your OK. The same three parts as the WhatsApp sheet in
/// Settings › Connections: the accounts, what reaches you, and the gateway (folded away).
struct WhatsAppLinkSection: View {
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @State private var enabled = WhatsAppSettings.enabled

    var body: some View {
        Section {
            SettingToggle(tr("whatsapp.settings.enable"), detail: tr("whatsapp.settings.enableDetail"), isOn: $enabled)
                .onChange(of: enabled) { _, on in accounts.setEnabled(on) }
            if enabled {
                WhatsAppInstallRow()
                WhatsAppAccountList()
                DisclosureGroup {
                    WhatsAppGatewayRows()
                } label: {
                    SettingLabel(tr("whatsapp.manage.gateway"), hint: tr("whatsapp.manage.gatewayDetail"))
                }
            }
        } header: {
            SettingsSectionTitle(tr("whatsapp.settings.title"), info: tr("whatsapp.settings.footer"))
        }

        // Once linked, what reaches you gets a section of its own.
        if enabled, accounts.isConnected {
            Section { WhatsAppNoticeRows() }
        }
    }
}

/// Installing GOWA, while the gateway is GOWA and it is not on this Mac yet (or is being installed).
struct WhatsAppInstallRow: View {
    @ObservedObject private var installer = WhatsAppGOWAInstaller.shared

    var body: some View {
        if WhatsAppSettings.gateway == .gowa, !WhatsAppGOWAInstaller.isInstalled || installer.busy {
            HStack(spacing: NookTheme.Spacing.md) {
                SettingLabel(tr("whatsapp.install.title"), detail: line)
                Spacer()
                if installer.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(tr("whatsapp.install.button")) { installer.install() }
                }
            }
        }
    }

    private var line: String {
        switch installer.step {
        case .idle: return tr("whatsapp.install.detail")
        case .checking: return tr("whatsapp.install.checking")
        case .downloading(let megabytes): return tr("whatsapp.install.downloading", megabytes)
        case .verifying: return tr("whatsapp.install.verifying")
        case .installing: return tr("whatsapp.install.installing")
        case .done(let version): return tr("whatsapp.install.done", version)
        case .failed(let why): return why
        }
    }
}

/// What reaches you from WhatsApp, in every account: the main switch, the rule per kind of chat, then every chat on its
/// own (louder or quieter than its kind), and whether answering reads the chat.
struct WhatsAppNoticeRows: View {
    @ObservedObject private var link = WhatsAppLink.shared
    /// Whether WhatsApp may notify is one of the switches in Settings › Notifications, the same one shown here.
    @ObservedObject private var settings = AppSettings.shared
    @State private var markRead = WhatsAppSettings.markReadOnReply

    private var notify: Binding<Bool> {
        Binding(get: { settings.noticeRules.isOn(.chats, app: "whatsapp") },
                set: { settings.noticeRules.set(.chats, app: "whatsapp", on: $0) })
    }

    var body: some View {
        SettingToggle(tr("whatsapp.settings.notify"), detail: tr("whatsapp.settings.notifyDetail"), isOn: notify)
        if notify.wrappedValue {
            SettingToggle(tr("whatsapp.settings.muteGroups"), detail: tr("whatsapp.settings.muteGroupsDetail"),
                          isOn: Binding(get: { link.filters.muteGroups }, set: { link.filters.muteGroups = $0 }))
            SettingToggle(tr("whatsapp.settings.muteStatus"), detail: tr("whatsapp.settings.muteStatusDetail"),
                          isOn: Binding(get: { link.filters.muteStatus }, set: { link.filters.muteStatus = $0 }))
            SettingToggle(tr("whatsapp.settings.muteChannels"), detail: tr("whatsapp.settings.muteChannelsDetail"),
                          isOn: Binding(get: { link.filters.muteChannels }, set: { link.filters.muteChannels = $0 }))
            WhatsAppChatModeList()
        }
        SettingToggle(tr("whatsapp.settings.markRead"), detail: tr("whatsapp.settings.markReadDetail"), isOn: $markRead)
            .onChange(of: markRead) { _, value in WhatsAppSettings.markReadOnReply = value }
    }
}

/// How Nook reaches WhatsApp, only needed when something does not work: the gateway, its address and password, starting
/// GOWA by itself and updating it, and the webhook when it needs attention. Each field has its label beside it, so the
/// rows read the same in a Settings form and in a sheet.
struct WhatsAppGatewayRows: View {
    @ObservedObject private var link = WhatsAppLink.shared
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @ObservedObject private var installer = WhatsAppGOWAInstaller.shared
    @State private var gateway = WhatsAppSettings.gateway
    @State private var address = WhatsAppSettings.url
    @State private var credential = WhatsAppSettings.credential ?? ""
    @State private var autoStart = WhatsAppGOWAProcess.autoStart

    var body: some View {
        Picker(tr("whatsapp.settings.gateway"), selection: $gateway) {
            ForEach(WAGatewayKind.allCases, id: \.self) { kind in Text(kind.name).tag(kind) }
        }
        .onChange(of: gateway) { _, kind in
            WhatsAppSettings.gateway = kind
            address = WhatsAppSettings.url
            accounts.settingsChanged()
        }
        LabeledContent(tr("whatsapp.settings.address")) {
            TextField("", text: $address, prompt: Text(gateway.defaultURL))
                .labelsHidden()
                .onSubmit { WhatsAppSettings.url = address; accounts.settingsChanged() }
        }
        LabeledContent(credentialLabel) {
            SecureField("", text: $credential)
                .labelsHidden()
                .onSubmit { WhatsAppSettings.setCredential(credential); accounts.settingsChanged() }
        }
        if gateway == .gowa, WhatsAppGOWAInstaller.isInstalled {
            Toggle(tr("whatsapp.settings.autoStart"), isOn: $autoStart)
                .onChange(of: autoStart) { _, on in WhatsAppGOWAProcess.autoStart = on; accounts.settingsChanged() }
            // Nook installs GOWA once; a newer one (polls need 9.3) comes from here.
            if !installer.busy {
                HStack(spacing: NookTheme.Spacing.md) {
                    SettingLabel(tr("whatsapp.update.title"), hint: tr("whatsapp.update.detail"))
                    Spacer()
                    Button(tr("whatsapp.update.button")) { installer.install() }
                }
            }
        }
        if let line = webhookLine {
            SettingNote(line, tone: .warning)
        }
    }

    private var credentialLabel: String {
        switch gateway {
        case .gowa: return tr("whatsapp.settings.basicAuth")
        case .openwa: return tr("whatsapp.settings.apiKey")
        }
    }

    /// The first account's webhook, when it needs attention; every other account says its own in its row.
    private var webhookLine: String? {
        switch link.webhook {
        case .off, .listening, .registered: return nil
        case .portBusy: return tr("whatsapp.webhook.portBusy", WhatsAppSettings.port)
        case .refused(let why): return tr("whatsapp.webhook.refused", why)
        }
    }
}

/// Every chat with its own choice: automatic (the rule of its kind), always, or never. Hidden chats can come back
/// one by one. The chats of every linked account, and the choices hold in each.
struct WhatsAppChatModeList: View {
    @ObservedObject private var link = WhatsAppLink.shared
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @State private var query = ""
    @State private var open = false

    private var chats: [(jid: String, name: String)] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return accounts.chatsForSettings.filter { !link.filters.ignored.contains($0.jid) }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var hidden: [(jid: String, name: String)] {
        let names = Dictionary(accounts.chatsForSettings.map { ($0.jid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return link.filters.ignored.sorted().map { ($0, names[$0] ?? WAJID.displayNumber($0)) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if accounts.chatsForSettings.isEmpty {
                SettingNote(tr("whatsapp.settings.noChats"))
            } else {
                NookSearchField(prompt: tr("whatsapp.settings.chatSearch"), text: $query, style: .inline)
                ForEach(chats, id: \.jid) { chat in
                    row(chat.jid, name: chat.name)
                }
            }
            if !hidden.isEmpty {
                Text(tr("whatsapp.settings.hidden"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.top, NookTheme.Spacing.sm)
                ForEach(hidden, id: \.jid) { chat in
                    HStack(spacing: 10) {
                        avatar(chat.name)
                        Text(chat.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Button(tr("whatsapp.settings.showAgain")) { link.filters.ignored.remove(chat.jid) }
                            .controlSize(.small)
                    }
                }
            }
        } label: {
            SettingLabel(tr("whatsapp.settings.perChat"), hint: tr("whatsapp.settings.perChatDetail"))
        }
    }

    private func row(_ jid: String, name: String) -> some View {
        let kind = WAJID.kind(jid)
        return HStack(spacing: 10) {
            avatar(name)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(tr("whatsapp.kind.\(kind.rawValue)")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            }
            Spacer(minLength: 8)
            Picker("", selection: Binding(get: { link.filters.mode(for: jid) }, set: { link.filters.setMode($0, for: jid) })) {
                Text(tr("whatsapp.mode.automatic")).tag(WAChatMode.automatic)
                Text(tr("whatsapp.mode.loud")).tag(WAChatMode.loud)
                Text(tr("whatsapp.mode.muted")).tag(WAChatMode.muted)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .fixedSize()
            .help(tr("whatsapp.mode.help", kindRule(kind)))
        }
        .padding(.vertical, 1)
    }

    /// What automatic means for this kind right now, for the picker's tooltip.
    private func kindRule(_ kind: WAJID.Kind) -> String {
        link.filters.kindIsQuiet(kind == .person ? "x@s.whatsapp.net" : kind == .group ? "x@g.us" : kind == .status ? "status@broadcast" : "x@newsletter")
            ? tr("whatsapp.mode.muted") : tr("whatsapp.mode.loud")
    }

    private func avatar(_ name: String) -> some View {
        Circle()
            .fill(NookTheme.smoke)
            .overlay(Text(WAJID.initials(name)).font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textSecondary))
            .frame(width: 22, height: 22)
    }
}

extension WhatsAppLink {
    /// The link as a service row shows it.
    var serviceStatus: ServiceStatus {
        switch link {
        case .connected: return .connected
        case .connecting: return .connecting
        case .needsQR: return .notLinked
        case .off: return .off
        case .unreachable, .unauthorized, .failed: return .unreachable
        }
    }
}

/// Every WhatsApp account, the first one included, as the rows of every other connected service: its name, its number or
/// where its link stands, and what can be done (Rename, Retry, Remove). An account waiting to be linked shows its QR under
/// its row. Below them, adding another account (a business number, a second phone), which gets a QR of its own.
struct WhatsAppAccountList: View {
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @State private var adding = false
    @State private var newName = ""
    @State private var removing: WAAccount?

    var body: some View {
        ForEach(accounts.links, id: \.account) { link in
            WhatsAppAccountRow(link: link, remove: {
                removing = accounts.accounts.first { $0.id == link.account }
            })
        }
        // Another account once the first is linked: before that, its QR comes first.
        if WhatsAppLink.shared.isConnected || accounts.links.count > 1 {
            Group {
                if adding {
                    HStack(spacing: NookTheme.Spacing.md) {
                        TextField("", text: $newName, prompt: Text(tr("whatsapp.accounts.namePrompt")))
                            .labelsHidden()
                            .onSubmit(add)
                        Button(tr("whatsapp.accounts.link"), action: add)
                            .buttonStyle(.borderedProminent)
                        Button(tr("button.cancel")) { adding = false; newName = "" }
                    }
                } else {
                    HStack(spacing: NookTheme.Spacing.md) {
                        SettingLabel(tr("whatsapp.accounts.add"), detail: tr("whatsapp.accounts.addDetail"))
                        Spacer()
                        Button(tr("whatsapp.accounts.addButton")) { adding = true }
                    }
                }
            }
            .confirmDelete($removing, question: { tr("whatsapp.accounts.removeTitle", $0.name.isEmpty ? "WhatsApp" : $0.name) },
                           detail: tr("whatsapp.accounts.removeDetail"), confirmTitle: tr("whatsapp.accounts.remove")) { account in
                accounts.remove(account.id)
            }
        }
    }

    private func add() {
        accounts.add(name: newName)
        newName = ""
        adding = false
    }
}

/// One WhatsApp account as a service row; Rename turns its name into a field until you press Return.
private struct WhatsAppAccountRow: View {
    @ObservedObject var link: WhatsAppLink
    let remove: () -> Void
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @State private var renaming = false
    @State private var name = ""

    private var isFirst: Bool { link.account.isEmpty }

    /// Linked: its number (its name is the title); else where its link stands.
    private var detail: String {
        if link.isConnected, let me = link.me { return WAJID.displayNumber(me) }
        return link.statusLine
    }

    var body: some View {
        ChatAccountRow(app: "whatsapp", title: accounts.name(of: link), detail: detail, status: link.serviceStatus,
                       detailIsError: link.link == .unauthorized) {
            if link.link == .unreachable || link.link == .unauthorized {
                Button(tr("whatsapp.settings.retry")) { isFirst ? accounts.settingsChanged() : link.settingsChanged() }
                    .controlSize(.small)
            }
            // A name says which account a chat is in once there are two; with one it needs none.
            if accounts.links.count > 1 {
                Button(tr("whatsapp.accounts.rename")) { name = currentName; renaming = true }
                    .controlSize(.small)
            }
            if !isFirst {
                Button(tr("whatsapp.accounts.remove"), role: .destructive, action: remove)
                    .controlSize(.small)
            }
        }
        if renaming {
            HStack(spacing: NookTheme.Spacing.md) {
                TextField("", text: $name, prompt: Text(tr(isFirst ? "whatsapp.accounts.mainPrompt" : "whatsapp.accounts.namePrompt")))
                    .labelsHidden()
                    .onSubmit(save)
                Button(tr("button.save"), action: save)
                Button(tr("button.cancel")) { renaming = false }
            }
        }
        if link.link == .needsQR, let data = link.qrPNG, let image = NSImage(data: data) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.xl) {
                QRCodeView(image: image, side: 160, label: tr("chats.link.qr"))
                Text(tr(isFirst ? "whatsapp.settings.scan" : "whatsapp.accounts.scan"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, NookTheme.Spacing.xs)
        }
        if !isFirst, link.webhook == .portBusy, let port = link.webhookPort {
            SettingNote(tr("whatsapp.webhook.portBusy", port), tone: .warning)
        }
    }

    private var currentName: String {
        isFirst ? WhatsAppSettings.mainName : accounts.accounts.first { $0.id == link.account }?.name ?? ""
    }

    private func save() {
        accounts.rename(link.account, to: name)
        renaming = false
    }
}
