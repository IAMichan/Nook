import SwiftUI

/// MCP servers in Settings › Connections: add one by command or address, see its tools, switch it off or remove it.
struct MCPSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MCPServerStore.shared
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(store.servers) { config in
                MCPServerRow(config: config)
            }
            Button {
                adding = true
            } label: {
                Label(tr("mcp.add"), systemImage: "plus")
            }
        } header: {
            Text(tr("mcp.title"))
        } footer: {
            Text(tr("mcp.footer"))
        }
        .sheet(isPresented: $adding) {
            AddMCPServerSheet { adding = false }
        }
    }
}

private struct MCPServerRow: View {
    let config: MCPServerConfig
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MCPServerStore.shared
    @State private var confirmRemove = false

    private var connector: MCPConnector? { app.connectors.source(id: config.sourceID) as? MCPConnector }

    var body: some View {
        let _ = app.connectors.revision
        HStack(spacing: 10) {
            SiteIcon(domain: connector?.iconDomain, fallback: "puzzlepiece.extension", tint: Color(hex: 0x9EC5FF), size: 20)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                Text(stateText).font(.caption).foregroundStyle(stateColor).lineLimit(2)
                Text(transportText).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button(tr("button.refresh")) {
                if let connector { app.connectors.refresh(connector) }
            }
            .controlSize(.small)
            Toggle("", isOn: Binding(get: { config.enabled }, set: { store.setEnabled(config.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help(tr("mcp.remove"))
        }
        .confirmationDialog(tr("mcp.removeConfirm", config.name), isPresented: $confirmRemove) {
            Button(tr("mcp.remove"), role: .destructive) { store.remove(config.id) }
        }
    }

    private var transportText: String {
        switch config.transport {
        case .stdio(let command, let arguments): return ([command] + arguments).joined(separator: " ")
        case .http(let url): return url
        }
    }

    private var stateText: String {
        guard config.enabled else { return tr("connect.status.off") }
        guard let connector else { return tr("connector.notYetFetched") }
        switch connector.status.state {
        case .off: return tr("connector.notYetFetched")
        case .loading: return tr("chat.plan.running")
        case .ok: return connector.status.headline + " · " + connector.status.detail
        case .error(let message): return message
        }
    }

    private var stateColor: Color {
        if case .error = connector?.status.state { return .red }
        return .secondary
    }
}

/// Adding a server: a local program (command line, as in the server's README) or an https address.
private struct AddMCPServerSheet: View {
    let done: () -> Void
    @ObservedObject private var store = MCPServerStore.shared
    @State private var name = ""
    @State private var remote = false
    @State private var command = ""
    @State private var address = ""
    @State private var secrets = ""
    @State private var problem = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("mcp.add")).font(.title3.weight(.semibold))
            Form {
                TextField(tr("mcp.name"), text: $name, prompt: Text("Linear"))
                Picker(tr("mcp.kind"), selection: $remote) {
                    Text(tr("mcp.kind.local")).tag(false)
                    Text(tr("mcp.kind.remote")).tag(true)
                }
                .pickerStyle(.segmented)
                if remote {
                    TextField(tr("mcp.address"), text: $address, prompt: Text("https://mcp.example.com/mcp"))
                } else {
                    TextField(tr("mcp.command"), text: $command, prompt: Text("npx -y @modelcontextprotocol/server-github"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(remote ? tr("mcp.headers") : tr("mcp.env")).font(.callout)
                    TextEditor(text: $secrets)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    Text(remote ? tr("mcp.headersHint") : tr("mcp.envHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Label(remote ? tr("mcp.warning.remote") : tr("mcp.warning.local"), systemImage: "exclamationmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !problem.isEmpty {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(tr("button.cancel"), action: done)
                Button(tr("mcp.addButton"), action: add)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (remote ? address.isEmpty : command.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func add() {
        let transport: MCPServerConfig.Transport
        if remote {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme?.lowercased() == "https", url.host != nil else {
                problem = tr("mcp.problem.https")
                return
            }
            transport = .http(url: url.absoluteString)
        } else {
            guard let parsed = MCPServerConfig.split(commandLine: command) else {
                problem = tr("mcp.problem.command")
                return
            }
            transport = .stdio(command: parsed.command, arguments: parsed.arguments)
        }
        store.add(name: name, transport: transport, secrets: MCPServerStore.parseSecrets(secrets))
        done()
    }
}
