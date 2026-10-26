import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings for the iPhone companion: switch it on, pair a phone (QR code or link, valid for five minutes) and remove phones.
struct CompanionSettingsRows: View {
    @ObservedObject private var store = CompanionStore.shared
    @ObservedObject private var server = CompanionServer.shared
    @ObservedObject private var notifier = CompanionNotifier.shared
    @ObservedObject private var relay = CompanionRelayClient.shared
    @ObservedObject private var awake = KeepAwake.shared
    @State private var keyProblem = false
    @State private var link: PairingLink?
    @State private var copied = false
    /// The Cloudflare token being pasted, and the address of a relay set up some other way.
    @State private var token = ""
    @State private var manualAddress = ""

    var body: some View {
        // Three sections instead of one long row: the phone and its pairing, push notifications, and the key push
        // needs from Apple (only while push is on).
        Section {
            Toggle(tr("companion.enable"), isOn: Binding(get: { store.enabled }, set: { store.enabled = $0; server.apply() }))
            SettingNote(tr("companion.hint"))
            if store.enabled {
                status
                ForEach(store.devices) { device in
                    HStack(spacing: NookTheme.Spacing.md) {
                        Image(systemName: "iphone").foregroundStyle(NookTheme.textSecondary).frame(width: 22)
                        SettingLabel(device.name, detail: deviceDetail(device))
                        Spacer()
                        ConfirmedButton(tr("companion.remove"), question: tr("confirm.remove", device.name),
                                        detail: tr("confirm.removeDevice.detail")) { store.remove(device.id) }
                    }
                    if device.protocolVersion != nil, !CompanionCompatibility.phoneSupported(device.protocolVersion) {
                        SettingNote(tr("companion.device.outdated"), tone: .error)
                    }
                }
                if store.devices.isEmpty { SettingNote(tr("companion.none")) }
                if let link {
                    pairing(link)
                } else {
                    Button(tr("companion.pair")) { link = server.pairingLink() }
                        .disabled(!isListening)
                }
            }
        } header: {
            Text(tr("settings.devices.iphone"))
        }
        // The window closes by itself; also when a phone completes it.
        .onChange(of: store.devices) { _, _ in link = nil }
        .onChange(of: store.enabled) { _, on in if !on { link = nil } }

        if store.enabled {
            Section { awayFromHome } header: { Text(tr("companion.away.title")) }
            Section { pushSection }
            if store.push.enabled {
                Section { apnsSetup } header: { Text(tr("companion.push.keyTitle")) }
            }
        }
    }

    // MARK: Push

    private func kindBinding(_ kind: PushEvent.Kind) -> Binding<Bool> {
        Binding(get: { store.push.kinds.contains(kind) },
                set: { on in if on { store.push.kinds.insert(kind) } else { store.push.kinds.remove(kind) } })
    }

