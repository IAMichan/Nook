import SwiftUI

/// Agent accounts in Settings › Agents, in the connection rows every list in Settings uses: one row per account of
/// every agent, which opens in place to manage it (name, sign-in method, re-login, API key), with Log in again, Make
/// default and Remove in its "…" menu, and "+ Add account" in the section's header.
struct AccountsSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var adding: AgentKind?
    /// The accounts there were as the Add sheet opened, so the one it added can be told apart once it closes.
    @State private var before: Set<String> = []
    /// The account just added: its row opens by itself, so signing in or naming it is right there.
    @State private var justAdded: String?

    /// Every account of every agent in one list, its agent's logo on each row. ACP agents you added follow in a section
    /// of their own (pick from the registry, or enter a command).
    var body: some View {
        let kinds = AgentKind.allCases.filter { $0 != .acp }
        let profiles = kinds.flatMap { app.profiles.profiles(for: $0) }
        // The agents that hold one account each (Antigravity) say so behind the ⓘ instead of under each.
        let info = kinds.compactMap(\.singleAccountNote).map { tr($0) }.joined(separator: "\n\n")
        Section {
            if profiles.isEmpty {
                ConnectionListEmpty(title: tr("accounts.empty.title"), detail: tr("accounts.empty.detail"))
            }
            ForEach(profiles) { profile in
                AgentAccountCardRow(profile: profile, startsOpen: profile.id == justAdded)
                    // The new row was drawn while the sheet was still open; a fresh identity lets it open by itself.
                    .id(profile.id == justAdded ? profile.id + ".added" : profile.id)
            }
        } header: {
            ConnectionListMenuHeader(title: tr("settings.agents.accounts"), info: info.isEmpty ? nil : info,
                                     add: tr("accounts.add")) {
                // Every agent with account folders (Claude Code, Codex, Gemini CLI): see AgentKind.homeVariable.
                ForEach(kinds.filter(\.supportsProfiles)) { kind in
                    Button { startAdding(kind) } label: { AgentName(kind) }
                }
            }
        }
        .sheet(item: $adding, onDismiss: noteAdded) { kind in
            AddAccountSheet(kind: kind)
        }
        AcpAgentsSection()
    }

    private var profileIDs: Set<String> {
        Set(AgentKind.allCases.filter { $0 != .acp }.flatMap { app.profiles.profiles(for: $0) }.map(\.id))
    }

    private func startAdding(_ kind: AgentKind) {
        before = profileIDs
        adding = kind
    }

    /// The sheet closed: when it added an account (it only closes on success or Cancel), say so and open its row.
    private func noteAdded() {
        guard let id = profileIDs.subtracting(before).first, let profile = app.profiles.profile(id: id) else { return }
        justAdded = id
        ToastCenter.shared.success(tr("connection.added", profile.label.isEmpty ? profile.kind.name : profile.label))
    }
}

/// The header of a list of connections whose Add first asks which kind ("+ Add account" › Claude Code, Codex, …):
/// `ConnectionListHeader` with a menu in place of its button, so adding stays in the same place and looks the same.
struct ConnectionListMenuHeader<Items: View>: View {
    let title: String
    var info: String? = nil
    let add: String
    @ViewBuilder var items: () -> Items

