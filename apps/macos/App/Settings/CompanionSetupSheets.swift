import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One switch per `CompanionScope`: what a phone may do from afar. Shared by the pairing sheet and a paired phone's row.
struct CompanionScopeToggles: View {
    @Binding var scopes: Set<CompanionScope>

    var body: some View {
        ForEach(CompanionScope.allCases, id: \.self) { scope in
            Toggle(Self.label(scope), isOn: Binding(
                get: { scopes.contains(scope) },
                set: { on in
                    var next = scopes
                    if on { next.insert(scope) } else { next.remove(scope) }
                    scopes = next
                }))
        }
    }

    static func label(_ scope: CompanionScope) -> String {
        switch scope {
        case .read: return tr("companion.scope.read")
        case .approve: return tr("companion.scope.approve")
        case .operate: return tr("companion.scope.operate")
        case .chats: return tr("companion.scope.chats")
        case .music: return tr("companion.scope.music")
        case .nookChat: return tr("companion.scope.nookChat")
        }
    }
}

// MARK: Pair an iPhone

/// Pairing a new iPhone in the steps every setup uses: the app, what the phone may do (asked before the code, because the
/// phone gets it the moment it scans), the code, and last Nook seeing the phone arrive.
struct PairPhoneSheet: View {
    @ObservedObject private var store = CompanionStore.shared
    @ObservedObject private var server = CompanionServer.shared
    @StateObject private var copied = CopiedMoment()
    @State private var link: PairingLink?
    /// The phone that paired while this sheet was open.
    @State private var paired: PairedDevice?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SetupSheet(title: tr("pairedPhone.pairTitle"), subtitle: tr("pairedPhone.sheet.subtitle")) {
            SettingsTile(.iphone, size: 40)
        } content: {
            SetupStep(number: 1, title: tr("pairedPhone.step.install")) {
                SettingNote(tr("pairedPhone.step.installDetail"))
            }
            SetupStep(number: 2, title: tr("pairedPhone.step.scopes")) {
                CompanionScopeToggles(scopes: $store.pendingScopes)
            }
            SetupStep(number: 3, title: tr("pairedPhone.step.scan"), done: paired != nil) {
                if paired != nil {
                    EmptyView()
                } else if let link, let url = link.url {
                    if let code = QRCodeView(text: url.absoluteString, side: 140, label: tr("companion.qr")) {
                        code
                    }
                    StepAction(detail: tr("companion.pairSteps"),
                               button: copied.copied ? tr("companion.copied") : tr("companion.copyLink"),
                               prominent: false) {
                        copied.copy(url.absoluteString)
                    }
                } else {
                    SettingNote(tr("pairedPhone.notListening"))
                }
            }
            SetupCheckStep(number: 4, title: tr("pairedPhone.step.check"), detail: tr("pairedPhone.step.checkDetail"),
                           state: paired.map { SetupCheckState.passed(tr("pairedPhone.step.checkPassed", $0.name)) } ?? .idle)
        } footer: {
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .sheetPrimaryButton()
        }
        .onAppear(perform: showCode)
        // The code appears as soon as this Mac listens.
        .onChange(of: isListening) { _, _ in showCode() }
        // A phone that just paired through this code is announced, as every other connection that is added.
        .onChange(of: store.devices) { old, new in
            guard link != nil, paired == nil,
                  let added = new.first(where: { device in !old.contains { $0.id == device.id } }) else { return }
            paired = added
            link = nil
            ToastCenter.shared.success(tr("connection.added", added.name))
        }
        // Closing before a phone scanned the code closes the pairing window too.
        .onDisappear { if paired == nil { store.cancelPairing() } }
    }

    private var isListening: Bool { if case .listening = server.state { return true }; return false }

    private func showCode() {
        guard link == nil, paired == nil, isListening else { return }
        link = server.pairingLink()
    }
}

// MARK: Own relay

/// Setting up the user's own relay on Cloudflare: open Cloudflare for a token, paste it, and Nook puts the relay on the
/// account and checks that this Mac connects to it.
struct OwnRelaySheet: View {
    @ObservedObject private var relay = CompanionRelayClient.shared
    @State private var token = ""
    @State private var manualAddress = ""
    /// Set once this sheet started setting up (or chose an address), so the last step follows the relay from then on.
    @State private var started = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SetupSheet(title: tr("companion.relay.sheet.title"), subtitle: tr("companion.relay.setup.intro")) {
            SettingsTile(symbol: "network", colors: (NookTheme.smoke, NookTheme.graphite), size: 40)
        } content: {
            SetupStep(number: 1, title: tr("companion.relay.step.open")) {
                StepAction(detail: tr("companion.relay.step.openDetail"), button: tr("companion.relay.setup.open"), prominent: false) {
                    NSWorkspace.shared.open(CloudflareRelaySetup.tokenPage)
                }
            }
            SetupStep(number: 2, title: tr("companion.relay.step.token")) {
                SecureField(tr("companion.relay.setup.token"), text: $token, prompt: Text(tr("companion.relay.setup.token")).foregroundStyle(NookTheme.textTertiary)).settingsField()
            }
            SetupCheckStep(number: 3, title: tr("companion.relay.step.check"), detail: tr("companion.relay.step.checkDetail"),
                           state: checkState, check: setUp, disabled: cleanToken.isEmpty || settingUp)
            if case .working(let step) = relay.setup { SettingNote(Self.progress(step)) }
            SettingsFold(tr("companion.relay.setup.manual")) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    TextField(tr("companion.relay.address"), text: $manualAddress, prompt: Text(tr("companion.relay.address")).foregroundStyle(NookTheme.textTertiary)).settingsField()
                    Button(tr("companion.relay.setup.use")) {
                        relay.address = manualAddress
                        manualAddress = ""
                        started = true
                    }
                    .disabled(CompanionRelay.normalize(manualAddress) == nil)
                }
            }
        } footer: {
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .sheetPrimaryButton()
        }
    }

    private var cleanToken: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var settingUp: Bool {
        if case .working = relay.setup { return true }
        return false
    }

    private func setUp() {
        started = true
        relay.setUp(token: cleanToken)
        token = ""
    }

    /// The setup first, then whether this Mac reached the relay it made.
    private var checkState: SetupCheckState {
        guard started else { return .idle }
        switch relay.setup {
        case .working: return .checking
        case .failed(let message): return .failed(tr("companion.relay.setup.failed", message))
        case .idle: break
        }
        guard !relay.address.isEmpty else { return .idle }
        switch relay.status {
        case .connected: return .passed(tr("companion.relay.connected"))
        case .connecting, .off: return .checking
        case .invalid: return .failed(tr("companion.relay.invalid"))
        case .failed(let message): return .failed(tr("companion.relay.failed", message))
        }
    }

    private static func progress(_ step: CloudflareRelayDeployer.Step) -> String {
        switch step {
        case .account: return tr("companion.relay.setup.account")
        case .uploading: return tr("companion.relay.setup.uploading")
        case .starting: return tr("companion.relay.setup.starting")
        }
    }
}

