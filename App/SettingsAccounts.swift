import SwiftUI

/// Agent accounts in Settings: sign-in method, re-login, API key, default, remove, and adding a new account.
/// The notch only shows status and usage; everything about logging in lives here.
struct AccountsSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var adding: AgentKind?
    @State private var expanded: Set<String> = []

    var body: some View {
        ForEach(AgentKind.allCases) { kind in
            Section {
                ForEach(app.profiles.profiles(for: kind)) { profile in
                    AccountSettingsRow(profile: profile, isExpanded: binding(profile))
                }
                if kind == .gemini {
                    Text(tr("accounts.geminiSingle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if kind.supportsProfiles {
                    Button(tr("accounts.add")) { adding = kind }
                }
            } header: {
                Text(kind.name)
            }
        }
        .sheet(item: $adding) { kind in
            AddAccountSheet(kind: kind)
        }
    }

    private func binding(_ profile: AgentProfile) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(profile.id) },
            set: { if $0 { expanded.insert(profile.id) } else { expanded.remove(profile.id) } }
        )
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile
    @Binding var isExpanded: Bool
    @State private var name = ""
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false

    private var account: AgentAccount? { app.history.profileAccounts[profile.id] }
    private var several: Bool { app.profiles.profiles(for: profile.kind).count > 1 }
    private var title: String {
        let label = profile.label.isEmpty ? (account?.organization.isEmpty == false ? account!.organization : tr("agents.personal")) : profile.label
        return several || !profile.isDefault ? label : profile.kind.name
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
        } label: {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 10) {
            Image(systemName: account == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(account == nil ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if several && app.profiles.isPreferred(profile) {
                        Text(tr("agents.default"))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    @ViewBuilder
    private var content: some View {
        TextField(tr("agents.name"), text: $name, prompt: Text(profile.isDefault ? tr("agents.personal") : tr("agents.name")))
            .onSubmit { app.profiles.rename(profile.id, to: name) }
            .onAppear { name = profile.label }

        if profile.kind != .gemini {
            Picker(tr("accounts.method"), selection: Binding(
                get: { profile.auth ?? .cli },
                set: { method in
                    if method == .cli { app.useCLILogin(profile) } else { app.profiles.setAuth(profile.id, .apiKey) }
                }
            )) {
                Text(tr("accounts.method.cli")).tag(AgentAuthMethod.cli)
                Text(tr("accounts.method.apiKey")).tag(AgentAuthMethod.apiKey)
            }
            .pickerStyle(.segmented)

            if profile.usesAPIKey {
                keyRow
            } else {
                HStack {
                    Button(tr("accounts.reauth")) { app.reauthenticate(profile) }
                        .help(tr("accounts.reauthHelp"))
                    if account != nil {
                        Button(tr("accounts.logout")) { app.logout(profile) }
                            .help(tr("accounts.logoutHelp"))
                    }
                }
            }
            Text(tr(profile.kind == .claude ? "accounts.method.help.claude" : "accounts.method.help.codex"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }

        if several && !app.profiles.isPreferred(profile) {
            Button(tr("agents.makeDefault")) { app.makeDefault(profile) }
                .help(tr(profile.kind == .claude ? "agents.defaultHelpClaude" : "agents.defaultHelp"))
        }

        if !profile.isDefault {
            if confirmRemove {
                HStack {
                    Text(tr("agents.removeConfirm", profile.displayHome))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("button.cancel")) { confirmRemove = false }
                    Button(tr("agents.remove"), role: .destructive) { app.removeAccount(profile) }
                }
            } else {
                Button(tr("agents.removeAccount"), role: .destructive) { confirmRemove = true }
            }
        }
    }

    @ViewBuilder
    private var keyRow: some View {
        let stored = profile.kind == .claude ? app.profiles.hasAPIKey(profile) : account != nil
        if stored && key.isEmpty {
            HStack {
                Label(tr("accounts.keyStored"), systemImage: "key.fill")
                    .foregroundStyle(.green)
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
        } else {
            HStack {
                SecureField(tr("accounts.keyPlaceholder"), text: $key)
                    .onSubmit(save)
                if saving {
                    ProgressView().controlSize(.small)
                } else {
                    Button(tr("accounts.saveKey"), action: save)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
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

/// Add an account: pick the name and how it signs in. Subscription opens Terminal to log in; an API key is stored right away.
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
        Form {
            Section {
                TextField(tr("agents.name"), text: $name, prompt: Text(tr("agents.addNamePrompt")))
                Picker(tr("accounts.method"), selection: $method) {
                    Text(tr("accounts.method.cli")).tag(AgentAuthMethod.cli)
                    Text(tr("accounts.method.apiKey")).tag(AgentAuthMethod.apiKey)
                }
                .pickerStyle(.segmented)
                if method == .apiKey {
                    SecureField(tr("accounts.keyPlaceholder"), text: $key)
                }
            } header: {
                Text(tr("agents.addTitle", kind.shortName))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tr(method == .cli ? (kind == .claude ? "agents.addHintClaude" : "agents.addHint") : "accounts.method.help.\(kind == .claude ? "claude" : "codex")"))
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }

            if !found.isEmpty {
                Section(tr("agents.foundOnMac")) {
                    ForEach(found, id: \.url) { item in
                        HStack {
                            Text(AgentProfile.tildePath(item.url.path)).font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(tr("agents.add")) {
                                app.addAccount(kind, label: AgentProfileStore.label(forFolder: item.url), home: item.url)
                                dismiss()
                            }
                        }
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button(tr("button.cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(method == .cli
                               ? (app.history.executables[kind] == nil ? tr("agents.installAndLogin") : tr("agents.addAndLogin"))
                               : tr("agents.add")) { add() }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAdd)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: found.isEmpty ? 330 : 440)
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
