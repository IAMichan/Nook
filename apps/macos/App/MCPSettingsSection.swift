import SwiftUI

/// Preset template for popular MCP servers so users can add them in one click.
struct MCPPreset: Identifiable {
    /// The tint of a server without a preset: the MCP mark's teal.
    static let genericTint = Color(hex: 0x1FA2C6)
    let id: String
    let iconDomain: String?
    let fallbackIcon: String
    let tint: Color
    let defaultCommand: String
    let requiredEnv: [String]
    let envLabels: [String: String]
    let envPlaceholders: [String: String]
    let helpURL: URL?
    /// The default command is the address of a server that is already running (Beeper Desktop), not a program to start.
    var isRemote = false
    /// Goes before the typed value, such as "Bearer " for an Authorization header.
    var envPrefixes: [String: String] = [:]

    var name: String { tr("mcp.preset.\(id).name") }
    var detail: String { tr("mcp.preset.\(id).detail") }

    /// A preset that works with something on the Mac shows that app's icon (the filesystem server: Finder).
    var appSource: String? { id == "filesystem" ? "files" : nil }

    /// Where the preset sits in the catalogue's categories.
    var category: ServiceCategory {
        switch id {
        case "filesystem": return .mac
        case "github", "postgres": return .development
        default: return .automation
        }
    }

    // No memory server here: memory is built into Nook (Settings › Memory), without Node or npx.
    // Computed, so the texts of the key fields follow the app language.
    static var all: [MCPPreset] {
        [
            MCPPreset(
                id: "filesystem",
                iconDomain: nil,
                fallbackIcon: "folder.fill",
                tint: Color(hex: 0x3478F6),
                defaultCommand: "npx -y @modelcontextprotocol/server-filesystem ~/Desktop ~/Documents ~/Downloads",
                requiredEnv: [],
                envLabels: [:],
                envPlaceholders: [:],
                helpURL: nil
            ),
            MCPPreset(
                id: "github",
                iconDomain: "github.com",
                fallbackIcon: "chevron.left.forwardslash.chevron.right",
                tint: .primary,
                defaultCommand: "npx -y @modelcontextprotocol/server-github",
                requiredEnv: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
                envLabels: ["GITHUB_PERSONAL_ACCESS_TOKEN": "GitHub Personal Access Token"],
                envPlaceholders: ["GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_..."],
                helpURL: URL(string: "https://github.com/settings/tokens/new")
            ),
            MCPPreset(
                id: "brave-search",
                iconDomain: "brave.com",
                fallbackIcon: "magnifyingglass",
                tint: Color(hex: 0xFF5500),
                defaultCommand: "npx -y @modelcontextprotocol/server-brave-search",
                requiredEnv: ["BRAVE_API_KEY"],
                envLabels: ["BRAVE_API_KEY": tr("mcp.preset.brave-search.key")],
                envPlaceholders: ["BRAVE_API_KEY": "BSA..."],
                helpURL: URL(string: "https://brave.com/search/api/")
            ),
            MCPPreset(
                id: "beeper",
                iconDomain: "beeper.com",
                fallbackIcon: "bubble.left.and.bubble.right.fill",
                tint: Color(hex: 0x6B5CE7),
                defaultCommand: "http://localhost:23373/v0/mcp",
                requiredEnv: ["Authorization"],
                envLabels: ["Authorization": tr("mcp.preset.beeper.key")],
                envPlaceholders: ["Authorization": tr("mcp.wizard.keyPrompt")],
                helpURL: URL(string: "https://developers.beeper.com/desktop-api/"),
                isRemote: true,
                envPrefixes: ["Authorization": "Bearer "]
            ),
            MCPPreset(
                id: "puppeteer",
                iconDomain: "pptr.dev",
                fallbackIcon: "safari.fill",
                tint: Color(hex: 0x00D69F),
                defaultCommand: "npx -y @modelcontextprotocol/server-puppeteer",
                requiredEnv: [],
                envLabels: [:],
                envPlaceholders: [:],
                helpURL: nil
            ),
            MCPPreset(
                id: "postgres",
                iconDomain: "postgresql.org",
                fallbackIcon: "cylinder.split.1x2.fill",
                tint: Color(hex: 0x336791),
                defaultCommand: "npx -y @modelcontextprotocol/server-postgres postgresql://localhost/mydb",
                requiredEnv: [],
                envLabels: [:],
                envPlaceholders: [:],
                helpURL: nil
            )
        ]
    }
}

/// What the Add MCP sheet opens with: a preset, or nothing for a pasted command.
struct MCPAddRequest: Identifiable {
    let preset: MCPPreset?
    var id: String { preset?.id ?? "custom" }
}

