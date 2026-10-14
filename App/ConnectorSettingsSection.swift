import SwiftUI
import Security
import AppKit

/// Rijen voor de online koppelingen (GitHub, Stripe…) in de instellingen. Zet hem in een `Section("Diensten")` binnen een Form.
struct CloudConnectorSettings: View {
    let connectors: [ContextSource]
    let onChange: () -> Void

    var body: some View {
        ForEach(connectors.indices, id: \.self) { index in
            CloudConnectorSettings.row(for: connectors[index], onChange: onChange)
        }
    }

    /// Opent het existential zodat de rij de koppeling kan observeren.
    private static func row(for connector: ContextSource, onChange: @escaping () -> Void) -> AnyView {
        guard let config = connector as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeRow(config, onChange: onChange)
    }

    private static func makeRow<C: CloudConnectorConfig>(_ connector: C, onChange: @escaping () -> Void) -> AnyView {
        AnyView(CloudConnectorRow(connector: connector, onChange: onChange))
    }
}

/// Eén koppeling: icoon, naam, status, aan/uit en (uitgeklapt) de velden voor de sleutel.
private struct CloudConnectorRow<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    let onChange: () -> Void

    @State private var expanded = false
    @State private var isOn = true
    @State private var configured = false
    @State private var drafts: [String: String] = [:]
    /// Welke geheime velden al een waarde in de Keychain hebben.
    @State private var stored: Set<String> = []
    @State private var note = ""
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if connector.id == "github" && GitHubSignIn.isAvailable {
                    gitHubSignInButton
                    Text(tr("connector.orPasteToken"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(connector.configFields, id: \.account) { field in
                    fieldRow(field)
                }
                Text(connector.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let url = connector.signupURL {
                        Link(tr("connector.createKey"), destination: url)
                            .font(.callout)
                    }
                    Spacer()
                    if !connector.configFields.isEmpty {
                        Button(tr("button.pasteClipboard")) { pasteFromClipboard() }
                    }
                    if configured {
                        Button(tr("button.clear")) { clear() }
                    }
                    Button(tr("button.save")) { save() }
                        .disabled(!hasDraft)
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                // De hele rij klapt open, niet alleen het pijltje: anders lijkt klikken op een dienst niets te doen.
                HStack(spacing: 10) {
                    SiteIcon(domain: connector.iconDomain, fallback: connector.symbol, tint: connector.accent, size: 20)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.title)
                        Text(stateText)
                            .font(.caption)
                            .foregroundStyle(stateColor)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { expanded.toggle() } }
                Toggle(tr("music.on"), isOn: Binding(get: { isOn }, set: { setOn($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!configured)
            }
        }
        .onAppear { load() }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            guard connector.id == "github", phase == .done else { return }
            load()
            refreshNow()
        }
    }

    // MARK: GitHub in één klik

    @ViewBuilder
    private var gitHubSignInButton: some View {
        switch gitHubSignIn.phase {
        case .waiting(let code, let uri):
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("connector.githubCodeHint"))
                    .font(.callout)
                Text(code)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                HStack {
                    Button(tr("connector.reopenGitHub")) { NSWorkspace.shared.open(uri) }
                    Spacer()
                    Button(tr("button.cancel")) { gitHubSignIn.cancel() }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button(tr("button.tryAgain")) { gitHubSignIn.start() }
            }
        case .idle, .done:
            Button(configured ? tr("connector.relinkGitHub") : tr("connector.linkWithGitHub")) { gitHubSignIn.start() }
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Velden

    @ViewBuilder
    private func fieldRow(_ field: ConnectorField) -> some View {
        let binding = Binding<String>(
            get: { drafts[field.account] ?? "" },
            set: { new in
                let old = drafts[field.account] ?? ""
                drafts[field.account] = new
                // Plakken zet in één keer veel tekst neer: dan bewaren we meteen, zonder extra knop.
                if new.count - old.count >= 8 { save() }
            }
        )
        if field.secret {
            SecureField(field.label, text: binding,
                        prompt: Text(stored.contains(field.account) ? tr("connector.savedInKeychain") : field.placeholder))
                .onSubmit { save() }
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .onSubmit { save() }
        }
    }

    /// Neemt wat er op het klembord staat, en bewaart het meteen in het eerste geheime veld.
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

    // MARK: Status

    private var stateText: String {
        if !configured { return tr("connector.notConfigured") }
        if !isOn { return tr("connect.status.off") }
        switch connector.status.state {
        case .off: return tr("connector.notYetFetched")
        case .loading: return tr("chat.plan.running")
        case .ok:
            let headline = connector.status.headline
            return headline.isEmpty ? tr("connect.status.connected") : headline
        case .error(let message): return message
        }
    }

    private var stateColor: Color {
        guard configured, isOn else { return .secondary }
        switch connector.status.state {
        case .error: return .red
        case .ok: return connector.status.needsAttention ? .orange : .secondary
        default: return .secondary
        }
    }

    // MARK: Acties

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
            // Een leeg geheim veld betekent: laat de bewaarde sleutel staan.
            if field.secret && cleaned.isEmpty { continue }
            if Keychain.write(cleaned, account: field.account) != errSecSuccess { failed = true }
        }
        load()
        note = failed ? tr("connector.keychainDenied") : tr("connector.savedFetching")
        refreshNow()
    }

    private func clear() {
        for field in connector.configFields {
            Keychain.write("", account: field.account)
        }
        load()
        note = tr("connector.keysCleared")
        refreshNow()
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
