import SwiftUI
import Security
import AppKit

// MARK: - Building the views

/// Online services (GitHub, Stripe, …) in Settings. Opens the existential so each view can observe its connector.
@MainActor
enum CloudConnectorViews {
    /// A connected service: one calm row with its state and an on/off switch. Clicking opens the manage sheet.
    static func row(_ source: ContextSource, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        guard let config = source as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeRow(config, capabilities: capabilities, onChange: onChange)
    }

    /// A service that is not connected yet: a card in the gallery. Clicking opens the step-by-step setup.
    static func card(_ source: ContextSource, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        guard let config = source as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeCard(config, capabilities: capabilities, onChange: onChange)
    }

    /// A service that is not connected yet, as a calm row with a Connect button (opens the step-by-step setup).
    static func linkRow(_ source: ContextSource, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        guard let config = source as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeLinkRow(config, capabilities: capabilities, onChange: onChange)
    }

    /// The setup sheet on its own, for a row elsewhere that offers "Use a key instead".
    static func setupSheet(_ source: ContextSource, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        guard let config = source as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeSheet(config, capabilities: capabilities, onChange: onChange)
    }

    private static func makeLinkRow<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(ServiceLinkRow(connector: connector, capabilities: capabilities, onChange: onChange))
    }

    private static func makeSheet<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(ServiceSetupSheet(connector: connector, capabilities: capabilities, onChange: onChange))
    }

    private static func makeRow<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(ServiceRow(connector: connector, capabilities: capabilities, onChange: onChange))
    }

    private static func makeCard<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(ServiceCard(connector: connector, capabilities: capabilities, onChange: onChange))
    }
}

/// How a service is doing, in one of a handful of plain states.
@MainActor
enum ServiceState {
    static func health(of connector: some ContextSource, configured: Bool, isOn: Bool) -> ConnectionHealth {
        guard configured else { return .notLinked }
        guard isOn else { return .off }
        switch connector.status.state {
        case .off, .loading: return .busy
        // Items that are waiting for you (a review, a failing check) are content, not a broken link: the link works.
        case .ok: return .working
        case .error: return (connector.status.errorKind ?? .other).needsReconnect ? .needsYou : .broken
        }
    }

    /// One short line under the name: what Nook sees, or what went wrong.
    static func summary(of connector: some ContextSource, health: ConnectionHealth) -> String {
        switch health {
        case .notLinked: return tagline(connector.id)
        case .off: return tr("settings2.service.offDetail")
        case .busy: return tr("settings2.service.busyDetail")
        case .working, .needsYou, .broken:
            if case .error(let message) = connector.status.state {
                return health == .needsYou ? tr("settings2.service.relinkDetail") : message
            }
            let headline = connector.status.headline
            let base = headline.isEmpty ? tr("connect.status.connected") : headline
            return base + (connector.status.updated.map { " · " + tr("context.updated", NookDates.ago($0)) } ?? "")
        }
    }

    /// What a service is for, in a few words: "Je pull requests en reviews".
    static func tagline(_ id: String) -> String {
        let key = "settings2.tagline.\(id)"
        let text = tr(key)
        return text == key ? tr("settings2.tagline.default") : text
    }
}

// MARK: - Row (connected)