/// A preset in the catalogue of Settings › Connections: the same card as every other service, with the MCP badge.
struct MCPPresetCard: View {
    let preset: MCPPreset
    var add: (MCPAddRequest) -> Void

    var body: some View {
        GalleryCard(title: preset.name, detail: preset.detail) {
            ServiceTile(domain: preset.iconDomain, fallback: preset.fallbackIcon, tint: preset.tint, size: 34, source: preset.appSource)
        } accessory: {
            ConnectMethodBadge(method: .mcp)
        } action: {
            add(MCPAddRequest(preset: preset))
        }
    }
}

/// The last card of the catalogue: your own MCP server from a pasted command, config, or web address.
struct MCPCustomCard: View {
    var add: (MCPAddRequest) -> Void

    var body: some View {
        GalleryCard(title: tr("mcp.custom.button"), detail: tr("mcp.custom.detail")) {
            ServiceTile(domain: nil, fallback: "puzzlepiece.extension.fill", tint: MCPPreset.genericTint, size: 34)
        } accessory: {
            ConnectMethodBadge(method: .mcp)
        } action: {
            add(MCPAddRequest(preset: nil))
        }
    }
}

/// A server you added yourself, in the shared row shape: icon, name with its state, one line, the switch and a menu.
/// Clicking the row opens its details.
struct MCPServerCardRow: View {
    let config: MCPServerConfig
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = MCPServerStore.shared
    @State private var confirmRemove = false
    @State private var showDetails = false

    private var connector: MCPConnector? { app.connectors.source(id: config.sourceID) as? MCPConnector }

    private var status: ServiceStatus {
        guard config.enabled else { return .off }
        guard let connector else { return .notLinked }
        switch connector.status.state {
        case .ok: return .connected
        case .loading: return .connecting
        case .off: return .off
        case .error: return .unreachable
        }
    }

    private var detail: String {
        if let connector, connector.toolCount > 0, status == .connected {
            return tr("mcp.toolsCount", connector.toolCount) + " · " + summaryText
        }
        return summaryText
    }

