import SwiftUI

/// Settings › Automation › Secret providers: how Nook reads `op://` references (1Password) where it takes a secret, the
/// secrets agents ask for and an MCP server's variables and headers. The 1Password CLI signs in through the app on this
/// Mac, a service account token, or a Connect server; the tokens are kept in Nook's keychain, and a value read through
/// them stays in memory only.
struct SecretProvidersSection: View {
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
        Section {
            LabeledContent(tr("secrets.providers.cli")) {
                Text(executable ?? tr("secrets.providers.cliMissing"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(executable == nil ? NookTheme.amber : NookTheme.textSecondary)
                    .textSelection(.enabled)
            }
            LabeledContent(tr("secrets.providers.mode")) {
                Text(modeText).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            }
            tokenField(tr("secrets.providers.serviceToken"), text: $serviceToken, stored: hasServiceToken,
                       account: SecretProviders.serviceAccountAccount)
            TextField(tr("secrets.providers.connectHost"), text: $connectHost, prompt: Text("https://op-connect.example.com"))
                .onSubmit { SecretProviders.connectHost = connectHost }
            tokenField(tr("secrets.providers.connectToken"), text: $connectToken, stored: hasConnectToken,
                       account: SecretProviders.connectTokenAccount)
            TextField(tr("secrets.providers.probe"), text: $probe, prompt: Text("op://vault/item/field"))
            HStack(spacing: NookTheme.Spacing.sm) {
                Button(tr("secrets.providers.test")) { test() }
                    .disabled(testing || executable == nil)
                if testing { ProgressView().controlSize(.small) }
                Spacer(minLength: 0)
            }
            if let result { SettingNote(result.text, tone: result.ok ? .success : .warning) }
        } header: {
            SettingsSectionTitle(tr("secrets.providers.title"), info: tr("secrets.providers.info"))
        }
        .task { await load() }
    }

    private var modeText: String {
        let config = OnePassword.Config(executable: executable, serviceAccountToken: hasServiceToken ? "set" : nil,
                                        connectHost: connectHost.isEmpty ? nil : connectHost,
                                        connectToken: hasConnectToken ? "set" : nil)
        switch config.mode {
        case .desktop: return tr("secrets.providers.mode.desktop")
        case .serviceAccount: return tr("secrets.providers.mode.serviceAccount")
        case .connect: return tr("secrets.providers.mode.connect")
        }
    }

    /// A token typed once: kept in the keychain on Return, never shown again; Remove forgets it.
    private func tokenField(_ title: String, text: Binding<String>, stored: Bool, account: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: NookTheme.Spacing.sm) {
                SecureField("", text: text, prompt: Text(stored ? tr("connector.savedInKeychain") : tr("secrets.providers.paste")))
                    .onSubmit { save(text, account: account) }
                if stored {
                    Button(tr("secrets.providers.remove")) {
                        SecretStore.remove(account)
                        Task { await load() }
                    }
                    .controlSize(.small)
                }
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

    /// What is set up, read off the main thread (the keychain and the file system).
    private func load() async {
        let found = await Task.detached(priority: .userInitiated) {
            (OnePassword.locate(), SecretStore.read(SecretProviders.serviceAccountAccount) != nil,
             SecretStore.read(SecretProviders.connectTokenAccount) != nil)
        }.value
        executable = found.0
        hasServiceToken = found.1
        hasConnectToken = found.2
    }

    /// Signs in the configured way (`op whoami`), or reads the reference typed above; the value read is dropped at once.
    private func test() {
        SecretProviders.connectHost = connectHost
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
