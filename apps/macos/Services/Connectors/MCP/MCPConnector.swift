import SwiftUI

/// The MCP servers the user added, stored without secrets (those go to the Keychain).
@MainActor
final class MCPServerStore: ObservableObject {
    static let shared = MCPServerStore()

    @Published private(set) var servers: [MCPServerConfig] = []
    private static let key = "mcpServers"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            let backup = NookPaths.supportDirectory.appendingPathComponent("mcpServers.json")
            servers = SafeStorage.decode(LossyArray<MCPServerConfig>.self, data: data, original: backup, skipped: { $0.skipped })
                .value?.elements ?? []
        }
    }

    /// Adds a server. `secrets` are environment variables (local program) or headers (https), stored in the Keychain.
    @discardableResult
    func add(name: String, transport: MCPServerConfig.Transport, secrets: [String: String],
             usesOAuth: Bool = false, serviceID: String? = nil) -> MCPServerConfig {
        var id = AccountRegistry.slug(name)
        var counter = 2
        while servers.contains(where: { $0.id == id }) {
            id = AccountRegistry.slug(name) + "\(counter)"
            counter += 1
        }
        var config = MCPServerConfig(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), transport: transport)
        config.usesOAuth = usesOAuth ? true : nil
        config.serviceID = serviceID
        for (secretName, value) in secrets where !secretName.isEmpty {
            Keychain.write(value, account: config.secretKey(secretName))
            config.secretNames.append(secretName)
        }
        servers.append(config)
        save()
        return config
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].enabled = enabled
        save()
    }

    func remove(_ id: String) {
        guard let config = servers.first(where: { $0.id == id }) else { return }
        for name in config.secretNames { Keychain.write("", account: config.secretKey(name)) }
        MCPOAuthStore.remove(id)
        servers.removeAll { $0.id == id }
        save()
    }

    func secrets(for config: MCPServerConfig) -> [String: String] {
        var result: [String: String] = [:]
        for name in config.secretNames {
            if let value = Keychain.read(config.secretKey(name)), !value.isEmpty { result[name] = value }
        }
        return result
    }

    /// "KEY=value" lines, as pasted from a server's README, into names and values.
    static func parseSecrets(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let separator = trimmed.firstIndex(of: "=") ?? trimmed.firstIndex(of: ":")
            guard let separator else { continue }
            let name = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !name.isEmpty, !value.isEmpty { result[name] = value }
        }
        return result
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// One MCP server as a Nook connection. Its read-only tools run during an answer; every other tool is an action that
/// waits for the user's approval, exactly like Nook's own actions.
@MainActor
final class MCPConnector: ContextSource, ObservableObject {
    let config: MCPServerConfig
    let symbol = "puzzlepiece.extension"
    let accent = Color(hex: 0x9EC5FF)
    @Published private(set) var status = ConnectorStatus()
    private var client: MCPClient?
    private var serverTools: [MCPTool] = []

    init(config: MCPServerConfig) {
        self.config = config
    }

    var id: String { config.sourceID }
    var title: String { config.name }
    var iconDomain: String? { SourceBrand.mcpDomain(name: config.name, transport: config.transport) }
    var isActive: Bool { config.enabled && ConnectorToggle.isOn(id) }
    var refreshInterval: TimeInterval { 900 }
    var toolCount: Int { serverTools.count }

    func refresh() async {
        guard isActive else {
            disconnect()
            status = ConnectorStatus(state: .off)
            return
        }
        if status.updated == nil { status.state = .loading }
        do {
            let client = try await connected()
            let tools = try await client.listTools()
            serverTools = tools
            SourceCatalog.register(SourceDescriptor(id: id, title: title, kind: .custom),
                                   tools: tools.map { MCPTool.nookName(server: config.id, tool: $0.name) })
            let reads = tools.filter(\.readOnly).count
            status = ConnectorStatus(
                state: .ok,
                headline: tr("mcp.status.tools", tools.count),
                detail: tr("mcp.status.split", reads, tools.count - reads),
                items: tools.prefix(12).map { ConnectorItem(id: $0.name, title: $0.title, subtitle: CloudHelp.short($0.description, 80),
                                                            tone: $0.readOnly ? .neutral : .attention) },
                updated: Date()
            )
        } catch {
            disconnect()
            status.state = .error(error.localizedDescription)
            status.errorKind = (error as? MCPOAuthError)?.connectorKind ?? ConnectorErrorKind.classify(error)
        }
    }

    func contextLines() -> [String] { [] }

    /// The readable name of one of this server's tools, by the name Nook gave it ("mcp_files_move_file" is "Move file").
    func title(ofTool name: String) -> String {
        serverTools.first { MCPTool.nookName(server: config.id, tool: $0.name) == name }?.title ?? name
    }

    var tools: [ToolSpec] {
        guard isActive else { return [] }
        let server = config.name
        return serverTools.map { tool in
            ToolSpec(
                name: MCPTool.nookName(server: config.id, tool: tool.name),
                description: "[\(server)] " + (tool.description.isEmpty ? tool.name : tool.description),
                schema: tool.inputSchema,
                kind: tool.readOnly ? .read : .action,
                summarize: { input in
                    let detail = input.sorted { $0.key < $1.key }.prefix(2)
                        .map { "\(McpToolName.readable($0.key)): \(CloudHelp.short("\($0.value)", 30))" }
                    return "\(server): \(tool.title)" + (detail.isEmpty ? "" : " · " + detail.joined(separator: ", "))
                },
                tag: { _ in tool.readOnly ? ("", .neutral) : ("MCP", .caution) },
                run: { [weak self] input in
                    guard let self else { throw NookError("\(server) is not connected.") }
                    return try await self.call(tool.name, input)
                }
            )
        }
    }

    private func call(_ name: String, _ input: [String: Any]) async throws -> String {
        guard isActive else { throw NookError("\(title) is switched off (Settings › Connections).") }
        do {
            return try await connected().callTool(name, arguments: input)
        } catch let error as MCPOAuthError {
            // Signed out or expired: starting again will not help; Settings offers "Sign in again".
            disconnect()
            status.state = .error(error.localizedDescription)
            status.errorKind = error.connectorKind
            throw error
        } catch {
            // A server that stopped is started again once.
            disconnect()
            return try await connected().callTool(name, arguments: input)
        }
    }

    private func connected() async throws -> MCPClient {
        if let client, client.initialized { return client }
        let secrets = MCPServerStore.shared.secrets(for: config)
        let transport: MCPTransport
        switch config.transport {
        case .stdio(let command, let arguments):
            transport = try MCPStdioTransport(command: command, arguments: arguments, environment: secrets)
        case .http(let address):
            guard let url = URL(string: address) else { throw NookError("Invalid address: \(address)") }
            transport = try MCPHTTPTransport(url: url, headers: secrets,
                                             authorizer: config.signsIn ? MCPOAuthAuthorizer(serverID: config.id) as MCPAuthorizer : nil)
        }
        let fresh = MCPClient(transport: transport)
        try await fresh.initialize()
        client = fresh
        return fresh
    }

    func disconnect() {
        client?.close()
        client = nil
    }
}
