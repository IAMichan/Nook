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
            Section { ChatAppNoticeRows(app: "whatsapp", setCollecting: { _ in }) }
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
