import SwiftUI
import AppKit

/// Settings › Accounts & connections › WhatsApp, live: link the phone through a local gateway so Nook can show new
/// messages in the notch, answer them and send messages after your OK.
struct WhatsAppLinkSection: View {
    @ObservedObject private var link = WhatsAppLink.shared
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @ObservedObject private var installer = WhatsAppGOWAInstaller.shared
    @State private var enabled = WhatsAppSettings.enabled
    @State private var gateway = WhatsAppSettings.gateway
    @State private var address = WhatsAppSettings.url
    @State private var credential = WhatsAppSettings.credential ?? ""
    @State private var autoStart = WhatsAppGOWAProcess.autoStart
    /// Whether WhatsApp may notify is one of the switches in Settings › Notifications, the same one shown here.
    @ObservedObject private var settings = AppSettings.shared
    @State private var markRead = WhatsAppSettings.markReadOnReply

    private var notify: Binding<Bool> {
        Binding(get: { settings.noticeRules.isOn(.chats, app: "whatsapp") },
                set: { settings.noticeRules.set(.chats, app: "whatsapp", on: $0) })
    }

    var body: some View {
        Section {
            SettingToggle(tr("whatsapp.settings.enable"), detail: tr("whatsapp.settings.enableDetail"), isOn: $enabled)
                .onChange(of: enabled) { _, on in accounts.setEnabled(on) }

            if enabled {
                // With more accounts the first one goes by its name too.
                StatusRow(title: accounts.links.count > 1 ? accounts.name(of: link) : "WhatsApp", detail: link.statusLine,
                          state: link.statusState) {
                    if link.link == .unreachable || link.link == .unauthorized {
                        Button(tr("whatsapp.settings.retry")) { accounts.settingsChanged() }
                    }
                }

                if gateway == .gowa, !WhatsAppGOWAInstaller.isInstalled || installer.busy {
                    installRow
                }

                if link.link == .needsQR, let data = link.qrPNG, let image = NSImage(data: data) {
                    HStack(alignment: .top, spacing: NookTheme.Spacing.xl) {
                        QRCodeView(image: image, side: 160, label: tr("chats.link.qr"))
                        Text(tr("whatsapp.settings.scan"))
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, NookTheme.Spacing.xs)
                }

                // A business number or a second phone, each linked with a QR of its own.
                if link.isConnected || accounts.links.count > 1 {
                    WhatsAppAccountRows()
                }

                DisclosureGroup(tr("whatsapp.settings.advanced")) {
                    SettingToggle(tr("whatsapp.settings.markRead"), detail: tr("whatsapp.settings.markReadDetail"), isOn: $markRead)
                        .onChange(of: markRead) { _, value in WhatsAppSettings.markReadOnReply = value }
                    Picker(tr("whatsapp.settings.gateway"), selection: $gateway) {
                        ForEach(WAGatewayKind.allCases, id: \.self) { kind in Text(kind.name).tag(kind) }
                    }
                    .onChange(of: gateway) { _, kind in
                        WhatsAppSettings.gateway = kind
                        address = WhatsAppSettings.url
                        accounts.settingsChanged()
                    }
                    TextField(tr("whatsapp.settings.address"), text: $address, prompt: Text(gateway.defaultURL))
                        .onSubmit { WhatsAppSettings.url = address; accounts.settingsChanged() }
                    SecureField(credentialLabel, text: $credential)
                        .onSubmit { WhatsAppSettings.setCredential(credential); accounts.settingsChanged() }
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
                }

                if !webhookLine.isEmpty, webhookNeedsAttention {
                    SettingNote(webhookLine, tone: .warning)
                }
            }
        } header: {
            SettingsSectionTitle(tr("whatsapp.settings.title"), info: tr("whatsapp.settings.footer"))
        }

        // Once linked, what reaches you gets a section of its own: the main switch, the rule per kind of chat, then
        // every chat on its own (louder or quieter than its kind). The choices hold in every account.
        if enabled, accounts.isConnected {
            Section {
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
            }
        }
    }

    private var credentialLabel: String {
        switch gateway {
        case .gowa: return tr("whatsapp.settings.basicAuth")
        case .openwa: return tr("whatsapp.settings.apiKey")
        }
    }

