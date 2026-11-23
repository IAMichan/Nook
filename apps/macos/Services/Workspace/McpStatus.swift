import Foundation

/// `/mcp`: the agent's MCP servers and how each one is doing, as a line in the session you can open. An agent's own
/// `/mcp` is a screen in its terminal app (Claude Code without one only prints a count), so Nook asks the agent and
/// shows the list itself. A server that waits for you also goes to the sign-in row above the composer (`ConnectorSignIn`).
struct McpServerState: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable, CaseIterable {
        case connected, needsSignIn, failed, pending, disabled
    }

    var name: String
    var status: Status
    /// What went wrong, in the agent's words.
    var error: String? = nil

    var id: String { name }
    var title: String { ConnectorSignIns.title(name) }
}

enum McpStatus {
    /// The `tool` of the timeline event that holds a report.
    static let tool = "mcp"

    /// Claude Code: the `mcpServers` of an `mcp_status` reply (or system/init's `mcp_servers`).
    static func claude(_ servers: Any?) -> [McpServerState] {
        rows(servers).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let status: McpServerState.Status
            switch row["status"] as? String {
            case "connected": status = .connected
            case "needs-auth": status = .needsSignIn
            case "failed": status = .failed
            case "disabled": status = .disabled
            default: status = .pending
            }
            return McpServerState(name: name, status: status, error: text(row["error"]))
        }
    }

    /// Codex app-server: the rows of `mcpServerStatus/list`. Codex says whether you are signed in, not whether a server
    /// started, so a listed server that does not wait for you counts as connected.
    static func codex(_ response: [String: Any]) -> [McpServerState] {
        rows(response["data"]).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let waits = (row["authStatus"] as? String) == "notLoggedIn"
            return McpServerState(name: name, status: waits ? .needsSignIn : .connected, error: text(row["error"]))
        }
    }

    /// OpenCode's server: the rows of `GET /api/mcp`, `{name, status: {status, error}}`.
    static func openCode(_ response: Any?) -> [McpServerState] {
        rows((response as? [String: Any])?["data"]).compactMap { row in
            guard let name = row["name"] as? String, !name.isEmpty else { return nil }
            let state = row["status"] as? [String: Any]
            let status: McpServerState.Status
            switch state?["status"] as? String {
            case "connected": status = .connected
            case "needs_auth", "needs_client_registration": status = .needsSignIn
            case "failed": status = .failed
            case "disabled": status = .disabled
            default: status = .pending
            }
            return McpServerState(name: name, status: status, error: text(state?["error"]))
        }
    }

    /// The order the list shows: what needs you first, then what works, each by name.
    static func sorted(_ servers: [McpServerState]) -> [McpServerState] {
        let rank: [McpServerState.Status: Int] = [.failed: 0, .needsSignIn: 1, .pending: 2, .connected: 3, .disabled: 4]
        return servers.sorted {
            let (a, b) = (rank[$0.status] ?? 9, rank[$1.status] ?? 9)
            return a != b ? a < b : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// The line itself: how many servers there are and how many need you.
    static func summary(_ servers: [McpServerState]) -> String {
        guard !servers.isEmpty else { return tr("ws.mcp.none") }
        var parts = [tr("ws.mcp.count", servers.count)]
        for status in McpServerState.Status.allCases {
            let count = servers.filter { $0.status == status }.count
            if count > 0 { parts.append(tr("ws.mcp.status.\(status.rawValue).count", count)) }
        }
        return parts.joined(separator: " · ")
    }

    static func event(_ servers: [McpServerState]) -> RunEvent {
        let list = sorted(servers)
        let detail = (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) }
        return RunEvent(kind: .system, text: summary(list), tool: tool, detail: detail)
    }

    /// The servers of a report event.
    static func servers(in event: RunEvent) -> [McpServerState] {
        guard event.tool == tool, let data = event.detail?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([McpServerState].self, from: data)) ?? []
    }

    /// `/mcp` on its own asks Nook for the list; with words after it (`/mcp reconnect github`) it goes to the agent.
    static func isRequest(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "/mcp"
    }

    private static func rows(_ raw: Any?) -> [[String: Any]] { (raw as? [[String: Any]]) ?? [] }

    private static func text(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(300))
    }
}
