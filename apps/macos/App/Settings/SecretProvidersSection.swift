import SwiftUI

/// Settings › Automation › Secret providers: how Nook reads `op://` references (1Password) where it takes a secret, the
/// secrets agents ask for and an MCP server's variables and headers. The page shows how 1Password signs in; setting it up
/// is a sheet of steps (`SecretProviderSheet`).
struct SecretProvidersSection: View {
    @State private var executable: String?
    @State private var mode: OnePassword.Config.Mode = .desktop
    @State private var showing = false

    var body: some View {
        Section {
            SettingsLinkRow(title: tr("secrets.providers.setUp"),
                            detail: executable == nil ? tr("secrets.providers.cliMissing") : SecretProviderSheet.modeText(mode),
                            state: executable == nil ? .todo : nil) {
                showing = true
            }
        } header: {
            SettingsSectionTitle(tr("secrets.providers.title"), info: tr("secrets.providers.info"))
        }
        .task { await load() }
        .sheet(isPresented: $showing, onDismiss: { Task { await load() } }) {
            SecretProviderSheet()
        }
    }

    private func load() async {
        let found = await SecretProviderSheet.read()
        executable = found.executable
        mode = found.config.mode
    }
}

/// Setting up 1Password in numbered steps: the CLI on this Mac, how it signs in (the app on this Mac, a service account
/// token, or a Connect server; the tokens are kept in Nook's keychain), and Nook checking it. A value read through it
/// stays in memory only.
struct SecretProviderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var executable: String?
    @State private var hasServiceToken = false
    @State private var hasConnectToken = false
    @State private var serviceToken = ""
    @State private var connectHost = SecretProviders.connectHost
    @State private var connectToken = ""
    @State private var probe = ""
    @State private var testing = false
    @State private var result: (text: String, ok: Bool)?

    var body: some View {
        SetupSheet(title: tr("secrets.providers.title"), subtitle: tr("secrets.providers.subtitle")) {
            ServiceTile(domain: "1password.com", fallback: "key.fill", tint: NookTheme.iris, size: 48)
        } content: {
            SetupStep(number: 1, title: tr("secrets.providers.cliStep"), done: executable != nil) {
                if let executable {
                    Text(executable)
                        .font(NookTheme.TextStyle.code)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                } else {
                    StepAction(detail: tr("secrets.providers.cliMissing"), button: tr("secrets.providers.lookAgain"),
                               prominent: false) { Task { await load() } }
                }
            }
            SetupStep(number: 2, title: tr("secrets.providers.signInStep"), done: hasServiceToken || hasConnectToken) {
                SettingNote(tr("secrets.providers.signInDetail"))
                tokenField(tr("secrets.providers.serviceToken"), text: $serviceToken, stored: hasServiceToken,
                           account: SecretProviders.serviceAccountAccount)
                labeled(tr("secrets.providers.connectHost")) {
                    TextField("", text: $connectHost, prompt: Text("https://op-connect.example.com").foregroundStyle(NookTheme.textTertiary))
                        .labelsHidden()
                        .settingsField()
                        .onSubmit { SecretProviders.connectHost = connectHost }
                }
                tokenField(tr("secrets.providers.connectToken"), text: $connectToken, stored: hasConnectToken,
                           account: SecretProviders.connectTokenAccount)
                labeled(tr("secrets.providers.probe")) {
                    TextField("", text: $probe, prompt: Text("op://vault/item/field").foregroundStyle(NookTheme.textTertiary))
                        .labelsHidden()
                        .settingsField()
                }
                SettingNote(tr("secrets.providers.mode") + ": " + Self.modeText(config.mode))
            }
            SetupCheckStep(number: 3, detail: tr("secrets.providers.checkDetail"), state: checkState,
                           check: { test() }, disabled: executable == nil || testing)
        } footer: {
            Spacer()
            Button(tr("settings2.done")) {
                saveAll()
                dismiss()
            }
            .sheetPrimaryButton()
        }
        .task { await load() }
    }

    /// How it signs in now, from what is set (tokens counted as set without reading them again).
    private var config: OnePassword.Config {
        OnePassword.Config(executable: executable, serviceAccountToken: hasServiceToken ? "set" : nil,
                           connectHost: connectHost.isEmpty ? nil : connectHost,
                           connectToken: hasConnectToken ? "set" : nil)
    }

    static func modeText(_ mode: OnePassword.Config.Mode) -> String {
        switch mode {
        case .desktop: return tr("secrets.providers.mode.desktop")
        case .serviceAccount: return tr("secrets.providers.mode.serviceAccount")
        case .connect: return tr("secrets.providers.mode.connect")
        }
    }

    private var checkState: SetupCheckState {
        if testing { return .checking }
        guard let result else { return .idle }
        return result.ok ? .passed(result.text) : .failed(result.text)
    }

    private func labeled<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(title).font(NookTheme.TextStyle.strong)
            field()
        }
    }

    /// A token typed once: kept in the keychain on Return (or Done), never shown again; Remove under it forgets it.
    private func tokenField(_ title: String, text: Binding<String>, stored: Bool, account: String) -> some View {
        labeled(title) {
            SecureField("", text: text, prompt: Text(stored ? tr("connector.savedInKeychain") : tr("secrets.providers.paste")).foregroundStyle(NookTheme.textTertiary))
                .labelsHidden()
                .settingsField()
                .onSubmit { save(text, account: account) }
            if stored {
                Button(tr("secrets.providers.remove")) {
                    SecretStore.remove(account)
                    result = nil
                    Task { await load() }
                }
                .controlSize(.small)
            }
        }
    }

    private func save(_ text: Binding<String>, account: String) {
        let value = text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        text.wrappedValue = ""
        guard !value.isEmpty else { return }
        SecretStore.write(value, account: account)
        result = nil
        Task { await load() }
    }

    /// What was typed but not saved with Return yet.
    private func saveAll() {
        save($serviceToken, account: SecretProviders.serviceAccountAccount)
        save($connectToken, account: SecretProviders.connectTokenAccount)
        SecretProviders.connectHost = connectHost
    }

    /// What is set up, read off the main thread (the keychain and the file system).
    static func read() async -> (executable: String?, config: OnePassword.Config) {
        await Task.detached(priority: .userInitiated) {
            let executable = OnePassword.locate()
            let service = SecretStore.read(SecretProviders.serviceAccountAccount) != nil
            let connect = SecretStore.read(SecretProviders.connectTokenAccount) != nil
            let host = SecretProviders.connectHost
            return (executable, OnePassword.Config(executable: executable, serviceAccountToken: service ? "set" : nil,
                                                   connectHost: host.isEmpty ? nil : host,
                                                   connectToken: connect ? "set" : nil))
        }.value
    }

    private func load() async {
        let found = await Self.read()
        executable = found.executable
        hasServiceToken = found.config.serviceAccountToken != nil
        hasConnectToken = found.config.connectToken != nil
    }

    /// Signs in the configured way (`op whoami`), or reads the reference typed above; the value read is dropped at once.
    private func test() {
        saveAll()
        let reference = probe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty, SecretReference(reference) == nil {
            result = (OnePassword.Failure.notReference.localizedMessage, false)
            return
        }
        testing = true
        result = nil
        Task {
            let config = await Task.detached(priority: .userInitiated) { SecretProviders.config() }.value
            do {
                let account = try await OnePassword.check(config: config, probe: SecretReference(reference),
                                                          runner: OnePassword.processRunner)
                result = (account.isEmpty ? tr("secrets.providers.testOK") : tr("secrets.providers.testOKAccount", account), true)
            } catch let failure as OnePassword.Failure {
                result = (failure.localizedMessage, false)
            } catch {
                result = (error.localizedDescription, false)
            }
            testing = false
        }
    }
}
