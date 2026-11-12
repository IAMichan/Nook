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

    /// The setup sheet on its own: the steps while not connected, its management once it is (the Add sheet, and a row
    /// elsewhere that offers "Use a key instead").
    static func setupSheet(_ source: ContextSource, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        guard let config = source as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeSheet(config, capabilities: capabilities, onChange: onChange)
    }

    private static func makeSheet<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(ServiceSetupSheet(connector: connector, capabilities: capabilities, onChange: onChange))
    }

    private static func makeRow<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(ServiceRow(connector: connector, capabilities: capabilities, onChange: onChange))
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

    /// The row's state in the words every row of Settings › Accounts & connections uses.
    private var status: ServiceStatus { signingIn ? .connecting : health.status }

    /// The one connection row (`ConnectionRow`): icon, name with its state and one line, the switch (off keeps the key),
    /// and the "…" menu with Sign in again or Fix when it needs you and Disconnect last. Opening the row manages it in
    /// place: the key, the extra accounts and what Nook can do with it.
    var body: some View {
        ConnectionRow(title: connector.title, status: status,
                      detail: signingIn ? signingInDetail : repairFailure ?? ServiceState.summary(of: connector, health: health),
                      isOn: Binding(get: { isOn }, set: { setOn($0) }),
                      removal: ConnectionRemoval(title: tr("settings2.disconnect"),
                                                 question: tr("connect.disconnectTitle", connector.title),
                                                 detail: tr("connection.disconnectDetail", connector.title)) { disconnect() }) {
            ServiceTile(domain: connector.iconDomain, fallback: connector.symbol, tint: connector.accent, size: 28, source: connector.id)
        } menu: {
            if health == .broken || health == .needsYou, !signingIn {
                Button(repairsInPlace ? tr("connect.reauthorize") : tr("settings2.fix")) { repair() }
            }
            Button(tr("connector.retry")) { refresh() }
        } expanded: {
            ServiceSetupSheet(connector: connector, capabilities: capabilities, onChange: onChange)
        }
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

    /// Forgets the key (and any other field): the service is no longer linked and leaves the list.
    private func disconnect() {
        for field in connector.configFields {
            Keychain.write("", account: field.account)
        }
        ToastCenter.shared.success(tr("connection.disconnected", connector.title))
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

// MARK: - Setup and manage sheet

/// Everything about one service in one place. Not connected yet: three numbered steps (get a key, paste it, done).
/// Connected: how it's doing, the on/off switch, replacing the key, extra accounts, and disconnecting.
private struct ServiceSetupSheet<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    let capabilities: String
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sheetEmbedded) private var embedded
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    @StateObject private var keyCatcher = ClipboardKeyCatcher()

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
    @State private var showKeySteps = false

    private var health: ConnectionHealth { ServiceState.health(of: connector, configured: configured, isOn: isOn) }
    private var isGitHub: Bool { connector.id == "github" }
    private var managing: Bool { startedConnected ?? false }

    var body: some View {
        SetupSheet(
            title: connector.title,
            subtitle: managing ? ServiceState.summary(of: connector, health: health) : tr("settings2.service.connectSubtitle", connector.title),
            status: managing ? health : nil
        ) {
            ServiceTile(domain: connector.iconDomain, fallback: connector.symbol, tint: connector.accent, size: 48, source: connector.id)
        } content: {
            if managing { manageContent } else { connectContent }
            capabilityNote
        } footer: {
            if configured {
                ConfirmedButton(tr("settings2.disconnect"), question: tr("connect.disconnectTitle", connector.title),
                                detail: tr("confirm.keychain.detail")) { clear() }
            }
            Spacer()
            Button(tr("settings2.done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.nookProminent)
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

    /// Every service in numbered steps, as every connection sheet: GitHub signs in (step 1) and Nook checks it
    /// (step 2), with a token as the other way folded inside step 1; any other service gets its key (1), you paste it
    /// (2) and Nook checks it (3).
    @ViewBuilder
    private var connectContent: some View {
        if isGitHub {
            SetupStep(number: 1, title: tr("hub.signIn.step", connector.title), done: configured) {
                if GitHubSignIn.isAvailable {
                    gitHubSignInButton
                    SettingNote(tr("settings2.github.easy"))
                } else {
                    ghCLIButton
                }
                DisclosureGroup(isExpanded: $showKeySteps) {
                    tokenWay.padding(.top, NookTheme.Spacing.md)
                } label: {
                    Text(tr("settings2.github.useToken")).font(NookTheme.TextStyle.body)
                }
            }
            resultStep(number: 2, waiting: tr("settings2.step.checkAfterSignIn"))
        } else {
            keySteps
        }
    }

    /// A token instead of signing in, without steps of its own: it sits inside a step already.
    @ViewBuilder
    private var tokenWay: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(connector.helpText)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = connector.signupURL {
                Button {
                    NSWorkspace.shared.open(url)
                    keyCatcher.watch()
                } label: {
                    Label(tr("settings2.openSite", connector.title), icon: "arrow.up.forward.app")
                }
            }
            fieldsAndPaste
        }
    }

    /// Takes over the login of the GitHub CLI, for when there is no OAuth app to sign in with.
    @ViewBuilder
    private var ghCLIButton: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Button { gitHubSignIn.reconnect() } label: {
                Label(configured ? tr("connector.relinkGitHub") : tr("connector.useGitHubCLI"), icon: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.nookProminent)
            .controlSize(.large)
            .disabled(gitHubSignIn.phase == .checkingCLI || gitHubSignIn.phase == .waitingForCLI)
            if gitHubSignIn.phase == .waitingForCLI {
                HStack(spacing: NookTheme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text(tr("connector.githubFinishLogin")).font(NookTheme.TextStyle.detail)
                }
            } else if case .failed(let message) = gitHubSignIn.phase {
                SettingNote(message, tone: .error)
            } else {
                SettingNote(tr("connector.useGitHubCLIHint"))
            }
        }
    }

    @ViewBuilder
    private var keySteps: some View {
        SetupStep(number: 1, title: connector.signupURL != nil ? tr("settings2.step.getKey", connector.title) : tr("settings2.step.findInfo"),
                  done: configured) {
            if let url = connector.signupURL {
                StepAction(detail: connector.helpText, button: tr("settings2.openSite", connector.title)) {
                    NSWorkspace.shared.open(url)
                    keyCatcher.watch()
                }
                SettingNote(tr("brain.key.autoPaste"))
            } else {
                Text(connector.helpText)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        SetupStep(number: 2, title: tr("settings2.step.paste"), done: configured) {
            fieldsAndPaste
        }
        .onDisappear { keyCatcher.stop() }
        // perf: `caught` is set once per copied key and reset right after, so every value is a new key.
        .onReceive(keyCatcher.$caught.compactMap { $0 }) { key in
            // The key copied on the service's page, picked up on the way back. A service that needs only the key is
            // saved and checked at once; one that also needs an address waits for it.
            guard let field = connector.configFields.first(where: { $0.secret }) else { return }
            drafts[field.account] = key
            keyCatcher.caught = nil
            if connector.configFields.count == 1 { save() }
        }
        resultStep(number: 3)
    }

    /// The last step of every connection: Nook checks the link. `waiting` says what has to happen first.
    private func resultStep(number: Int, waiting: String = tr("settings2.step.checkWaiting")) -> some View {
        SetupCheckStep(number: number, detail: waiting, state: checkState,
                       check: health == .notLinked ? nil : { refreshNow() })
    }

    /// The check step's state, from how the service is doing.
    private var checkState: SetupCheckState {
        switch health {
        case .notLinked: return .idle
        case .busy: return .checking
        case .working, .needsYou: return .passed(tr("settings2.step.checkOK", connector.title))
        case .broken, .off: return .failed(ServiceState.summary(of: connector, health: health))
        }
    }

    // MARK: Manage

    /// The same parts, in the same order, as every sheet for something already linked: how it is doing, how it signs
    /// in, then its other accounts.
    @ViewBuilder
    private var manageContent: some View {
        SheetPart(tr("sheet.part.status")) {
            // How it is doing is the pill beside the title; here only what you can do about it.
            if health == .broken {
                StepAction(detail: ServiceState.summary(of: connector, health: health), button: tr("connector.retry"),
                           prominent: false) { refreshNow() }
            }
            // In a row the switch is the row's own; only the sheet shows it here.
            if !embedded {
                SettingToggle(tr("settings2.service.useToggle"), detail: tr("settings2.service.useToggleDetail"),
                              isOn: Binding(get: { isOn }, set: { setOn($0) }))
                    .toggleStyle(.switch)
            } else if health != .broken {
                SettingNote(ServiceState.summary(of: connector, health: health))
            }
        }

        SheetPart(tr("settings2.service.keyTitle")) {
            if replacing && isGitHub {
                if GitHubSignIn.isAvailable { gitHubSignInButton } else { ghCLIButton }
                DisclosureGroup(isExpanded: $showKeySteps) {
                    fieldsAndPaste.padding(.top, NookTheme.Spacing.md)
                } label: {
                    Text(tr("settings2.github.useToken")).font(NookTheme.TextStyle.body)
                }
            } else if replacing || connector.configFields.contains(where: { !$0.secret }) {
                fieldsAndPaste
            } else {
                StepAction(detail: tr("settings2.service.keySafe"), button: tr("settings2.service.replaceKey"), prominent: false) {
                    withAnimation { replacing = true }
                }
            }
        }

        if isGitHub {
            SheetPart(tr("chats.manage.accounts")) {
                ExtraAccountsView(service: "github", field: "token", placeholder: "ghp_… / github_pat_…") { refreshNow() }
            }
        }
    }

    @ViewBuilder
    private var capabilityNote: some View {
        // What Nook can do with it: a part of its own, last, as on every connection sheet.
        if !capabilities.isEmpty {
            SheetPart(tr("sheet.part.canDo")) { SettingNote(capabilities) }
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var fieldsAndPaste: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ForEach(connector.configFields, id: \.account) { field in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    if connector.configFields.count > 1 {
                        Text(field.label).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    }
                    fieldRow(field)
                }
            }
            HStack {
                if connector.configFields.contains(where: \.secret) {
                    Button { pasteFromClipboard() } label: {
                        Label(tr("button.pasteClipboard"), icon: "doc.on.clipboard")
                    }
                    .buttonStyle(.nookProminent)
                }
                Button(tr("button.save")) { save() }
                    .disabled(!hasDraft)
                Spacer()
            }
            if !note.isEmpty {
                SettingNote(note)
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
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Text(tr("connector.githubCodeHint"))
                    .font(NookTheme.TextStyle.body)
                Text(code)
                    .font(NookTheme.mono(22, .semibold))
                    .textSelection(.enabled)
                HStack {
                    Button(tr("connector.reopenGitHub")) { NSWorkspace.shared.open(uri) }
                    Button(tr("button.cancel")) { gitHubSignIn.cancel() }
                }
            }
            .padding(NookTheme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(NookTheme.iris.opacity(0.1), radius: NookTheme.Radius.card)
        case .failed(let message):
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Text(message)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coral)
                Button(tr("button.tryAgain")) { gitHubSignIn.start() }
            }
        case .idle, .checkingCLI, .waitingForCLI, .done:
            Button { gitHubSignIn.start() } label: {
                Label(configured ? tr("connector.relinkGitHub") : tr("connector.linkWithGitHub"), icon: "person.badge.key.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.nookProminent)
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
        // Shown inside the "Accounts" part of the sheet or row, which already names it.
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack {
                TextField(tr("accounts.primaryName"), text: $primaryLabel, prompt: Text(tr("accounts.primaryPlaceholder")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { AccountRegistry.shared.rename(service, to: primaryLabel); onChange() }
                if let identity = AccountRegistry.shared.accounts(for: service).first?.identity {
                    Text(identity).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            ForEach(accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(account.label).lineLimit(1)
                        // A login or address has no spaces to wrap at: cut in the middle instead of a letter per line.
                        if let identity = account.identity {
                            Text(identity).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .frame(width: 120, alignment: .leading)
                    SecureField("", text: binding(account), prompt: Text(CloudHelp.secret(account.key(field)) == nil ? placeholder : tr("connector.savedInKeychain")))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { save(account) }
                    Button(tr("button.save")) { save(account) }
                        .disabled((drafts[account.id] ?? "").isEmpty)
                    ConfirmedButton(symbol: "trash", title: tr("button.delete"), question: tr("confirm.remove", account.label),
                                    detail: tr("confirm.keychain.detail")) { remove(account) }
                        .labelled(tr("button.delete"))
                        .buttonStyle(.nookBorderless)
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
            SettingNote(tr("accounts.hint"))
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
            NotYetBuiltIn(name: "Gmail · Outlook · Exchange", how: tr("notbuilt.mail"), domains: ["mail.google.com", "outlook.com"]),
            NotYetBuiltIn(name: tr("notbuilt.calendar.name"), how: tr("notbuilt.calendar"), domains: ["calendar.google.com", "outlook.com"]),
            NotYetBuiltIn(name: "Google Drive · OneDrive · SharePoint · Dropbox", how: tr("notbuilt.drive"),
                          domains: ["drive.google.com", "onedrive.live.com", "sharepoint.com", "dropbox.com"]),
            // Linear and Jira are built in (they sign in under Services), and Discord links as a chat app.
            NotYetBuiltIn(name: "Todoist · Asana · Trello", how: tr("notbuilt.tasks"),
                          domains: ["todoist.com", "asana.com", "trello.com"])
        ]
    }
}