    private func hourBinding(_ keyPath: WritableKeyPath<PushSettings, Int?>) -> Binding<Int> {
        Binding(get: { store.push[keyPath: keyPath] ?? 22 }, set: { store.push[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private var pushSection: some View {
        SettingToggle(tr("companion.push.enable"), detail: tr("companion.push.hint"), isOn: $store.push.enabled)
        if store.push.enabled {
            Group {
                Toggle(tr("companion.push.approval"), isOn: kindBinding(.approval))
                Toggle(tr("companion.push.question"), isOn: kindBinding(.question))
                Toggle(tr("companion.push.finished"), isOn: kindBinding(.finished))
                Toggle(tr("companion.push.failed"), isOn: kindBinding(.failed))
                Toggle(tr("companion.push.limited"), isOn: kindBinding(.limited))
            }
            .padding(.leading, NookTheme.Spacing.lg)
            Toggle(tr("companion.push.onlyAway"), isOn: $store.push.onlyWhenAway)
            Toggle(tr("companion.push.titles"), isOn: $store.push.includeTitle)
            Toggle(tr("companion.push.quiet"), isOn: Binding(
                get: { store.push.quietFrom != nil },
                set: { on in store.push.quietFrom = on ? 22 : nil; store.push.quietTo = on ? 7 : nil }))
            if store.push.quietFrom != nil {
                HStack {
                    Stepper(tr("companion.push.from", store.push.quietFrom ?? 22), value: hourBinding(\.quietFrom), in: 0...23)
                    Stepper(tr("companion.push.to", store.push.quietTo ?? 7), value: hourBinding(\.quietTo), in: 0...23)
                }
                Toggle(tr("companion.push.urgent"), isOn: $store.push.quietAllowsUrgent)
            }
        }
    }

    @ViewBuilder
    private var apnsSetup: some View {
        SettingNote(tr("companion.push.keyHint"))
        HStack {
            TextField(tr("companion.push.keyID"), text: $store.apnsKeyID).textFieldStyle(.roundedBorder)
            TextField(tr("companion.push.teamID"), text: $store.apnsTeamID).textFieldStyle(.roundedBorder)
        }
        HStack {
            if store.hasAPNsKey {
                InUseLabel(tr("companion.push.keySaved"))
                ConfirmedButton(tr("companion.remove"), question: tr("confirm.removePush"), detail: tr("confirm.removePush.detail")) {
                    store.removeAPNsKey(); APNsClient.shared.forgetToken(); keyProblem = false
                }
            } else {
                Button(tr("companion.push.importKey")) { importKey() }
            }
            Button(tr("companion.push.test")) { notifier.sendTest() }
                .disabled(!store.canPush || !store.devices.contains { $0.pushToken != nil })
        }
        if keyProblem { SettingNote(tr("companion.push.keyInvalid"), tone: .error) }
        if !store.canPush { SettingNote(tr("companion.push.notReady")) }
        if let result = notifier.lastResult { SettingNote(result) }
    }

    /// Reads the .p8 file the user downloaded from Apple; its contents go to the Keychain and are not shown.
    private func importKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        keyProblem = !store.saveAPNsKey(pem: text)
        APNsClient.shared.forgetToken()
    }

    /// When the phone was last seen, and which version of the app it runs once it said so.
    private func deviceDetail(_ device: PairedDevice) -> String {
        let seen = device.lastSeen.map { tr("companion.lastSeen", $0.formatted(.relative(presentation: .named))) } ?? tr("companion.neverSeen")
        guard let version = device.appVersion else { return seen }
        return seen + " · " + tr("companion.device.version", version)
    }

    private var isListening: Bool { if case .listening = server.state { return true }; return false }

    /// Reaching this Mac outside the home network: one switch for a relay (Nook's, or one Settings sets up on the user's
    /// own Cloudflare account), and whether Tailscale runs here.
    @ViewBuilder
    private var awayFromHome: some View {
        SettingToggle(tr("companion.relay.enable"),
                      detail: CompanionRelayClient.nookRelay == nil ? tr("companion.relay.hint.own") : tr("companion.relay.hint"),
                      isOn: $relay.enabled)
        if relay.enabled {
            if CompanionRelayClient.nookRelay != nil {
                Picker(tr("companion.relay.which"), selection: $relay.mode) {
                    Text(tr("companion.relay.mode.nook")).tag(CompanionRelayClient.Mode.nook)
                    Text(tr("companion.relay.mode.own")).tag(CompanionRelayClient.Mode.own)
                }
                .pickerStyle(.segmented)
            }
            if relay.mode == .own { ownRelay }
            relayStatus
            relayTest
        }
        keepAwake
        if case .listening = server.state {
            let tailnet = server.endpoints().filter { $0.tailnet == true }.map(\.host)
            if tailnet.isEmpty {
                SettingNote(tr("companion.tailscale.off"))
            } else {
                SettingNote(tr("companion.tailscale.on", tailnet.joined(separator: ", ")), tone: .success)
            }
        }
    }

    /// A Mac that sleeps cannot be reached: Nook keeps it awake while it may be needed (`KeepAwake`).
    @ViewBuilder
    private var keepAwake: some View {
        Picker(tr("companion.awake.title"), selection: $awake.mode) {
            Text(tr("companion.awake.off")).tag(KeepAwakePolicy.Mode.off)
            Text(tr("companion.awake.working")).tag(KeepAwakePolicy.Mode.whileWorking)
            Text(tr("companion.awake.always")).tag(KeepAwakePolicy.Mode.always)
        }
        SettingNote(tr("companion.awake.hint"))
        switch awake.decision.reason {
        case .working?: SettingNote(tr("companion.awake.now.working"), tone: .success)
        case .phone?: SettingNote(tr("companion.awake.now.phone"), tone: .success)
        case .always?: SettingNote(tr("companion.awake.now.always"), tone: .success)
        case nil: EmptyView()
        }
    }

    /// The user's own relay: set up in two steps (open Cloudflare, paste the token), or the one already set up.
    @ViewBuilder
    private var ownRelay: some View {
        if relay.address.isEmpty {
            SettingNote(tr("companion.relay.setup.intro"))
            Button(tr("companion.relay.setup.open")) { NSWorkspace.shared.open(CloudflareRelaySetup.tokenPage) }
            HStack(spacing: NookTheme.Spacing.md) {
                SecureField(tr("companion.relay.setup.token"), text: $token).textFieldStyle(.roundedBorder)
                Button(tr("companion.relay.setup.go")) {
                    relay.setUp(token: token)
                    token = ""
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || settingUp)
            }
            switch relay.setup {
            case .working(.account): SettingNote(tr("companion.relay.setup.account"))
            case .working(.uploading): SettingNote(tr("companion.relay.setup.uploading"))
            case .working(.starting): SettingNote(tr("companion.relay.setup.starting"))
            case .failed(let message): SettingNote(tr("companion.relay.setup.failed", message), tone: .error)
            case .idle: EmptyView()
            }
            DisclosureGroup(tr("companion.relay.setup.manual")) {
                HStack(spacing: NookTheme.Spacing.md) {
                    TextField(tr("companion.relay.address"), text: $manualAddress).textFieldStyle(.roundedBorder)
                    Button(tr("companion.relay.setup.use")) {
                        relay.address = manualAddress
                        manualAddress = ""
                    }
                    .disabled(CompanionRelay.normalize(manualAddress) == nil)
                }
            }
        } else {
            HStack(spacing: NookTheme.Spacing.md) {
                SettingNote(tr("companion.relay.own.address", relay.address))
                Spacer()
                Button(tr("companion.relay.own.change")) { relay.forgetOwnRelay() }
            }
        }
    }

    private var settingUp: Bool {
        if case .working = relay.setup { return true }
        return false
    }

    @ViewBuilder
    private var relayStatus: some View {
        switch relay.status {
        case .connected: SettingNote(tr("companion.relay.connected"), tone: .success)
        case .connecting: SettingNote(tr("companion.relay.connecting"))
        case .invalid:
            if relay.mode == .own, !relay.address.isEmpty { SettingNote(tr("companion.relay.invalid"), tone: .error) }
        case .failed(let message): SettingNote(tr("companion.relay.failed", message), tone: .error)
        case .off: EmptyView()
        }
    }

    /// *Test relay*: a message through the relay to this Mac and back, as the phone sends it from away.
    @ViewBuilder
    private var relayTest: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Button(relay.testing ? tr("companion.relay.testing") : tr("companion.relay.test")) { relay.testRelay() }
                .disabled(!relay.canTest || relay.testing)
            if relay.enabled, store.devices.isEmpty { SettingNote(tr("companion.relay.test.needsPhone")) }
        }
        if let result = relay.testResult, !relay.testing {
            SettingNote(Self.testHeadline(result), tone: result.cause == .connected ? .success : .error)
            SettingNote(result.hops.filter { $0.hop != .device }.map(Self.hopLine).joined(separator: " · "))
        }
    }

    private static func testHeadline(_ result: CompanionDiagnosis.Result) -> String {
        switch result.cause {
        case .connected: return tr("companion.relay.test.ok", result.fastestMilliseconds ?? 0)
        case .macNotOnRelay: return tr("companion.relay.test.macOffline")
        case .relayUnreachable: return tr("companion.relay.test.unreachable")
        case .relayFull: return tr("companion.relay.test.full")
        case .macSilent: return tr("companion.relay.test.silent")
        default: return tr("companion.relay.test.failed")
        }
    }

    private static func hopLine(_ state: CompanionDiagnosis.HopState) -> String {
        let name = state.hop == .relay ? tr("companion.diag.hop.relay") : tr("companion.diag.hop.mac")
        switch state.result {
        case .ok: return tr("companion.diag.ok", name)
        case .failed: return tr("companion.diag.failed", name)
        case .unchecked: return tr("companion.diag.unchecked", name)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch server.state {
        case .listening(let port):
            SettingNote(tr("companion.listening", Int(port)), tone: .success)
            let places = server.endpoints().map { $0.tailnet == true ? tr("companion.reachable.tailnet", $0.host) : $0.host }
            if !places.isEmpty { SettingNote(tr("companion.reachable", places.joined(separator: ", "))) }
        case .failed(let message): SettingNote(tr("companion.failed", message), tone: .error)
        case .stopped: EmptyView()
        }
    }

    private func pairing(_ link: PairingLink) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let url = link.url, let code = QRCodeView(text: url.absoluteString, side: 140, label: tr("companion.qr")) {
                code
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(tr("companion.pairSteps")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textStrong).fixedSize(horizontal: false, vertical: true)
                Button(copied ? tr("companion.copied") : tr("companion.copyLink")) {
                    if let url = link.url {
                        Pasteboard.copy(url.absoluteString)
                        copied = true
                    }
                }
                Button(tr("companion.cancelPairing")) { store.cancelPairing(); self.link = nil; copied = false }
            }
        }
    }
}