    var body: some View {
        ServiceRowLayout(
            domain: SourceBrand.mcpDomain(name: config.name, transport: config.transport),
            symbol: "puzzlepiece.extension.fill", tint: MCPPreset.genericTint, title: config.name, detail: detail,
            status: status, detailIsError: status == .unreachable,
            source: SourceBrand.mcpAppSource(name: config.name, transport: config.transport)
        ) {
            Toggle("", isOn: Binding(get: { config.enabled }, set: { store.setEnabled(config.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Menu {
                Button {
                    showDetails = true
                } label: {
                    Label(tr("mcp.details.view"), systemImage: "info.circle")
                }
                Button {
                    if let connector { app.connectors.refresh(connector) }
                } label: {
                    Label(tr("button.refresh"), systemImage: "arrow.clockwise")
                }
                Divider()
                Button(role: .destructive) {
                    confirmRemove = true
                } label: {
                    Label(tr("mcp.remove"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tr("connect.manage", config.name))
        }
        .contentShape(Rectangle())
        .onTapGesture { showDetails = true }
        .confirmationDialog(tr("mcp.removeConfirm", config.name), isPresented: $confirmRemove) {
            Button(tr("mcp.remove"), role: .destructive) { store.remove(config.id) }
        }
        .sheet(isPresented: $showDetails) {
            MCPServerDetailSheet(config: config, connector: connector) {
                showDetails = false
            }
        }
    }

    private var summaryText: String {
        guard config.enabled else { return tr("settings2.health.off") }
        guard let connector else { return tr("connector.notYetFetched") }
        switch connector.status.state {
        case .off: return tr("connector.notYetFetched")
        case .loading: return tr("chat.plan.running")
        case .ok:
            if !connector.status.headline.isEmpty {
                return connector.status.headline
            }
            return tr("mcp.status.ready")
        case .error(let msg): return msg
        }
    }
}

/// Sheet showing tools and details of an installed MCP server.
private struct MCPServerDetailSheet: View {
    let config: MCPServerConfig
    let connector: MCPConnector?
    let done: () -> Void

    var body: some View {
        SetupSheet(
            title: config.name,
            subtitle: transportDescription
        ) {
            ServiceTile(
                domain: SourceBrand.mcpDomain(name: config.name, transport: config.transport),
                fallback: "puzzlepiece.extension.fill",
                tint: MCPPreset.genericTint,
                size: 48,
                source: SourceBrand.mcpAppSource(name: config.name, transport: config.transport)
            )
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("mcp.details.commandTitle")).font(NookTheme.TextStyle.strong)
                Text(rawTransportString)
                    .font(NookTheme.TextStyle.code)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.well))
                    .textSelection(.enabled)

                if let connector {
                    Text(tr("mcp.details.toolsTitle", connector.tools.count)).font(NookTheme.TextStyle.strong)
                        .padding(.top, 6)

                    if connector.tools.isEmpty {
                        Text(tr("mcp.details.noToolsFound"))
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textSecondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(connector.tools, id: \.name) { tool in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: tool.kind == .read ? "eye.fill" : "bolt.fill")
                                        .font(NookTheme.font(12))
                                        .foregroundStyle(tool.kind == .read ? NookTheme.mint : NookTheme.amber)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(connector.title(ofTool: tool.name))
                                            .font(NookTheme.TextStyle.strong)
                                        // The "[Server] " prefix is for the model; the sheet already names the server.
                                        Text(tool.description.replacingOccurrences(of: "[\(config.name)] ", with: ""))
                                            .font(NookTheme.TextStyle.detail)
                                            .foregroundStyle(NookTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Text(tool.kind == .read ? tr("mcp.tool.read") : tr("mcp.tool.action"))
                                        .font(NookTheme.TextStyle.label)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                                        .foregroundStyle(NookTheme.textSecondary)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(Color.primary.opacity(0.03)))
                            }
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            Button(tr("button.close"), action: done)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private var transportDescription: String {
        switch config.transport {
        case .stdio: return tr("mcp.kind.local")
        case .http: return tr("mcp.kind.remote")
        }
    }

    private var rawTransportString: String {
        switch config.transport {
        case .stdio(let cmd, let args): return ([cmd] + args).joined(separator: " ")
        case .http(let url): return url
        }
    }
}

/// Child-simple Add MCP Server wizard:
/// - One-click presets
/// - Paste full Claude/Cursor config or npx command (auto-detects and auto-fills!)
/// - Manual mode for advanced power users
struct AddMCPServerWizardSheet: View {
    let preset: MCPPreset?
    let done: () -> Void

    @ObservedObject private var store = MCPServerStore.shared
    @State private var name = ""
    @State private var commandOrURL = ""
    @State private var isRemote = false
    @State private var envDrafts: [String: String] = [:]
    @State private var rawSecrets = ""
    @State private var pasteError = ""
    @State private var problem = ""
    @State private var showAdvanced = false

    var body: some View {
        SetupSheet(
            title: preset != nil ? tr("mcp.wizard.presetTitle", preset!.name) : tr("mcp.add"),
            subtitle: preset?.detail ?? tr("mcp.wizard.subtitle")
        ) {
            ServiceTile(
                domain: preset?.iconDomain,
                fallback: preset?.fallbackIcon ?? "puzzlepiece.extension.fill",
                tint: preset?.tint ?? MCPPreset.genericTint,
                size: 48,
                source: preset?.appSource
            )
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                // Quick paste box if no preset was selected
                if preset == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(tr("mcp.wizard.smartPasteTitle")).font(NookTheme.TextStyle.strong)
                            Spacer()
                            Button {
                                pasteFromClipboard()
                            } label: {
                                Label(tr("button.pasteClipboard"), systemImage: "doc.on.clipboard")
                            }
                            .controlSize(.small)
                        }

                        Text(tr("mcp.wizard.smartPasteHelp"))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(Color(hex: 0x5ED6EE).opacity(0.1)))
                }

                // Step 1: Name
                SetupStep(number: 1, title: tr("mcp.wizard.stepName"), done: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                    TextField(tr("mcp.name"), text: $name, prompt: Text(tr("mcp.wizard.namePrompt")))
                        .textFieldStyle(.roundedBorder)
                }

                // Step 2: Command or URL
                SetupStep(number: 2, title: isRemote ? tr("mcp.address") : tr("mcp.command"), done: !commandOrURL.trimmingCharacters(in: .whitespaces).isEmpty) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            isRemote ? "https://..." : "npx -y ...",
                            text: $commandOrURL,
                            prompt: Text(isRemote ? "https://mcp.example.com/mcp" : "npx -y @modelcontextprotocol/server-github")
                        )
                        .textFieldStyle(.roundedBorder)

                        if preset == nil {
                            Picker("", selection: $isRemote) {
                                Text(tr("mcp.kind.local")).tag(false)
                                Text(tr("mcp.kind.remote")).tag(true)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }
                }

                // Step 3: API keys / environment variables if needed
                if let preset, !preset.requiredEnv.isEmpty {
                    SetupStep(number: 3, title: tr("mcp.wizard.stepKeys"), done: allRequiredEnvFilled) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(preset.requiredEnv, id: \.self) { key in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.envLabels[key] ?? key).font(NookTheme.TextStyle.label)
                                    SecureField(
                                        key,
                                        text: binding(for: key),
                                        prompt: Text(preset.envPlaceholders[key] ?? tr("mcp.wizard.keyPrompt"))
                                    )
                                    .textFieldStyle(.roundedBorder)
                                }
                            }

                            if let url = preset.helpURL {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    Label(tr("mcp.wizard.getKeySite"), systemImage: "arrow.up.forward.app")
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                } else if preset == nil {
                    // Optional environment variables for custom
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(isRemote ? tr("mcp.headers") : tr("mcp.env")).font(NookTheme.TextStyle.body)
                            TextEditor(text: $rawSecrets)
                                .font(NookTheme.mono(11))
                                .frame(height: 70)
                                .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.chip).stroke(NookTheme.textSecondary.opacity(0.3)))
                            Text(isRemote ? tr("mcp.headersHint") : tr("mcp.envHint"))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                        }
                        .padding(.top, 6)
                    } label: {
                        Text(tr("mcp.wizard.optionalEnv")).font(NookTheme.TextStyle.body)
                    }
                }