    var body: some View {
        HStack {
            SettingsSectionTitle(title, info: info)
            Spacer()
            Menu {
                items()
            } label: {
                Label(add, systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .controlSize(.small)
        }
    }
}

/// One agent account in the connection row: the agent's logo, the account's name, its state with whose account it is,
/// and in its "…" menu signing in (again), Make default, and Remove for an account Nook added. Opened, it shows what the
/// manage sheet used to: the name, how it signs in, the key.
private struct AgentAccountCardRow: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile
    var startsOpen = false

    private var account: AgentAccount? { app.history.profileAccounts[profile.id] }
    private var several: Bool { app.profiles.profiles(for: profile.kind).count > 1 }
    private var busy: Bool { app.agentConnect[profile.id]?.isBusy == true }

    private var title: String {
        let label = profile.label.isEmpty ? (account?.organization.isEmpty == false ? account!.organization : tr("agents.personal")) : profile.label
        return several || !profile.isDefault ? label : profile.kind.name
    }

    /// Antigravity's hooks may be set up while Nook holds no Google sign-in for it yet.
    private var antigravitySignedOut: Bool { profile.kind == .antigravity && app.antigravityUsage.noLogin }

    private var health: ConnectionHealth {
        if busy { return .busy }
        if !profile.isEnabled { return .off }
        if antigravitySignedOut { return .needsYou }
        if account != nil { return .working }
        if app.history.executables[profile.kind] == nil { return .notLinked }
        return .needsYou
    }

    var body: some View {
        ConnectionRow(title: title, status: health.status, statusText: healthText, detail: detail,
                      removal: removal, startsOpen: startsOpen) {
            // The account's own color as a badge on the agent's logo, as everywhere the logo shows (`AccountTag`).
            AgentLogo(profile.kind, size: 22)
                .accountBadge(AccountTag.badge(profile, app: app), size: 22, ring: NookTheme.rowRest)
        } menu: {
            if antigravitySignedOut {
                // Antigravity signs in right here, in your browser.
                Button(tr("button.login")) { app.connect(profile) }
                    .disabled(busy)
            } else if !profile.usesAPIKey {
                // Every agent signs in again its own way (`reauthenticate`); an account on a key has nothing to sign in to.
                Button(account == nil ? tr("button.login") : tr("accounts.reauth")) { app.reauthenticate(profile) }
                    .disabled(busy)
            }
            if several, !app.profiles.isPreferred(profile) {
                Button(tr("agents.makeDefault")) { app.makeDefault(profile) }
            }
        } expanded: {
            ManageAccountSheet(profile: profile)
        }
    }

    /// The account in the agent's default folder is the agent itself: it cannot be removed, only signed out of.
    private var removal: ConnectionRemoval? {
        guard !profile.isDefault else { return nil }
        let name = title
        return ConnectionRemoval(title: tr("agents.removeAccount"), question: tr("confirm.remove", name),
                                 detail: tr("accounts.remove.detail", profile.displayHome)) {
            app.removeAccount(profile)
            ToastCenter.shared.success(tr("connection.removed", name))
        }
    }

    /// Whose account it is, with "Default" in front when the agent has several.
    private var detail: String {
        let isDefault = several && app.profiles.isPreferred(profile)
        return [isDefault ? tr("agents.default") : nil, subtitle].compactMap { $0 }.joined(separator: " · ")
    }

    private var healthText: String? {
        if let progress = app.agentConnect[profile.id], progress.isBusy { return progress.text }
        if !profile.isEnabled { return tr("accounts.off") }
        if antigravitySignedOut { return tr("agents.notLoggedIn") }
        if account != nil { return tr("connect.status.connected") }
        if app.history.executables[profile.kind] == nil { return tr("agents.notInstalled") }
        return tr("agents.notLoggedIn")
    }

    /// Who is signed in (name, organization, where its files live); nil while nobody is, when the state says it all.
    private var subtitle: String? {
        if busy { return nil }
        guard let account else {
            return profile.isDefault ? nil : profile.displayHome
        }
        var parts = [profile.usesAPIKey ? tr("accounts.method.apiKey") : account.name]
        if !profile.usesAPIKey, !account.organization.isEmpty { parts.append(account.organization) }
        if !profile.isDefault { parts.append(profile.displayHome) }
        return parts.joined(separator: " · ")
    }
}

/// What an agent account's row shows once opened: its name, how it signs in, and its key. Drawn by `SetupSheet` inside
/// the row, so only its parts show, without a card around each.
private struct ManageAccountSheet: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile

    @State private var name = ""
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?

    private var account: AgentAccount? { app.history.profileAccounts[profile.id] }
    /// The account as stored now: the row opened with a copy, and a color picked here changes the stored one.
    private var current: AgentProfile { app.profiles.profile(id: profile.id) ?? profile }

