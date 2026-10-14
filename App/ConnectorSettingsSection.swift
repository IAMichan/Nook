import SwiftUI
import Security

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

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(connector.configFields, id: \.account) { field in
                    fieldRow(field)
                }
                Text(connector.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    if let url = connector.signupURL {
                        Link("Maak een sleutel", destination: url)
                            .font(.callout)
                    }
                    Spacer()
                    if configured {
                        Button("Wis") { clear() }
                    }
                    Button("Bewaar") { save() }
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
                Image(systemName: connector.symbol)
                    .foregroundStyle(connector.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.title)
                    Text(stateText)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("Aan", isOn: Binding(get: { isOn }, set: { setOn($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!configured)
            }
        }
        .onAppear { load() }
    }

    // MARK: Velden

    @ViewBuilder
    private func fieldRow(_ field: ConnectorField) -> some View {
        let binding = Binding<String>(
            get: { drafts[field.account] ?? "" },
            set: { drafts[field.account] = $0 }
        )
        if field.secret {
            SecureField(field.label, text: binding,
                        prompt: Text(stored.contains(field.account) ? "Bewaard in je Keychain" : field.placeholder))
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
        }
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
        if !configured { return "Niet ingesteld" }
        if !isOn { return "Uit" }
        switch connector.status.state {
        case .off: return "Nog niet opgehaald"
        case .loading: return "Bezig…"
        case .ok:
            let headline = connector.status.headline
            return headline.isEmpty ? "Verbonden" : headline
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
        note = failed ? "De Keychain weigerde de sleutel. Probeer het nog eens." : "Bewaard. Nook haalt de gegevens op…"
        refreshNow()
    }

    private func clear() {
        for field in connector.configFields {
            Keychain.write("", account: field.account)
        }
        load()
        note = "Sleutels gewist."
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
