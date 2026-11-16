import Foundation

/// A connector (MCP server) the agent has but cannot use until you sign in to it: a claude.ai connector that was never
/// connected, or a server that asks for OAuth. Nook asks the agent for the sign-in page, opens it, and checks back until
/// the server connects.
struct ConnectorSignIn: Equatable, Identifiable, Sendable {
    /// The server's name as the agent reports it (`claude.ai Supabase`, `plugin:design:linear`): the agent takes it back
    /// as is.
    var name: String
    /// Its sign-in page is open and Nook waits for the server to connect.
    var waiting = false

    var id: String { name }

    /// The name as you know it: without the `claude.ai ` prefix or a plugin's path.
    var title: String { ConnectorSignIns.title(name) }

    /// The website whose icon is the connector's logo, wherever it is listed; nil shows the connector symbol.
    var iconDomain: String? { ConnectorDomains.connectorDomain(name: title) }
}

/// Which connectors need you, read from what each agent reports.
enum ConnectorSignIns {
    /// Claude Code: the `needs-auth` rows of `mcp_servers` (system/init) or of an `mcp_status` reply.
    static func claude(_ servers: Any?) -> [String] {
        ((servers as? [[String: Any]]) ?? []).compactMap { row in
            guard (row["status"] as? String) == "needs-auth", let name = row["name"] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    /// Codex app-server: the `mcpServerStatus/list` rows whose `authStatus` is `notLoggedIn`.
    static func codex(_ response: [String: Any]) -> [String] {
        ((response["data"] as? [[String: Any]]) ?? []).compactMap { row in
            guard (row["authStatus"] as? String) == "notLoggedIn", let name = row["name"] as? String, !name.isEmpty else { return nil }
            return name
        }
    }

    /// The new list, keeping which ones are waiting on their sign-in page.
    static func merged(_ names: [String], into current: [ConnectorSignIn]) -> [ConnectorSignIn] {
        let waiting = Set(current.filter(\.waiting).map(\.name))
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
            .map { ConnectorSignIn(name: $0, waiting: waiting.contains($0)) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Where an agent keeps its connector sign-ins: per agent, account (profile) and machine. Sessions with the same one
    /// share them.
    static func account(provider: RunProvider, profileID: String, machine: String?) -> String {
        [provider.rawValue, profileID, machine ?? ""].joined(separator: "|")
    }

    static func account(_ run: WorkspaceRun) -> String {
        account(provider: run.provider, profileID: run.profileID, machine: run.remote?.machineID)
    }

    static func title(_ name: String) -> String {
        if name.hasPrefix("claude.ai ") { return String(name.dropFirst("claude.ai ".count)) }
        if name.hasPrefix("plugin:"), let last = name.split(separator: ":").last { return String(last) }
        return name
    }

    // MARK: Dismissed

    private static let dismissedKey = "connectorSignIns.dismissed"

    /// Connectors you said you do not need: the row above the composer leaves them out (the session menu still lists them).
    static var dismissed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: dismissedKey) }
    }

    /// The ones the row above the composer shows.
    static func shown(_ all: [ConnectorSignIn], dismissed: Set<String>) -> [ConnectorSignIn] {
        all.filter { $0.waiting || !dismissed.contains($0.name) }
    }
}
