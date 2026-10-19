import SwiftUI

/// Agent accounts in Settings: sign-in method, re-login, API key, default, remove, and adding a new account.
/// Designed to be crystal clear, intuitive, and child-simple.
struct AccountsSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var adding: AgentKind?
    @State private var editingProfile: AgentProfile?

    var body: some View {
        // ACP agents you added have a section of their own (pick from the registry, or enter a command).
        AcpAgentsSection()
        ForEach(AgentKind.allCases.filter { $0 != .acp }) { kind in
            Section {
                let profiles = app.profiles.profiles(for: kind)
                ForEach(profiles) { profile in
                    AgentAccountCardRow(profile: profile) {
                        editingProfile = profile
                    }
                }

                if kind == .gemini || kind == .antigravity {
                    Text(tr(kind == .gemini ? "accounts.geminiSingle" : "accounts.antigravitySingle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if kind.supportsProfiles {
                    Button {
                        adding = kind
                    } label: {
                        Label(tr("accounts.add"), systemImage: "plus")
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    AgentLogo(kind, size: 16)
                    Text(kind.name)
                }
            }
        }
        .sheet(item: $adding) { kind in
            AddAccountSheet(kind: kind)
        }
        .sheet(item: $editingProfile) { profile in
            ManageAccountSheet(profile: profile) {
                editingProfile = nil
            }
        }
    }
}

/// Clean row representing an agent profile / account
private struct AgentAccountCardRow: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile
    let onManage: () -> Void

    private var account: AgentAccount? { app.history.profileAccounts[profile.id] }
    private var several: Bool { app.profiles.profiles(for: profile.kind).count > 1 }

    private var title: String {
        let label = profile.label.isEmpty ? (account?.organization.isEmpty == false ? account!.organization : tr("agents.personal")) : profile.label
        return several || !profile.isDefault ? label : profile.kind.name
    }

    private var health: ConnectionHealth {
        if let progress = app.agentConnect[profile.id], progress.isBusy { return .busy }
        if account != nil { return .working }
        if app.history.executables[profile.kind] == nil { return .notLinked }
        return .needsYou
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onManage) {
                HStack(spacing: 12) {
                    AgentLogo(profile.kind, size: 28)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)

                            if several && app.profiles.isPreferred(profile) {
                                Text(tr("agents.default"))
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(health == .needsYou ? Color.orange : Color.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    HealthPill(health: health, text: healthText)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(account == nil ? tr("button.login") : tr("settings2.manage")) {
                onManage()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private var healthText: String? {
        if let progress = app.agentConnect[profile.id], progress.isBusy { return progress.text }
        if account != nil { return tr("connect.status.connected") }
        if app.history.executables[profile.kind] == nil { return tr("agents.notInstalled") }
        return tr("agents.notLoggedIn")
    }

    private var subtitle: String {
        if let progress = app.agentConnect[profile.id], progress.isBusy { return progress.text }
        guard let account else {
            return app.history.executables[profile.kind] == nil ? tr("agents.notInstalled") : tr("agents.notLoggedIn")
        }
        var parts = [profile.usesAPIKey ? tr("accounts.method.apiKey") : account.name]
        if !profile.usesAPIKey, !account.organization.isEmpty { parts.append(account.organization) }
        if !profile.isDefault { parts.append(profile.displayHome) }
        return parts.joined(separator: " · ")
    }
}

/// Manage sheet for an agent profile: child-simple actions
private struct ManageAccountSheet: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile
    let done: () -> Void

    @State private var name = ""
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false

    private var account: AgentAccount? { app.history.profileAccounts[profile.id] }
    private var several: Bool { app.profiles.profiles(for: profile.kind).count > 1 }

    var body: some View {
        SetupSheet(
            title: profile.kind.name,
            subtitle: subtitle
        ) {
            AgentLogo(profile.kind, size: 44)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr("agents.name")).font(.headline)
                    HStack {
                        TextField(profile.isDefault ? tr("agents.personal") : tr("agents.name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                        Button(tr("button.save")) {
                            app.profiles.rename(profile.id, to: name)
                        }
                        .disabled(name == profile.label || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if profile.kind != .gemini && profile.kind != .antigravity {
                    Divider()

                    // Method: subscription or API key
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("accounts.method")).font(.headline)
                        Picker("", selection: Binding(
                            get: { profile.auth ?? .cli },
                            set: { method in
                                if method == .cli { app.useCLILogin(profile) } else { app.profiles.setAuth(profile.id, .apiKey) }
                            }
                        )) {
                            Text(tr("accounts.method.cli")).tag(AgentAuthMethod.cli)
                            Text(tr("accounts.method.apiKey")).tag(AgentAuthMethod.apiKey)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if profile.usesAPIKey {
                            apiKeyView
                        } else {
                            cliAuthView
                        }

                        Text(tr(profile.kind == .claude ? "accounts.method.help.claude" : "accounts.method.help.codex"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if several && !app.profiles.isPreferred(profile) {
                    Divider()
                    Button {
                        app.makeDefault(profile)
                    } label: {
                        Label(tr("agents.makeDefault"), systemImage: "star")
                    }
                }
            }
        } footer: {
            if !profile.isDefault {
                if confirmRemove {
                    Text(tr("agents.removeConfirm", profile.displayHome))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(tr("button.cancel")) { confirmRemove = false }
                    Button(tr("agents.remove"), role: .destructive) {
                        app.removeAccount(profile)
                        done()
                    }
                } else {
                    Button(tr("agents.removeAccount"), role: .destructive) { confirmRemove = true }
                }
            }
            Spacer()
            Button(tr("settings2.done"), action: done)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .onAppear {
            name = profile.label
        }
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
        HStack(spacing: 12) {
            Button {
                app.reauthenticate(profile)
            } label: {
                Label(account == nil ? tr("button.login") : tr("accounts.reauth"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)

            if account != nil {
                Button(tr("accounts.logout")) {
                    app.logout(profile)
                }
            }
        }
    }

    @ViewBuilder
    private var apiKeyView: some View {
        let stored = profile.kind == .claude ? app.profiles.hasAPIKey(profile) : account != nil
        if stored && key.isEmpty {
            HStack {
                Label(tr("accounts.keyStored"), systemImage: "key.fill")
                    .foregroundStyle(Color.green)
                Spacer()
                if profile.kind == .claude {
                    Button(tr("accounts.removeKey")) {
                        app.profiles.setAPIKey("", for: profile)
                        app.history.refresh(minimumInterval: 0)
                    }
                } else {
                    Button(tr("accounts.logout")) { app.logout(profile) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
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

    private var found: [(kind: AgentKind, url: URL)] { app.profiles.discover().filter { $0.kind == kind } }
    private var canAdd: Bool { method == .cli || !key.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        SetupSheet(
            title: tr("agents.addTitle", kind.shortName),
            subtitle: tr(method == .cli ? (kind == .claude ? "agents.addHintClaude" : "agents.addHint") : "accounts.method.help.\(kind == .claude ? "claude" : "codex")")
        ) {
            AgentLogo(kind, size: 44)
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                SetupStep(number: 1, title: tr("agents.name"), done: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    TextField(tr("agents.addNamePrompt"), text: $name, prompt: Text(tr("agents.work")))
                        .textFieldStyle(.roundedBorder)
                }

                SetupStep(number: 2, title: tr("accounts.method"), done: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $method) {
                            Text(tr("accounts.method.cli")).tag(AgentAuthMethod.cli)
                            Text(tr("accounts.method.apiKey")).tag(AgentAuthMethod.apiKey)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        if method == .apiKey {
                            SecureField(tr("accounts.keyPlaceholder"), text: $key)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if !found.isEmpty {
                    Divider()
                    Text(tr("agents.foundOnMac")).font(.headline)
                    ForEach(found, id: \.url) { item in
                        HStack {
                            Text(AgentProfile.tildePath(item.url.path))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(tr("agents.add")) {
                                app.addAccount(kind, label: AgentProfileStore.label(forFolder: item.url), home: item.url)
                                dismiss()
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } footer: {
            Button(tr("button.cancel")) { dismiss() }
            Spacer()
            if saving {
                ProgressView().controlSize(.small)
            } else {
                Button(method == .cli
                       ? (app.history.executables[kind] == nil ? tr("agents.installAndLogin") : tr("agents.addAndLogin"))
                       : tr("agents.add")) { add() }
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