    var body: some View {
        SetupSheet(
            title: profile.kind.name,
            subtitle: subtitle
        ) {
            AgentMark(agent: profile.kind.name, account: AccountTag.badge(current, app: app), size: 44)
        } content: {
            // The same parts as every sheet for something linked: the account, how it signs in, then its place in Nook.
            SheetPart(tr("agents.name")) {
                HStack {
                    TextField(profile.isDefault ? tr("agents.personal") : tr("agents.name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveName)
                    Button(tr("button.save"), action: saveName)
                        .disabled(!nameChanged)
                }
            }
            // Its own color, on the account's badge wherever the agent's logo shows (as accent color).
            SheetPart(tr("accounts.color")) {
                AccountColorPicker(accent: Binding(get: { current.accent },
                                                   set: { app.profiles.setAccent(profile.id, $0) }))
                SettingNote(tr("accounts.color.help"))
            }
            // Its own icon, centered on that badge instead of the first letter of its name.
            SheetPart(tr("accounts.icon")) {
                AccountIconPicker(icon: Binding(get: { current.icon }, set: { app.profiles.setIcon(profile.id, $0) }),
                                  tag: AccountTag.of(current, app: app))
                SettingNote(tr("accounts.icon.help"))
            }
            if profile.kind != .gemini && profile.kind != .antigravity {
                // Signing in with the agent's own login is the way; a key is only for whoever needs one, folded away.
                SheetPart(tr("accounts.method")) {
                    if profile.usesAPIKey {
                        apiKeyView
                        Button(tr("accounts.signInInstead")) { app.useCLILogin(profile) }
                    } else {
                        cliAuthView
                        DisclosureGroup(tr("settings.fold.keyInstead")) {
                            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                                SettingNote(tr(profile.kind == .claude ? "accounts.method.help.claude" : "accounts.method.help.codex"))
                                Button(tr("accounts.useKeyInstead")) { app.profiles.setAuth(profile.id, .apiKey) }
                            }
                            .padding(.top, NookTheme.Spacing.xs)
                        }
                    }
                }
            }
            if profile.kind == .antigravity {
                SheetPart(tr("accounts.method")) { antigravitySignInView }
            }
            AccountOptionsSection(profile: current)
            if let error {
                SettingNote(error, tone: .error)
            }
        } footer: {
            // Shown inside the account's row (`sheetEmbedded`), which has no buttons of its own: Make default and
            // Remove are in the row's "…" menu, and a typed name is saved as the row closes.
            EmptyView()
        }
        .onDisappear(perform: saveName)
        .onAppear {
            name = profile.label
        }
    }

    private var nameChanged: Bool {
        name != profile.label && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Renames the profile; also runs on Return and as the row closes, so a typed name is never lost.
    private func saveName() {
        guard nameChanged else { return }
        app.profiles.rename(profile.id, to: name)
    }

    private var subtitle: String {
        if let progress = app.agentConnect[profile.id], progress.isBusy { return progress.text }
        guard let account else {
            return app.history.executables[profile.kind] == nil ? tr("agents.notInstalled") : tr("agents.notLoggedIn")
        }
        return account.name.isEmpty ? tr("connect.status.connected") : account.name
    }

    @ViewBuilder
    private var cliAuthView: some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            Button {
                app.reauthenticate(profile)
            } label: {
                Label(account == nil ? tr("button.login") : tr("accounts.reauth"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)

            if account != nil {
                ConfirmedButton(tr("accounts.logout"), question: tr("confirm.logout", profile.kind.name)) {
                    app.logout(profile)
                }
            }
        }
    }

    /// Antigravity signs in through Nook, in your browser: the same sign-in its sessions and the usage overview use.
    @ViewBuilder
    private var antigravitySignInView: some View {
        let progress = app.agentConnect[profile.id]
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.lg) {
                Button {
                    app.reauthenticate(profile)
                } label: {
                    Label(app.antigravityUsage.noLogin ? tr("accounts.antigravitySignIn") : tr("accounts.reauth"),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(progress?.isBusy == true)

                if let progress, progress.isBusy {
                    ProgressView().controlSize(.small)
                    Text(progress.text).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                }
            }
            if case .failed(let message)? = progress {
                SettingNote(message, tone: .error)
            }
            SettingNote(tr("accounts.antigravitySignInHelp"))
        }
    }

    @ViewBuilder
    private var apiKeyView: some View {
        let stored = profile.kind == .claude ? app.profiles.hasAPIKey(profile) : account != nil
        if stored && key.isEmpty {
            HStack {
                Label(tr("accounts.keyStored"), systemImage: "key.fill")
                    .foregroundStyle(NookTheme.mint)
                Spacer()
                if profile.kind == .claude {
                    ConfirmedButton(tr("accounts.removeKey"), question: tr("confirm.removeKeyNamed", profile.kind.name), detail: tr("confirm.keychain.detail")) {
                        app.profiles.setAPIKey("", for: profile)
                        app.history.refresh(minimumInterval: 0)
                    }
                } else {
                    ConfirmedButton(tr("accounts.logout"), question: tr("confirm.logout", profile.kind.name)) { app.logout(profile) }
                }
            }
            .padding(NookTheme.Spacing.md)
            .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
        } else {
            HStack {
                SecureField(tr("accounts.keyPlaceholder"), text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button(tr("accounts.saveKey"), action: saveKey)
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func saveKey() {
        let value = key
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        saving = true
        error = nil
        Task {
            do {
                try await app.setAPIKey(value, for: profile)
                key = ""
            } catch let failure {
                error = failure.localizedDescription
            }
            saving = false
        }
    }
}

/// The colors an account can have: none (the badge keeps its personal/work/key look), a swatch, or one of your own.
private struct AccountColorPicker: View {
    @Binding var accent: UInt32?

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            swatch(nil, name: "accounts.color.none")
            ForEach(AccountTag.swatches, id: \.hex) { swatch($0.hex, name: $0.name) }
            Spacer(minLength: NookTheme.Spacing.md)
            ColorPicker(tr("accounts.color.custom"), selection: Binding(
                get: { AccountTag.color(accent ?? AccountTag.swatches[0].hex) },
                set: { accent = NSColor($0).nookHex }
            ), supportsOpacity: false)
            .labelsHidden()
            .help(tr("accounts.color.custom"))
        }
    }

    private func swatch(_ hex: UInt32?, name: String) -> some View {
        let selected = accent == hex
        return Button { accent = hex } label: {
            Group {
                if let hex {
                    Circle().fill(AccountTag.color(hex))
                } else {
                    // No color: an empty ring with a slash.
                    Circle().stroke(NookTheme.line2, lineWidth: 1.5)
                        .overlay(Image(icon: "slash.circle").font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary))
                }
            }
            .frame(width: 20, height: 20)
            .padding(NookTheme.Spacing.xs)
            .overlay(Circle().stroke(selected ? NookTheme.paper : Color.clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tr(name))
        .accessibilityLabel(tr(name))
        .accessibilityHint(tr("accounts.color"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The icons an account can have on its badge: none (the first letter of its name, or the personal/work/key symbol) or
/// one of `AccountTag.symbols`, each shown on the account's own badge so you see the result before you pick it.
private struct AccountIconPicker: View {
    @Binding var icon: String?
    /// The account's badge as it is now; each option shows it with that option's icon.
    let tag: AccountTag

    private let columns = [GridItem(.adaptive(minimum: 32, maximum: 36), spacing: NookTheme.Spacing.xs)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: NookTheme.Spacing.xs) {
            option(nil, name: "accounts.icon.none")
            ForEach(AccountTag.symbols, id: \.symbol) { option($0.symbol, name: $0.name) }
        }
    }

    private func option(_ symbol: String?, name: String) -> some View {
        let selected = icon == symbol
        var shown = tag
        shown.icon = symbol
        return Button { icon = symbol } label: {
            Group {
                if symbol == nil {
                    // No icon: an empty ring with a slash, as "no color".
                    Circle().stroke(NookTheme.line2, lineWidth: 1.5)
                        .overlay(Image(icon: "slash.circle").font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary))
                        .frame(width: 20, height: 20)
                } else {
                    AccountBadge(kind: shown, size: 20, ring: .clear)
                }
            }
            .padding(NookTheme.Spacing.xs)
            .overlay(Circle().stroke(selected ? NookTheme.paper : Color.clear, lineWidth: 1.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tr(name))
        .accessibilityLabel(tr(name))
        .accessibilityHint(tr("accounts.icon"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Add an account sheet: simple and guided
private struct AddAccountSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: AgentKind
    @State private var name = ""
    @State private var method: AgentAuthMethod = .cli
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?

    /// Folders with a login on this Mac not added yet; looked up once as the sheet opens, not on every redraw (it lists
    /// the home folder).
    @State private var found: [(kind: AgentKind, url: URL)] = []
    private var canAdd: Bool { method == .cli || !key.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        SetupSheet(
            title: tr("agents.addTitle", kind.shortName),
            subtitle: tr(method == .cli ? (kind == .claude ? "agents.addHintClaude" : "agents.addHint") : "accounts.method.help.\(kind == .claude ? "claude" : "codex")")
        ) {
            AgentLogo(kind, size: 44)
        } content: {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
                SetupStep(number: 1, title: tr("agents.name"), done: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    TextField(tr("agents.addNamePrompt"), text: $name, prompt: Text(tr("agents.work")))
                        .textFieldStyle(.roundedBorder)
                }

                // Step 2 is signing in with the agent's own login, in the browser, right after adding. A key instead is
                // folded away for whoever needs one.
                SetupStep(number: 2, title: tr("accounts.signInStep"), done: method == .apiKey && canAdd) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                        if method == .cli {
                            SettingNote(tr("accounts.signInStepDetail", kind.shortName))
                        }
                        // A key instead, for the agents Nook keeps one for (AgentKind.takesAPIKeyAccounts).
                        if kind.takesAPIKeyAccounts {
                            DisclosureGroup(isExpanded: Binding(get: { method == .apiKey },
                                                                set: { method = $0 ? .apiKey : .cli })) {
                                SecureField(tr("accounts.keyPlaceholder"), text: $key)
                                    .textFieldStyle(.roundedBorder)
                                    .padding(.top, NookTheme.Spacing.xs)
                            } label: {
                                Text(tr("accounts.useKeyInstead"))
                            }
                        }
                    }
                }

                if !found.isEmpty {
                    Divider()
                    Text(tr("agents.foundOnMac")).font(NookTheme.TextStyle.strong)
                    ForEach(found, id: \.url) { item in
                        HStack {
                            Text(AgentProfile.tildePath(item.url.path))
                                .font(NookTheme.TextStyle.code)
                            Spacer()
                            Button(tr("agents.add")) {
                                app.addAccount(kind, label: AgentProfileStore.label(forFolder: item.url), home: item.url)
                                dismiss()
                            }
                        }
                        .padding(NookTheme.Spacing.md)
                        .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.coral)
                }
            }
            .onAppear { found = app.profiles.discover().filter { $0.kind == kind } }
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            if saving {
                ProgressView().controlSize(.small)
            } else {
                Button(method == .cli
                       ? (app.history.executables[kind] == nil ? tr("agents.installAndLogin") : tr("agents.addAndLogin"))
                       : tr("agents.add")) { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canAdd)
            }
        }
    }

    private func add() {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = clean.isEmpty ? tr("agents.work") : clean
        if method == .cli {
            app.addAccount(kind, label: label)
            dismiss()
            return
        }
        saving = true
        error = nil
        Task {
            do {
                try await app.addAccount(kind, label: label, apiKey: key)
                dismiss()
            } catch let failure {
                error = failure.localizedDescription
            }
            saving = false
        }
    }
}
