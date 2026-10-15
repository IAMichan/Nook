import SwiftUI
import Security
import AppKit

/// Rows for online connectors (GitHub, Stripe, etc.) in settings. Place in a Section within a Form.
struct CloudConnectorSettings: View {
    let connectors: [ContextSource]
    /// One-line description of how the connector works and its capabilities, per id.
    var capabilities: (String) -> String = { _ in "" }
    let onChange: () -> Void

    var body: some View {
        ForEach(connectors.indices, id: \.self) { index in
            CloudConnectorSettings.row(for: connectors[index], capabilities: capabilities(connectors[index].id), onChange: onChange)
        }
    }

    /// Opens the existential so the row can observe the connector.
    private static func row(for connector: ContextSource, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        guard let config = connector as? any CloudConnectorConfig else { return AnyView(EmptyView()) }
        return makeRow(config, capabilities: capabilities, onChange: onChange)
    }

    private static func makeRow<C: CloudConnectorConfig>(_ connector: C, capabilities: String, onChange: @escaping () -> Void) -> AnyView {
        AnyView(CloudConnectorRow(connector: connector, capabilities: capabilities, onChange: onChange))
    }
}

/// A single connector: icon, title, status, toggle, and (expanded) credential fields.
private struct CloudConnectorRow<C: CloudConnectorConfig>: View {
    @ObservedObject var connector: C
    var capabilities: String = ""
    let onChange: () -> Void

    @State private var expanded = false
    @State private var isOn = true
    @State private var configured = false
    @State private var drafts: [String: String] = [:]
    /// Which secret fields already have a value stored in the Keychain.
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
                if !capabilities.isEmpty {
                    Text(capabilities)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                // Expanding the entire row, not just the chevron: makes tapping a service more intuitive.
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

    // MARK: - One-Click GitHub

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

    // MARK: - Fields

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
                .onSubmit { save() }
        } else {
            TextField(field.label, text: binding, prompt: Text(field.placeholder))
                .onSubmit { save() }
        }
    }

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

    // MARK: - Status

    private var stateText: String {
        if !configured { return tr("connector.notConfigured") }
        if !isOn { return tr("connect.status.off") }
        switch connector.status.state {
        case .off: return tr("connector.notYetFetched")
        case .loading: return tr("chat.plan.running")
        case .ok:
            let headline = connector.status.headline
            let base = headline.isEmpty ? tr("connect.status.connected") : headline
            // When it was last successful, providing a health indicator for the connection.
            return base + (connector.status.updated.map { " · " + tr("context.updated", NookDates.relative($0)) } ?? "")
        case .error(let message):
            return message + (connector.status.updated.map { " · " + tr("settings.connections.lastOK", NookDates.relative($0)) } ?? "")
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

    // MARK: - Actions

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

/// Services Nook does not yet connect directly, explaining current alternatives.
struct NotYetBuiltIn {
    let name: String
    let how: String

    static var all: [NotYetBuiltIn] {
        [
            NotYetBuiltIn(name: "Slack", how: tr("notbuilt.slack")),
            NotYetBuiltIn(name: "Microsoft Teams", how: tr("notbuilt.teams")),
            NotYetBuiltIn(name: "Gmail · Outlook · Exchange", how: tr("notbuilt.mail")),
            NotYetBuiltIn(name: "Google Agenda · Outlook-agenda", how: tr("notbuilt.calendar")),
            NotYetBuiltIn(name: "Google Drive · OneDrive · SharePoint · Dropbox", how: tr("notbuilt.drive")),
            NotYetBuiltIn(name: "Linear · Jira · Todoist · GitLab", how: tr("notbuilt.tasks")),
            NotYetBuiltIn(name: "Discord · Telegram", how: tr("notbuilt.chat"))
        ]
    }
}