    @ViewBuilder private var installRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            SettingLabel(tr("whatsapp.install.title"), detail: installLine)
            Spacer()
            if installer.busy {
                ProgressView().controlSize(.small)
            } else {
                Button(tr("whatsapp.install.button")) { installer.install() }
            }
        }
    }

    private var installLine: String {
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

    private var webhookNeedsAttention: Bool {
        switch link.webhook {
        case .portBusy, .refused: return true
        case .off, .listening, .registered: return false
        }
    }

    private var webhookLine: String {
        switch link.webhook {
        case .off: return ""
        case .listening: return tr("whatsapp.webhook.listening", WhatsAppSettings.port)
        case .registered: return tr("whatsapp.webhook.registered")
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
    /// The link as a status row shows it.
    var statusState: StatusState {
        switch link {
        case .connected: return .done
        case .off, .connecting, .needsQR: return .todo
        case .unreachable: return .warning
        case .unauthorized, .failed: return .error
        }
    }
}

/// Every WhatsApp account besides the first, and adding another (a business number, a second phone): each links with a
/// QR of its own, scanned with the phone of that account, on the same gateway. The first account can get a name too, so
/// the Chats tab says which account a chat is in.
struct WhatsAppAccountRows: View {
    @ObservedObject private var accounts = WhatsAppAccounts.shared
    @State private var adding = false
    @State private var newName = ""
    @State private var mainName = WhatsAppSettings.mainName
    @State private var removing: WAAccount?

    var body: some View {
        if accounts.links.count > 1 {
            TextField(tr("whatsapp.accounts.mainName"), text: $mainName, prompt: Text(tr("whatsapp.accounts.mainPrompt")))
                .onSubmit { accounts.rename("", to: mainName) }
        }
        ForEach(accounts.accounts) { account in
            if let link = accounts.links.first(where: { $0.account == account.id }) {
                WhatsAppAccountRow(link: link, account: account, remove: { removing = account })
            }
        }
        Group {
            if adding {
                HStack(spacing: NookTheme.Spacing.md) {
                    TextField(tr("whatsapp.accounts.name"), text: $newName, prompt: Text(tr("whatsapp.accounts.namePrompt")))
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
            .confirmationDialog(tr("whatsapp.accounts.removeTitle", removing?.name ?? ""),
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { account in
                Button(tr("whatsapp.accounts.remove"), role: .destructive) { accounts.remove(account.id) }
                Button(tr("button.cancel"), role: .cancel) {}
            } message: { _ in
                Text(tr("whatsapp.accounts.removeDetail"))
            }
    }

    private func add() {
        accounts.add(name: newName)
        newName = ""
        adding = false
    }
}

/// One account besides the first: its name (a click changes it), where its link stands, its QR until it is linked, and
/// Remove.
private struct WhatsAppAccountRow: View {
    @ObservedObject var link: WhatsAppLink
    let account: WAAccount
    let remove: () -> Void
    @State private var name: String

    init(link: WhatsAppLink, account: WAAccount, remove: @escaping () -> Void) {
        self.link = link
        self.account = account
        self.remove = remove
        _name = State(initialValue: account.name)
    }

    var body: some View {
        StatusRow(title: WhatsAppAccounts.shared.name(of: link), detail: link.statusLine, state: link.statusState) {
            if link.link == .unreachable || link.link == .unauthorized {
                Button(tr("whatsapp.settings.retry")) { link.settingsChanged() }
            }
            Button(tr("whatsapp.accounts.remove"), role: .destructive, action: remove)
        }
        TextField(tr("whatsapp.accounts.name"), text: $name, prompt: Text(tr("whatsapp.accounts.namePrompt")))
            .onSubmit { WhatsAppAccounts.shared.rename(account.id, to: name) }
        if link.link == .needsQR, let data = link.qrPNG, let image = NSImage(data: data) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.xl) {
                QRCodeView(image: image, side: 160, label: tr("chats.link.qr"))
                Text(tr("whatsapp.accounts.scan"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textStrong)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, NookTheme.Spacing.xs)
        }
        if link.webhook == .portBusy, let port = link.webhookPort {
            SettingNote(tr("whatsapp.webhook.portBusy", port), tone: .warning)
        }
    }
}
