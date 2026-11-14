import SwiftUI
import AppKit

/// Settings for the iPhone companion, in the order you meet it: switch it on, the phones already paired (one
/// `ConnectionRow` each, which opens to its permissions and details; "+ Pair an iPhone" opens `PairPhoneSheet`), what the
/// phones are told, and reaching this Mac away from home, folded because most people pair at home and never need it.
struct CompanionSettingsRows: View {
    @ObservedObject private var store = CompanionStore.shared
    @ObservedObject private var server = CompanionServer.shared
    @ObservedObject private var notifier = CompanionNotifier.shared
    @ObservedObject private var relay = CompanionRelayClient.shared
    @ObservedObject private var awake = KeepAwake.shared
    @ObservedObject private var relayPush = RelayPushClient.shared
    @StateObject private var diagnosticsCopied = CopiedMoment()
    /// The setup sheets this page opens: pairing a phone, the user's own relay, and the user's own Apple key.
    @State private var pairing = false
    @State private var settingUpRelay = false
    @State private var settingUpKey = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { store.enabled }, set: { store.enabled = $0; server.apply() })) { SettingText("companion.enable") }
            if store.enabled {
                status
                // The local connection log, redacted (no addresses, names or keys), for the user to paste where they choose.
                HStack(spacing: NookTheme.Spacing.md) {
                    Button(diagnosticsCopied.copied ? tr("companion.diagnostics.copied") : tr("companion.diagnostics.copy")) {
                        diagnosticsCopied.copy(CompanionDiagnosticsLog.mac.bundle(about: diagnosticsAbout))
                    }
                    SettingNote(tr("companion.diagnostics.hint"))
                }
            }
        } header: {
            SettingsSectionTitle(tr("settings.devices.iphone"), info: tr("companion.hint"))
        }
        // The sheets hang on this section, which is always there: the row that opened one may go once it is done
        // (the relay row turns into its address), and the sheet must stay to show that.
        .sheet(isPresented: $pairing) { PairPhoneSheet() }
        .sheet(isPresented: $settingUpRelay) { OwnRelaySheet() }
        .sheet(isPresented: $settingUpKey) { APNsKeySheet() }
        // Switching the companion off closes a pairing that was under way.
        .onChange(of: store.enabled) { _, on in if !on { pairing = false } }

        if store.enabled {
            pairedPhones
            Section { pushSection } header: { SettingText("pairedPhone.pushTitle") }
            if store.push.enabled {
                Section { pushRoute } header: { Text(tr("companion.push.keyTitle")) }
            }
            SettingsFold(tr("companion.away.title"), summary: awaySummary,
                         keys: ["companion.relay.enable", "companion.awake.title"]) {
                awayFromHome
            }
        }
    }

    // MARK: Paired iPhones

    /// "+ Pair an iPhone" opens the pairing steps in a sheet.
    private var pairAction: (title: String, action: () -> Void) {
        (tr("companion.pair"), { pairing = true })
    }

    private var pairedPhones: some View {
        Section {
            if store.devices.isEmpty {
                ConnectionListEmpty(title: tr("pairedPhone.empty.title"), detail: tr("pairedPhone.empty.detail"))
            } else {
                ForEach(store.devices) { deviceRow($0) }
            }
        } header: {
            ConnectionListHeader(title: tr("pairedPhone.title"), add: pairAction)
        }
    }

    /// One paired phone: its name and app version, how recently it was seen, and once opened what it may do and the
    /// rest of what this Mac knows about it. Unpairing sits last in its "…" menu.
    private func deviceRow(_ device: PairedDevice) -> some View {
        let outdated = device.protocolVersion != nil && !CompanionCompatibility.phoneSupported(device.protocolVersion)
        return ConnectionRow(
            title: device.name,
            version: device.appVersion,
            status: outdated ? .expired : .connected,
            statusText: outdated ? tr("pairedPhone.outdated") : tr("pairedPhone.paired"),
            detail: lastSeen(device),
            removal: ConnectionRemoval(title: tr("companion.remove"), question: tr("pairedPhone.unpairQuestion", device.name),
                                       detail: tr("pairedPhone.unpairDetail")) {
                store.remove(device.id)
                ToastCenter.shared.success(tr("connection.removed", device.name))
            }
        ) {
            Image(icon: "iphone")
                .font(NookTheme.font(16))
                .foregroundStyle(NookTheme.textSecondary)
        } expanded: {
            if outdated {
                SettingNote(tr("companion.device.outdated"), tone: .error)
            } else if device.protocolVersion != nil, CompanionCompatibility.phoneBehind(device.protocolVersion) {
                // It works, but cannot use what this Nook added since (pull requests, sharing…).
                SettingNote(tr("companion.phone.behind"), tone: .info)
            }
            SheetPart(tr("companion.scopes.title")) {
                CompanionScopeToggles(scopes: Binding(get: { device.grantedScopes }, set: { store.setScopes(device: device.id, $0) }))
            }
            SheetPart(tr("pairedPhone.details")) {
                LabeledContent(tr("pairedPhone.lastSeen")) {
                    Text(device.lastSeen.map { $0.formatted(.relative(presentation: .named)) } ?? tr("companion.neverSeen"))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                LabeledContent(tr("pairedPhone.pairedOn")) {
                    Text(device.pairedAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                LabeledContent(tr("pairedPhone.appVersion")) {
                    Text(device.appVersion ?? tr("pairedPhone.unknown"))
                        .font(device.appVersion == nil ? NookTheme.TextStyle.body : NookTheme.mono(11))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                LabeledContent(tr("pairedPhone.notifications")) {
                    Text(device.pushToken != nil ? tr("pairedPhone.notificationsOn") : tr("pairedPhone.notificationsOff"))
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
        }
    }

    /// When the phone was last seen, for the line under its name.
    private func lastSeen(_ device: PairedDevice) -> String {
        device.lastSeen.map { tr("companion.lastSeen", $0.formatted(.relative(presentation: .named))) } ?? tr("companion.neverSeen")
    }

    /// What the folded "Away from home" group says while closed: whether a relay carries the phones there, and how.
    private var awaySummary: String {
        guard relay.enabled else { return tr("pairedPhone.away.off") }
        switch relay.status {
        case .connected: return tr("pairedPhone.away.relayConnected")
        case .failed, .invalid: return tr("pairedPhone.away.relayProblem")
        case .connecting, .off: return tr("pairedPhone.away.relayOn")
        }
    }

    // MARK: Push

    private func kindBinding(_ kind: PushEvent.Kind) -> Binding<Bool> {
        Binding(get: { store.push.kinds.contains(kind) },
                set: { on in if on { store.push.kinds.insert(kind) } else { store.push.kinds.remove(kind) } })
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
            // One set of quiet hours for the Mac and the phone, kept with the other notice rules.
            SettingNote(tr("companion.push.quietShared"))
        }
    }

    /// How pushes reach Apple: sealed through the relay (no Apple account needed), or with the user's own APNs key.
    @ViewBuilder
    private var pushRoute: some View {
        Picker(tr("relayPush.route"), selection: $relayPush.route) {
            Text(tr("relayPush.route.relay")).tag(RelayPushClient.Route.relay)
            Text(tr("relayPush.route.own")).tag(RelayPushClient.Route.own)
        }
        .pickerStyle(.segmented)
        if relayPush.route == .relay { relaySetup } else { apnsSetup }
    }

    @ViewBuilder
    private var relaySetup: some View {
        SettingNote(tr("relayPush.hint"))
        if relayPush.relay == nil {
            SettingNote(tr("relayPush.noRelay"), tone: .warning)
        }
        Button(tr("companion.push.test")) { notifier.sendTest() }
            .disabled(!relayPush.active || !store.devices.contains { $0.pushToken != nil })
        SettingNote(tr("relayPush.liveActivities"))
        if let result = notifier.lastResult { SettingNote(result) }
    }

    /// The user's own Apple key: one row with its state; making, importing and testing it happen in `APNsKeySheet`.
    private var apnsSetup: some View {
        StatusRow(title: tr("companion.push.keyRow"),
                  detail: store.canPush ? tr("companion.push.keySaved") : tr("companion.push.notReady"),
                  state: store.canPush ? .done : .todo) {
            Button(store.canPush ? tr("companion.push.keyChange") : tr("companion.push.keySetUp")) { settingUpKey = true }
        }
    }

    /// The header of *Copy diagnostics*: versions and what is set up, nothing that names the user or a device.
    private var diagnosticsAbout: [String: String] {
        var about = ["app": CompanionProtocol.appVersion ?? "?", "protocol": String(CompanionProtocol.version),
                     "phones": String(store.devices.count), "relay": relay.enabled ? relay.mode.rawValue : "off",
                     "relayStatus": String(describing: relay.status), "server": String(describing: server.state)]
        for (index, device) in store.devices.enumerated() {
            about["phone\(index + 1)"] = "app \(device.appVersion ?? "?") · protocol \(device.protocolVersion.map { String($0) } ?? "1") · "
                + CompanionScopes.names(device.grantedScopes).joined(separator: ",")
        }
        return about
    }

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

    /// The user's own relay: one row that opens `OwnRelaySheet` while there is none, or the one already set up.
    @ViewBuilder
    private var ownRelay: some View {
        if relay.address.isEmpty {
            HStack(spacing: NookTheme.Spacing.md) {
                SettingLabel(tr("companion.relay.sheet.title"), detail: tr("companion.relay.setup.intro"))
                Spacer(minLength: NookTheme.Spacing.md)
                Button(tr("companion.relay.setup.go")) { settingUpRelay = true }
                    .controlSize(.small)
            }
        } else {
            HStack(spacing: NookTheme.Spacing.md) {
                SettingNote(tr("companion.relay.own.address", relay.address))
                Spacer()
                Button(tr("companion.relay.own.change")) { relay.forgetOwnRelay() }
            }
        }
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
}