                if !problem.isEmpty {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.coral)
                }
            }
        } footer: {
            Button(tr("button.cancel"), action: done)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(tr("mcp.addButton"), action: add)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || commandOrURL.trimmingCharacters(in: .whitespaces).isEmpty || !allRequiredEnvFilled)
        }
        .onAppear {
            if let preset {
                name = preset.name
                commandOrURL = preset.defaultCommand
                isRemote = preset.isRemote
            }
        }
    }

    private var allRequiredEnvFilled: Bool {
        guard let preset, !preset.requiredEnv.isEmpty else { return true }
        return preset.requiredEnv.allSatisfy { key in
            !(envDrafts[key]?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { envDrafts[key] ?? "" },
            set: { envDrafts[key] = $0 }
        )
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        parsePastedInput(text)
    }

    /// Smart parser that automatically understands:
    /// 1. Claude desktop json (`{ "mcpServers": { "foo": { "command": "...", "args": [...] } } }`)
    /// 2. Single server json (`{ "command": "...", "args": [...] }`)
    /// 3. Direct command lines (`npx -y @modelcontextprotocol/server-...`)
    /// 4. Direct URLs (`https://...`)
    private func parsePastedInput(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Try JSON format
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var serverObj: [String: Any]? = json
            var autoName = ""

            if let mcpServers = json["mcpServers"] as? [String: Any], let firstKey = mcpServers.keys.first,
               let firstServer = mcpServers[firstKey] as? [String: Any] {
                autoName = firstKey
                serverObj = firstServer
            }

            if let serverObj {
                if let cmd = serverObj["command"] as? String {
                    var fullCmd = cmd
                    if let args = serverObj["args"] as? [String] {
                        fullCmd += " " + args.joined(separator: " ")
                    }
                    commandOrURL = fullCmd
                    isRemote = false
                } else if let url = serverObj["url"] as? String {
                    commandOrURL = url
                    isRemote = true
                }

                if let env = serverObj["env"] as? [String: String] {
                    var lines: [String] = []
                    for (k, v) in env { lines.append("\(k)=\(v)") }
                    rawSecrets = lines.joined(separator: "\n")
                    showAdvanced = true
                }

                if name.isEmpty {
                    name = autoName.isEmpty ? "MCP Server" : autoName.capitalized
                }
                return
            }
        }

        // Try HTTPS URL
        if trimmed.lowercased().hasPrefix("https://") {
            commandOrURL = trimmed
            isRemote = true
            if name.isEmpty, let host = URL(string: trimmed)?.host {
                name = host.capitalized
            }
            return
        }

        // Try command line
        commandOrURL = trimmed
        isRemote = false
        if name.isEmpty {
            if trimmed.contains("server-") {
                let parts = trimmed.components(separatedBy: "server-")
                if let candidate = parts.last?.components(separatedBy: CharacterSet.whitespaces).first {
                    name = candidate.capitalized
                }
            } else {
                name = "MCP Server"
            }
        }
    }

    private func add() {
        problem = ""
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let transport: MCPServerConfig.Transport

        if isRemote {
            guard let url = URL(string: commandOrURL.trimmingCharacters(in: .whitespaces)),
                  url.scheme?.lowercased() == "https" || url.host == "localhost" || url.host == "127.0.0.1", url.host != nil else {
                problem = tr("mcp.problem.https")
                return
            }
            transport = .http(url: url.absoluteString)
        } else {
            guard let parsed = MCPServerConfig.split(commandLine: commandOrURL) else {
                problem = tr("mcp.problem.command")
                return
            }
            transport = .stdio(command: parsed.command, arguments: parsed.arguments)
        }

        var secrets = MCPServerStore.parseSecrets(rawSecrets)
        for (k, v) in envDrafts where !v.isEmpty {
            secrets[k] = (preset?.envPrefixes[k] ?? "") + v.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        store.add(name: cleanName, transport: transport, secrets: secrets)
        done()
    }
}
