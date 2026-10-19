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
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(tr("whatsapp.settings.scan"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }

                if link.isConnected {
                    SettingToggle(tr("whatsapp.settings.notify"), detail: tr("whatsapp.settings.notifyDetail"), isOn: $notify)
                        .onChange(of: notify) { _, value in WhatsAppSettings.notify = value }
                    if notify {
                        SettingToggle(tr("whatsapp.settings.muteGroups"), detail: tr("whatsapp.settings.muteGroupsDetail"),
                                      isOn: Binding(get: { link.filters.muteGroups }, set: { link.filters.muteGroups = $0 }))
                    }
                    if !link.filters.ignored.isEmpty {
                        Button(tr("whatsapp.settings.unmute", link.filters.ignored.count)) { link.filters.ignored = [] }
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
                    Text(webhookLine).font(.caption).foregroundStyle(.secondary)
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
                Text(installLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
