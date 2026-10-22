import SwiftUI
import AppKit

/// Settings › Accounts & connections › WhatsApp, live: link the phone through a local gateway so Nook can show new
/// messages in the notch, answer them and send messages after your OK.
struct WhatsAppLinkSection: View {
    @ObservedObject private var link = WhatsAppLink.shared
    @ObservedObject private var installer = WhatsAppGOWAInstaller.shared
    @State private var enabled = WhatsAppSettings.enabled
    @State private var gateway = WhatsAppSettings.gateway
    @State private var address = WhatsAppSettings.url
    @State private var credential = WhatsAppSettings.credential ?? ""
    @State private var autoStart = WhatsAppGOWAProcess.autoStart
    @State private var notify = WhatsAppSettings.notify
    @State private var markRead = WhatsAppSettings.markReadOnReply

    var body: some View {
        Section {
            SettingToggle(tr("whatsapp.settings.enable"), detail: tr("whatsapp.settings.enableDetail"), isOn: $enabled)
                .onChange(of: enabled) { _, on in link.setEnabled(on) }

            if enabled {
                StatusRow(title: "WhatsApp", detail: link.statusLine, state: state) {
                    if link.link == .unreachable || link.link == .unauthorized {
                        Button(tr("whatsapp.settings.retry")) { link.settingsChanged() }
                    }
                }

                if gateway == .gowa, !WhatsAppGOWAInstaller.isInstalled || installer.busy {
                    installRow
                }

                if link.link == .needsQR, let data = link.qrPNG, let image = NSImage(data: data) {
                    HStack(alignment: .top, spacing: 16) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.none)
                            .frame(width: 180, height: 180)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control))
                        Text(tr("whatsapp.settings.scan"))
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                if link.isConnected {
                    SettingToggle(tr("whatsapp.settings.notify"), detail: tr("whatsapp.settings.notifyDetail"), isOn: $notify)
                        .onChange(of: notify) { _, value in WhatsAppSettings.notify = value }
                    if notify {
                        // The rule per kind of chat, then every chat on its own: louder or quieter than its kind.
                        SettingToggle(tr("whatsapp.settings.muteGroups"), detail: tr("whatsapp.settings.muteGroupsDetail"),
                                      isOn: Binding(get: { link.filters.muteGroups }, set: { link.filters.muteGroups = $0 }))
                        SettingToggle(tr("whatsapp.settings.muteStatus"), detail: tr("whatsapp.settings.muteStatusDetail"),
                                      isOn: Binding(get: { link.filters.muteStatus }, set: { link.filters.muteStatus = $0 }))
                        SettingToggle(tr("whatsapp.settings.muteChannels"), detail: tr("whatsapp.settings.muteChannelsDetail"),
                                      isOn: Binding(get: { link.filters.muteChannels }, set: { link.filters.muteChannels = $0 }))
                        WhatsAppChatModeList()
                    }
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
                        link.settingsChanged()
                    }
                    TextField(tr("whatsapp.settings.address"), text: $address, prompt: Text(gateway.defaultURL))
                        .onSubmit { WhatsAppSettings.url = address; link.settingsChanged() }
                    SecureField(gateway == .gowa ? tr("whatsapp.settings.basicAuth") : tr("whatsapp.settings.apiKey"), text: $credential)
                        .onSubmit { WhatsAppSettings.setCredential(credential); link.settingsChanged() }
                    if gateway == .gowa, WhatsAppGOWAInstaller.isInstalled {
                        Toggle(tr("whatsapp.settings.autoStart"), isOn: $autoStart)
                            .onChange(of: autoStart) { _, on in WhatsAppGOWAProcess.autoStart = on; link.settingsChanged() }
                    }
                }

                if !webhookLine.isEmpty, webhookNeedsAttention {
                    Text(webhookLine).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                }
            }
        } header: {
            Text(tr("whatsapp.settings.title"))
        } footer: {
            Text(tr("whatsapp.settings.footer"))
        }
    }

    private var state: StatusState {
        switch link.link {
        case .connected: return .done
        case .off, .connecting, .needsQR: return .todo
        case .unreachable: return .warning
        case .unauthorized, .failed: return .error
        }
    }

    @ViewBuilder private var installRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("whatsapp.install.title"))
                Text(installLine).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
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
/// one by one.
struct WhatsAppChatModeList: View {
    @ObservedObject private var link = WhatsAppLink.shared
    @State private var query = ""
    @State private var open = false

    private var chats: [(jid: String, name: String)] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return link.chatsForSettings.filter { !link.filters.ignored.contains($0.jid) }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
    }

    private var hidden: [(jid: String, name: String)] {
        let names = Dictionary(link.chatsForSettings.map { ($0.jid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return link.filters.ignored.sorted().map { ($0, names[$0] ?? WAJID.displayNumber($0)) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            if link.chatsForSettings.isEmpty {
                Text(tr("whatsapp.settings.noChats")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(NookTheme.textSecondary)
                    TextField(tr("whatsapp.settings.chatSearch"), text: $query).textFieldStyle(.plain)
                }
                ForEach(chats, id: \.jid) { chat in
                    row(chat.jid, name: chat.name)
                }
            }
            if !hidden.isEmpty {
                Text(tr("whatsapp.settings.hidden"))
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.top, 6)
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
            SettingLabel(tr("whatsapp.settings.perChat"), detail: tr("whatsapp.settings.perChatDetail"))
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