private struct ServiceRow<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    let capabilities: String
    let onChange: () -> Void

    @State private var showSetup = false
    @State private var isOn = true
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    @ObservedObject private var mcpSignIn = MCPSignIn.shared
    @EnvironmentObject private var app: AppModel
    /// Whether this row started a sign-in, so only this row reacts to it finishing.
    @State private var repairing = false
    /// Why signing in on the service's own page didn't work, shown in the row until the next try.
    @State private var repairFailure: String?

    private var health: ConnectionHealth { ServiceState.health(of: connector, configured: true, isOn: isOn) }

    /// The same service with its own sign-in page (Notion, Stripe, Vercel): an expired key is repaired by signing in.
    private var signInService: MCPRemoteService? { MCPRemoteService.all.first { $0.id == connector.id } }

    /// Repairs in place by signing in again, never via a key: GitHub's login (or the gh login), or the service's own page.
    private var repairsInPlace: Bool { health == .needsYou && (connector.id == "github" || signInService != nil) }

    private var signingIn: Bool {
        guard repairing else { return false }
        if connector.id != "github" {
            if case .connecting = mcpSignIn.phase { return true }
            return false
        }
        switch gitHubSignIn.phase {
        case .checkingCLI, .waiting, .waitingForCLI: return true
        case .idle, .done, .failed: return false
        }
    }

    private var signingInDetail: String {
        connector.id == "github" ? tr("connector.githubFinishLogin") : tr("connect.waiting", connector.title)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { showSetup = true } label: {
                HStack(spacing: 12) {
                    ServiceTile(domain: connector.iconDomain, fallback: connector.symbol, tint: connector.accent, size: 30, source: connector.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.title)
                        Text(signingIn ? signingInDetail : repairFailure ?? ServiceState.summary(of: connector, health: health))
                            .font(.caption)
                            .foregroundStyle(health == .broken || repairFailure != nil ? ConnectionHealth.broken.color : Color.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if health != .broken && health != .needsYou {
                        HealthPill(health: health)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("settings2.service.manageHelp", connector.title))
            if signingIn {
                ProgressView().controlSize(.small)
            } else if health == .broken || health == .needsYou {
                Button { repair() } label: {
                    Text(tr("settings2.fix"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(health.color))
                }
                .buttonStyle(.plain)
            }
            Toggle(tr("music.on"), isOn: Binding(get: { isOn }, set: { setOn($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(tr("settings2.service.toggleHelp"))
        }
        .padding(.vertical, 3)
        .onAppear { isOn = ConnectorToggle.isOn(connector.id) }
        .sheet(isPresented: $showSetup, onDismiss: {
            isOn = ConnectorToggle.isOn(connector.id)
            onChange()
        }) {
            ServiceSetupSheet(connector: connector, capabilities: capabilities, onChange: onChange)
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            guard repairing else { return }
            switch phase {
            case .done:
                repairing = false
                refresh()
            case .failed:
                // Sign-in couldn't finish on its own: show the sheet, which explains what went wrong.
                repairing = false
                showSetup = true
            case .idle, .checkingCLI, .waiting, .waitingForCLI:
                break
            }
        }
        .onChange(of: mcpSignIn.phase) { _, phase in
            guard repairing, connector.id != "github" else { return }
            switch phase {
            case .done:
                // Signed in on the service's own page: the expired key has had its day, the sign-in takes over.
                repairing = false
                for field in connector.configFields where field.secret {
                    Keychain.write("", account: field.account)
                }
                refresh()
            case .failed(_, let message):
                repairing = false
                repairFailure = message
            case .idle:
                repairing = false
            case .connecting:
                break
            }
        }
    }

    private func repair() {
        guard repairsInPlace else {
            showSetup = true
            return
        }
        repairing = true
        repairFailure = nil
        if let signInService, connector.id != "github" {
            mcpSignIn.connect(signInService, app: app)
        } else {
            gitHubSignIn.reconnect()
        }
    }

    private func setOn(_ on: Bool) {
        isOn = on
        ConnectorToggle.set(connector.id, on)
        refresh()
    }

    private func refresh() {
        let target = connector
        let done = onChange
        Task { @MainActor in
            await target.refresh()
            done()
        }
    }
}

// MARK: - Link row (not connected yet)

private struct ServiceLinkRow<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    let capabilities: String
    let onChange: () -> Void
    @State private var showSetup = false

    var body: some View {
        ServiceRowLayout(domain: connector.iconDomain, symbol: connector.symbol, tint: connector.accent, title: connector.title,
                         detail: ServiceState.tagline(connector.id) + " · " + tr("connect.method.key"),
                         status: .notLinked, source: connector.id) {
            Button(tr("connect.connect")) { showSetup = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .sheet(isPresented: $showSetup, onDismiss: onChange) {
            ServiceSetupSheet(connector: connector, capabilities: capabilities, onChange: onChange)
        }
    }
}

// MARK: - Card (not connected yet)

private struct ServiceCard<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    let capabilities: String
    let onChange: () -> Void
    @State private var showSetup = false

    var body: some View {
        GalleryCard(title: connector.title, detail: ServiceState.tagline(connector.id)) {
            ServiceTile(domain: connector.iconDomain, fallback: connector.symbol, tint: connector.accent, size: 34, source: connector.id)
        } accessory: {
            Text(tr("connector.link"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(NookTheme.iris)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(NookTheme.iris.opacity(0.14)))
        } action: {
            showSetup = true
        }
        .sheet(isPresented: $showSetup, onDismiss: onChange) {
            ServiceSetupSheet(connector: connector, capabilities: capabilities, onChange: onChange)
        }
    }
}

// MARK: - Setup and manage sheet

/// Everything about one service in one place. Not connected yet: three numbered steps (get a key, paste it, done).
/// Connected: how it's doing, the on/off switch, replacing the key, extra accounts, and disconnecting.
private struct ServiceSetupSheet<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    let capabilities: String
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared

    /// Whether the sheet opened on an already connected service: then it's the manage view, otherwise the steps stay
    /// visible until the sheet closes, so the user sees step 3 turn green.
    @State private var startedConnected: Bool?
    @State private var isOn = true
    @State private var configured = false
    @State private var drafts: [String: String] = [:]
    /// Which secret fields already have a value stored in the Keychain.
    @State private var stored: Set<String> = []
    @State private var note = ""
    @State private var replacing = false
    @State private var confirmDisconnect = false
    @State private var showKeySteps = false

    private var health: ConnectionHealth { ServiceState.health(of: connector, configured: configured, isOn: isOn) }
    private var isGitHub: Bool { connector.id == "github" }
    private var managing: Bool { startedConnected ?? false }

    var body: some View {
        SetupSheet(
            title: connector.title,
            subtitle: managing ? ServiceState.summary(of: connector, health: health) : tr("settings2.service.connectSubtitle", connector.title)
        ) {
            ServiceTile(domain: connector.iconDomain, fallback: connector.symbol, tint: connector.accent, size: 48, source: connector.id)
        } content: {
            if managing { manageContent } else { connectContent }
            capabilityNote
        } footer: {
            if configured {
                if confirmDisconnect {
                    Text(tr("settings2.service.disconnectConfirm"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(tr("button.cancel")) { confirmDisconnect = false }
                    Button(tr("settings2.disconnect"), role: .destructive) { clear() }
                } else {
                    Button(tr("settings2.disconnect"), role: .destructive) { confirmDisconnect = true }
                }
            }
            Spacer()
            Button(health == .working ? tr("settings2.done") : tr("button.close")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .onAppear {
            load()
            if startedConnected == nil { startedConnected = configured }
            if case .error = connector.status.state, (connector.status.errorKind ?? .other).needsReconnect { replacing = true }
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            guard isGitHub, phase == .done else { return }
            load()
            refreshNow()
        }
    }

    // MARK: Connect (three steps)

    @ViewBuilder
    private var connectContent: some View {
        if isGitHub && GitHubSignIn.isAvailable {
            VStack(alignment: .leading, spacing: 10) {
                gitHubSignInButton
                Text(tr("settings2.github.easy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: $showKeySteps) {
                VStack(alignment: .leading, spacing: 20) { keySteps }
                    .padding(.top, 12)
            } label: {
                Text(tr("settings2.github.useToken")).font(.callout)
            }
            if configured { resultStep(number: 1) }
        } else if isGitHub {
            ghCLIButton
            DisclosureGroup(isExpanded: $showKeySteps) {
                VStack(alignment: .leading, spacing: 20) { keySteps }
                    .padding(.top, 12)
            } label: {
                Text(tr("settings2.github.useToken")).font(.callout)
            }
            if configured { resultStep(number: 1) }
        } else {
            keySteps
        }
    }

    /// Takes over the login of the GitHub CLI, for when there is no OAuth app to sign in with.
    @ViewBuilder
    private var ghCLIButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { gitHubSignIn.reconnect() } label: {
                Label(configured ? tr("connector.relinkGitHub") : tr("connector.useGitHubCLI"), systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(gitHubSignIn.phase == .checkingCLI || gitHubSignIn.phase == .waitingForCLI)
            if gitHubSignIn.phase == .waitingForCLI {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("connector.githubFinishLogin")).font(.caption)
                }
            } else if case .failed(let message) = gitHubSignIn.phase {
                Text(message).font(.caption).foregroundStyle(.red)
            } else {
                Text(tr("connector.useGitHubCLIHint")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var keySteps: some View {
        SetupStep(number: 1, title: connector.signupURL != nil ? tr("settings2.step.getKey", connector.title) : tr("settings2.step.findInfo"),
                  done: configured) {
            Text(connector.helpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = connector.signupURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label(tr("settings2.openSite", connector.title), systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)
            }
        }
        SetupStep(number: 2, title: tr("settings2.step.paste"), done: configured) {
            fieldsAndPaste
        }
        resultStep(number: 3)
    }

    private func resultStep(number: Int) -> some View {
        SetupStep(number: number, title: tr("settings2.step.check"), done: health == .working) {
            resultView
        }
    }

    @ViewBuilder
    private var resultView: some View {
        switch health {
        case .notLinked:
            Text(tr("settings2.step.checkWaiting"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .busy:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(tr("settings2.step.checkBusy")).font(.callout)
            }
        case .working, .needsYou:
            Label(tr("settings2.step.checkOK", connector.title), systemImage: "checkmark.seal.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(ConnectionHealth.working.color)
        case .broken, .off:
            VStack(alignment: .leading, spacing: 6) {
                Label(ServiceState.summary(of: connector, health: health), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(ConnectionHealth.broken.color)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("connector.retry")) { refreshNow() }
            }
        }
    }

    // MARK: Manage

    @ViewBuilder
    private var manageContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HealthPill(health: health)
                Spacer()
                if health == .broken {
                    Button(tr("connector.retry")) { refreshNow() }
                }
            }
            SettingToggle(tr("settings2.service.useToggle"), detail: tr("settings2.service.useToggleDetail"),
                          isOn: Binding(get: { isOn }, set: { setOn($0) }))
                .toggleStyle(.switch)
        }

        Divider()

        VStack(alignment: .leading, spacing: 10) {
            Text(tr("settings2.service.keyTitle")).font(.headline)
            if replacing && isGitHub {
                if GitHubSignIn.isAvailable { gitHubSignInButton } else { ghCLIButton }
                DisclosureGroup(isExpanded: $showKeySteps) {
                    fieldsAndPaste.padding(.top, 8)
                } label: {
                    Text(tr("settings2.github.useToken")).font(.callout)
                }
            } else if replacing || connector.configFields.contains(where: { !$0.secret }) {
                fieldsAndPaste
            } else {
                HStack {
                    Label(tr("settings2.service.keySafe"), systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("settings2.service.replaceKey")) { withAnimation { replacing = true } }
                }
            }
        }

        if isGitHub {
            ExtraAccountsView(service: "github", field: "token", placeholder: "ghp_… / github_pat_…") { refreshNow() }
        }
    }

    @ViewBuilder
    private var capabilityNote: some View {
        if !capabilities.isEmpty {
            DisclosureGroup {
                Text(capabilities)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Label(tr("settings2.service.whatCanNook"), systemImage: "questionmark.circle")
                    .font(.callout)
            }
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var fieldsAndPaste: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(connector.configFields, id: \.account) { field in
                VStack(alignment: .leading, spacing: 4) {
                    if connector.configFields.count > 1 {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                    }
                    fieldRow(field)
                }
            }
            HStack {
                if connector.configFields.contains(where: \.secret) {
                    Button { pasteFromClipboard() } label: {
                        Label(tr("button.pasteClipboard"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(tr("button.save")) { save() }
                    .disabled(!hasDraft)
                Spacer()
            }
            if !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: ConnectorField) -> some View {
        let binding = Binding<String>(
            get: { drafts[field.account] ?? "" },
            set: { new in
                let old = drafts[field.account] ?? ""
                drafts[field.account] = new
                // Pasting inserts a large chunk of text at once: save immediately without requiring extra button clicks.
                if new.count - old.count >= 8 { save() }
            }
        )
        if field.secret {
            SecureField(field.label, text: binding,
                        prompt: Text(stored.contains(field.account) ? tr("connector.savedInKeychain") : field.placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { save() }
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .onSubmit { save() }
        }
    }

    // MARK: One-Click GitHub

    @ViewBuilder
    private var gitHubSignInButton: some View {
        switch gitHubSignIn.phase {
        case .waiting(let code, let uri):
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("connector.githubCodeHint"))
                    .font(.callout)
                Text(code)
                    .font(.system(.title, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    Button(tr("connector.reopenGitHub")) { NSWorkspace.shared.open(uri) }
                    Button(tr("button.cancel")) { gitHubSignIn.cancel() }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.iris.opacity(0.1)))
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button(tr("button.tryAgain")) { gitHubSignIn.start() }
            }
        case .idle, .checkingCLI, .waitingForCLI, .done:
            Button { gitHubSignIn.start() } label: {
                Label(configured ? tr("connector.relinkGitHub") : tr("connector.linkWithGitHub"), systemImage: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: Actions

    /// Takes text from the clipboard and saves it directly into the first secret field.
    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !ConnectorField.clean(text).isEmpty,
              let field = connector.configFields.first(where: { $0.secret }) ?? connector.configFields.first else {
            note = tr("connector.nothingOnClipboard")
            return
        }
        drafts[field.account] = text
        save()
    }

    private var hasDraft: Bool {
        connector.configFields.contains { field in
            let draft = ConnectorField.clean(drafts[field.account] ?? "")
            if field.secret { return !draft.isEmpty }
            return draft != (CloudHelp.secret(field.account) ?? "")
        }
    }

    private func load() {
        isOn = ConnectorToggle.isOn(connector.id)
        configured = connector.isConfigured
        var newStored: Set<String> = []
        var newDrafts: [String: String] = [:]
        for field in connector.configFields {
            let value = CloudHelp.secret(field.account)
            if field.secret {
                if value != nil { newStored.insert(field.account) }
            } else {
                newDrafts[field.account] = value ?? ""
            }
        }
        stored = newStored
        drafts = newDrafts
    }

    private func save() {
        var failed = false
        for field in connector.configFields {
            guard let draft = drafts[field.account] else { continue }
            let cleaned = ConnectorField.clean(draft)
            // An empty secret field means: keep the existing saved key.
            if field.secret && cleaned.isEmpty { continue }
            if Keychain.write(cleaned, account: field.account) != errSecSuccess { failed = true }
        }
        // A fresh key means the user wants to use it: switch the service on.
        if !failed && !isOn { ConnectorToggle.set(connector.id, true) }
        load()
        note = failed ? tr("connector.keychainDenied") : tr("connector.savedFetching")
        if !failed { replacing = false }
        refreshNow()
    }

    private func clear() {
        for field in connector.configFields {
            Keychain.write("", account: field.account)
        }
        load()
        confirmDisconnect = false
        note = tr("connector.keysCleared")
        refreshNow()
        dismiss()
    }

    private func setOn(_ on: Bool) {
        isOn = on
        ConnectorToggle.set(connector.id, on)
        refreshNow()
    }

    private func refreshNow() {
        let target = connector
        let done = onChange
        Task { @MainActor in
            await target.refresh()
            done()
        }
    }
}

// MARK: - Extra accounts

/// More accounts of the same service ("GitHub · Werk"): each with its own name and key. The first account is the one
/// configured above; these come on top of it.
struct ExtraAccountsView: View {
    let service: String
    let field: String
    let placeholder: String
    let onChange: () -> Void

    @State private var accounts: [ServiceAccount] = []
    @State private var newLabel = ""
    @State private var drafts: [String: String] = [:]
    @State private var primaryLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(tr("accounts.title")).font(.headline)
            HStack {
                TextField(tr("accounts.primaryName"), text: $primaryLabel, prompt: Text(tr("accounts.primaryPlaceholder")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { AccountRegistry.shared.rename(service, to: primaryLabel); onChange() }
                if let identity = AccountRegistry.shared.accounts(for: service).first?.identity {
                    Text(identity).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.label)
                        if let identity = account.identity { Text(identity).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(width: 120, alignment: .leading)
                    SecureField("", text: binding(account), prompt: Text(CloudHelp.secret(account.key(field)) == nil ? placeholder : tr("connector.savedInKeychain")))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(account) }
                    Button(tr("button.save")) { save(account) }
                        .disabled((drafts[account.id] ?? "").isEmpty)
                    Button(role: .destructive) { remove(account) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(tr("accounts.newName"), text: $newLabel, prompt: Text(tr("accounts.newPlaceholder")))
                    .textFieldStyle(.roundedBorder)
                Button(tr("accounts.add")) {
                    AccountRegistry.shared.add(service: service, label: newLabel)
                    newLabel = ""
                    load()
                }
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(tr("accounts.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear(perform: load)
    }

    private func binding(_ account: ServiceAccount) -> Binding<String> {
        Binding(get: { drafts[account.id] ?? "" }, set: { drafts[account.id] = $0 })
    }

    private func load() {
        let all = AccountRegistry.shared.accounts(for: service)
        primaryLabel = all.first?.label ?? ""
        accounts = Array(all.dropFirst())
    }

    private func save(_ account: ServiceAccount) {
        let value = ConnectorField.clean(drafts[account.id] ?? "")
        guard !value.isEmpty else { return }
        Keychain.write(value, account: account.key(field))
        drafts[account.id] = ""
        load()
        onChange()
    }

    private func remove(_ account: ServiceAccount) {
        Keychain.write("", account: account.key(field))
        AccountRegistry.shared.remove(account.id)
        load()
        onChange()
    }
}

/// Services Nook does not yet connect directly, explaining current alternatives.
struct NotYetBuiltIn {
    let name: String
    let how: String
    /// The websites whose icons stand for the services named, in the same order.
    let domains: [String]

    static var all: [NotYetBuiltIn] {
        [
            NotYetBuiltIn(name: "Slack", how: tr("notbuilt.slack"), domains: ["slack.com"]),
            NotYetBuiltIn(name: "Microsoft Teams", how: tr("notbuilt.teams"), domains: ["teams.microsoft.com"]),
            NotYetBuiltIn(name: "Gmail · Outlook · Exchange", how: tr("notbuilt.mail"), domains: ["mail.google.com", "outlook.com"]),
            NotYetBuiltIn(name: "Google Agenda · Outlook-agenda", how: tr("notbuilt.calendar"), domains: ["calendar.google.com", "outlook.com"]),
            NotYetBuiltIn(name: "Google Drive · OneDrive · SharePoint · Dropbox", how: tr("notbuilt.drive"),
                          domains: ["drive.google.com", "onedrive.live.com", "sharepoint.com", "dropbox.com"]),
            NotYetBuiltIn(name: "Linear · Jira · Todoist · GitLab", how: tr("notbuilt.tasks"),
                          domains: ["linear.app", "atlassian.com", "todoist.com", "gitlab.com"]),
            NotYetBuiltIn(name: "Discord · Telegram", how: tr("notbuilt.chat"), domains: ["discord.com", "telegram.org"])
        ]
    }
}