// MARK: Own APNs key

/// The user's own Apple key for notifications: make it at Apple, give Nook its ids and the .p8 file, and send a test.
/// Removing the saved key sits on the left, as every removal.
struct APNsKeySheet: View {
    @ObservedObject private var store = CompanionStore.shared
    @ObservedObject private var notifier = CompanionNotifier.shared
    @State private var keyProblem = false
    @State private var test: SetupCheckState = .idle
    /// Bumped when the key changes here, since the Keychain is not observed.
    @State private var keyVersion = 0
    @Environment(\.dismiss) private var dismiss

    private static let keysPage = URL(string: "https://developer.apple.com/account/resources/authkeys/list")!

    var body: some View {
        SetupSheet(title: tr("companion.push.keyTitle"), subtitle: tr("companion.push.sheet.subtitle")) {
            SettingsTile(symbol: "key", colors: (NookTheme.smoke, NookTheme.graphite), size: 40)
        } content: {
            SetupStep(number: 1, title: tr("companion.push.step.make")) {
                StepAction(detail: tr("companion.push.step.makeDetail"), button: tr("companion.push.step.openApple"), prominent: false) {
                    NSWorkspace.shared.open(Self.keysPage)
                }
            }
            SetupStep(number: 2, title: tr("companion.push.step.ids"), done: store.canPush) {
                TextField(tr("companion.push.keyID"), text: $store.apnsKeyID, prompt: Text(tr("companion.push.keyID")).foregroundStyle(NookTheme.textTertiary)).settingsField()
                TextField(tr("companion.push.teamID"), text: $store.apnsTeamID, prompt: Text(tr("companion.push.teamID")).foregroundStyle(NookTheme.textTertiary)).settingsField()
                if store.hasAPNsKey {
                    StepAction(detail: tr("companion.push.keySaved"), button: tr("companion.push.step.replaceKey"),
                               prominent: false, action: importKey)
                } else {
                    StepAction(detail: tr("companion.push.step.importDetail"), button: tr("companion.push.importKey"),
                               prominent: false, action: importKey)
                }
                if keyProblem { SettingNote(tr("companion.push.keyInvalid"), tone: .error) }
            }
            SetupCheckStep(number: 3, title: tr("companion.push.test"), detail: testDetail, state: test,
                           check: sendTest, disabled: !store.canPush || !hasPhone)
        } footer: {
            if store.hasAPNsKey {
                ConfirmedButton(tr("companion.push.removeKey"), question: tr("confirm.removePush"),
                                detail: tr("confirm.removePush.detail")) {
                    store.removeAPNsKey()
                    APNsClient.shared.forgetToken()
                    keyProblem = false
                    keyVersion += 1
                    test = .idle
                }
            }
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .sheetPrimaryButton()
        }
        .id(keyVersion)
        .onChange(of: store.apnsKeyID) { _, _ in test = .idle }
        .onChange(of: store.apnsTeamID) { _, _ in test = .idle }
        .onReceive(notifier.$lastResult.dropFirst()) { result in
            guard test == .checking, let result else { return }
            test = Self.outcome(result)
        }
    }

    private var hasPhone: Bool { store.devices.contains { $0.pushToken != nil } }

    private var testDetail: String {
        if !store.canPush { return tr("companion.push.notReady") }
        return hasPhone ? tr("companion.push.step.testDetail") : tr("companion.push.step.needsPhone")
    }

    private func sendTest() {
        test = .checking
        notifier.sendTest()
        // Delivery answers within seconds; a test that never answers does not leave the step spinning.
        Task {
            try? await Task.sleep(for: .seconds(20))
            if test == .checking { test = .failed(tr("companion.push.step.noAnswer")) }
        }
    }

    /// Every phone answered "ok": the key works. Otherwise the line names what each phone answered.
    private static func outcome(_ result: String) -> SetupCheckState {
        let parts = result.components(separatedBy: " · ")
        guard !result.isEmpty else { return .failed(tr("companion.push.step.needsPhone")) }
        return parts.allSatisfy { $0.hasSuffix(": ok") } ? .passed(tr("companion.push.step.passed")) : .failed(result)
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
        keyVersion += 1
        test = .idle
    }
}
