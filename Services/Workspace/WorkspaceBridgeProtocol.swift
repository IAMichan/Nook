import Foundation

// The workspace bridge: Nook's own terminal, browser and pull requests as tools for coding agents.
// An agent reaches them through a small MCP server (`nook-mcp`, see WorkspaceBridgeScript) that forwards every request to
// Nook over a local socket. Nook decides what may happen directly and asks you for the rest.
// Everything in this file depends only on Foundation so tests can use it independently.

/// One tool of the bridge. The names are what the agent sees, prefixed by its MCP client (`mcp__nook__terminal_run`).
enum BridgeTool: String, CaseIterable, Sendable {
    case workspaceInfo = "workspace_info"
    case terminalRun = "terminal_run"
    case terminalRead = "terminal_read"
    case terminalList = "terminal_list"
    case terminalStop = "terminal_stop"
    case browserOpen = "browser_open"
    case browserRead = "browser_read"
    case browserScreenshot = "browser_screenshot"
    case pullRequestCreate = "pull_request_create"
    case orchestratorCapabilities = "orchestrator_capabilities"
    case delegateTask = "delegate_task"
    case taskStatus = "task_status"
    case taskCancel = "task_cancel"
    case sessionRead = "session_read"
    case sessionList = "session_list"
    case sessionSend = "session_send"

    /// The MCP server name, in the agent's configuration and in its tool names.
    static let serverName = "nook"
    /// Claude Code's prefix for the tools of this server.
    static let toolPrefix = "mcp__nook__"

    /// What a call can change: nothing, something visible on this Mac, or something outside it.
    enum Effect: Sendable { case read, local, outward }

    var effect: Effect {
        switch self {
        case .workspaceInfo, .terminalRead, .terminalList, .browserRead, .browserScreenshot,
             .orchestratorCapabilities, .taskStatus, .sessionRead, .sessionList: return .read
        case .terminalRun, .terminalStop, .browserOpen, .delegateTask, .taskCancel, .sessionSend: return .local
        case .pullRequestCreate: return .outward
        }
    }

    /// The tool behind a name as an agent reports it: bare, or with an MCP prefix (`mcp__nook__…`, `nook__…`, `nook.…`).
    static func named(_ name: String) -> BridgeTool? {
        if let tool = BridgeTool(rawValue: name) { return tool }
        for prefix in [toolPrefix, "nook__", "nook."] where name.hasPrefix(prefix) {
            return BridgeTool(rawValue: String(name.dropFirst(prefix.count)))
        }
        return nil
    }

    /// Short, language-neutral label for a session's timeline.
    var label: String {
        switch self {
        case .workspaceInfo: return "Nook workspace"
        case .terminalRun: return "Nook terminal"
        case .terminalRead: return "Nook terminal output"
        case .terminalList: return "Nook terminals"
        case .terminalStop: return "Stop Nook terminal"
        case .browserOpen: return "Nook browser"
        case .browserRead: return "Read Nook browser"
        case .browserScreenshot: return "Nook browser screenshot"
        case .pullRequestCreate: return "Pull request"
        case .orchestratorCapabilities: return "Nook agents"
        case .delegateTask: return "Delegate task"
        case .taskStatus: return "Task status"
        case .taskCancel: return "Cancel task"
        case .sessionRead: return "Read session"
        case .sessionList: return "Nook sessions"
        case .sessionSend: return "Message session"
        }
    }

    /// The most telling argument of a call, for the timeline: the command, the address, the title or the terminal.
    static func detail(_ input: [String: Any]) -> String? {
        for key in ["command", "url", "title", "terminal_id", "task", "task_id", "session_id", "message"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    var summary: String {
        switch self {
        case .workspaceInfo:
            return "Describes the workspace Nook gives you: your folder, branch and changes, the terminals open in Nook for this folder, the page in Nook's browser, whether pull requests can be created, and which tools run directly or need the user's approval. Call it once before using the other nook tools."
        case .terminalRun:
            return "Starts a shell command in a new, visible terminal in Nook (the user sees it next to your session). Use it for long-running processes such as dev servers, watchers or test runs in watch mode, and for anything the user should be able to see or take over. Returns a terminal id and the first output; read more with terminal_read. Commands that are not clearly harmless wait for the user's approval; dangerous ones are refused. For short commands whose output you need right away, keep using your own shell."
        case .terminalRead:
            return "Reads the latest output of one of Nook's terminals in your folder, with whether it is still running and its exit code."
        case .terminalList:
            return "Lists Nook's terminals in your folder: id, title, folder, running or exited, and whether you started it."
        case .terminalStop:
            return "Stops the process in a terminal you started with terminal_run (Ctrl-C). With close: true the terminal is also closed."
        case .browserOpen:
            return "Opens a page in Nook's built-in browser, visible to the user next to your session: https addresses, or http on this Mac (localhost, 127.0.0.1) such as the dev server you started. Waits until the page has loaded and reports its title."
        case .browserRead:
            return "Reads the page open in Nook's browser: title, address, visible text, and console errors and warnings logged since it loaded."
        case .browserScreenshot:
            return "Takes a screenshot of the page in Nook's browser, to check layout and visual changes. Works best while the browser is visible in Nook."
        case .pullRequestCreate:
            return "Proposes a pull request for the current branch of your folder. The user approves it in Nook first; Nook then pushes the branch and opens the pull request on GitHub with the user's own connection (or the GitHub page to finish it). Commit your work before calling this. Returns the link."
        case .orchestratorCapabilities:
            return "Lists the agents Nook can run as a delegated task (installed or not, their models and the rights they offer), your own mode and rights, and the limits on delegating. Call it before delegate_task when you want another agent or model."
        case .delegateTask:
            return "Hands a task to a new agent session in Nook, visible to the user next to yours. The agent gets only the task text (and a role), not this conversation, so write a complete brief. It works in your folder with your mode and rights or narrower; it can never have more. Returns a task id. Without wait it returns at once and Nook tells you when the task has finished; with wait it waits for the result (at most timeout_seconds) and reports waitTimedOut if the task is still running. The user approves each delegation unless the session has full rights."
        case .taskStatus:
            return "Reads the state and result of a task you delegated: queued, running, waiting (for the user), completed, failed or cancelled, with the child's last message as summary."
        case .taskCancel:
            return "Stops a task you delegated, and every task that task delegated in turn."
        case .sessionList:
            return "Lists the user's sessions in Nook (most recent first): id, title, agent, status, folder and branch. Use it to find a session to read with session_read or to message with session_send."
        case .sessionSend:
            return "Sends a message to another Nook session, as if from another agent, not the user: the receiving agent is told so and treats it as information. Use it to hand over a result or ask a question; it is queued when that session is busy. The user approves each message unless the session has full rights. You cannot message yourself."
        case .sessionRead:
            return "Reads a summary of another Nook session: what the user asked, what the agent answered, the commands it ran and the files it changed. Use it when the user points you at a session with a link like [title](nook-context://v1/session/<id>) or an @-mention; the id is in the <nook_context> record."
        }
    }

    var schema: [String: Any] {
        func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required]
        }
        let terminalID: [String: Any] = ["type": "string", "description": "The terminal id from terminal_run or terminal_list, such as \"t2\"."]
        switch self {
        case .workspaceInfo, .terminalList, .browserRead:
            return object([:])
        case .terminalRun:
            return object([
                "command": ["type": "string", "description": "The complete shell command, for example \"npm run dev\"."],
                "cwd": ["type": "string", "description": "Folder to run it in, absolute or relative to your folder. Defaults to your folder."],
                "title": ["type": "string", "description": "Short title for the terminal tab. Defaults to the command."]
            ], required: ["command"])
        case .terminalRead:
            return object([
                "terminal_id": terminalID,
                "lines": ["type": "integer", "description": "How many of the last lines to return (default 80, at most 400)."]
            ], required: ["terminal_id"])
        case .terminalStop:
            return object([
                "terminal_id": terminalID,
                "close": ["type": "boolean", "description": "Also close the terminal tab. Default false."]
            ], required: ["terminal_id"])
        case .browserOpen:
            return object([
                "url": ["type": "string", "description": "The address: https://…, or http://localhost:3000 for a local server."]
            ], required: ["url"])
        case .browserScreenshot:
            return object([
                "max_width": ["type": "integer", "description": "Maximum width of the image in pixels (default 1280)."]
            ])
        case .orchestratorCapabilities:
            return object([:])
        case .delegateTask:
            return object([
                "task": ["type": "string", "description": "The complete brief for the other agent. It sees nothing of this conversation."],
                "agent": ["type": "string", "description": "Which agent: claude, codex, gemini, opencode, cursor, grok or antigravity. Defaults to your own."],
                "model": ["type": "string", "description": "Model name for that agent. Defaults to your own model when it is the same agent, otherwise the agent's default."],
                "title": ["type": "string", "description": "Short title for the session. Defaults to the first line of the task."],
                "role": ["type": "string", "enum": DelegationRole.allCases.map(\.rawValue),
                         "description": "What the task is for. research, review and design run in Plan mode (read-only) unless you pass plan: false."],
                "plan": ["type": "boolean", "description": "Run the task in Plan mode (read-only). Defaults to your own mode; false only if you are not in Plan mode."],
                "rights": ["type": "string", "enum": PermissionPolicy.allCases.map(\.rawValue),
                           "description": "What the task may do without asking: ask, acceptEdits or bypass. Never more than you have."],
                "wait": ["type": "boolean", "description": "Wait for the result instead of returning at once. Default false."],
                "timeout_seconds": ["type": "integer", "description": "With wait: how long to wait (default 45, at most 840). The task keeps running after a timeout."],
                "client_request_id": ["type": "string", "description": "Makes a retry of this call return the same task instead of starting a second one."]
            ], required: ["task"])
        case .sessionList:
            return object(["limit": ["type": "integer", "description": "How many sessions to return (default 15, at most 50)."]])
        case .sessionSend:
            return object([
                "session_id": ["type": "string", "description": "The session id from session_list."],
                "message": ["type": "string", "description": "The message; complete and self-contained."]
            ], required: ["session_id", "message"])
        case .sessionRead:
            return object(["session_id": ["type": "string", "description": "The session id from a <ref kind=\"session\" id=\"…\"/> record."]], required: ["session_id"])
        case .taskStatus:
            return object(["task_id": ["type": "string", "description": "The task id from delegate_task."]], required: ["task_id"])
        case .taskCancel:
            return object(["task_id": ["type": "string", "description": "The task id from delegate_task."]], required: ["task_id"])
        case .pullRequestCreate:
            return object([
                "title": ["type": "string", "description": "Title of the pull request."],
                "body": ["type": "string", "description": "Description in Markdown: what changed and how it was tested."],
                "base": ["type": "string", "description": "Branch to merge into. Defaults to the session's base branch or the repository's default branch."],
                "draft": ["type": "boolean", "description": "Open as draft. Default true."]
            ], required: ["title"])
        }
    }

    /// The tool as `tools/list` describes it.
    var definition: [String: Any] {
        var tool: [String: Any] = ["name": rawValue, "description": summary, "inputSchema": schema]
        tool["annotations"] = [
            "readOnlyHint": effect == .read,
            "openWorldHint": effect == .outward || self == .browserOpen
        ]
        return tool
    }
}

/// Who calls the bridge: a session Nook runs itself, or an agent in a terminal that linked the bridge on its own.
struct BridgeCaller: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case run(UUID)
        case external
    }

    var kind: Kind
    /// The agent's display name: "Claude Code".
    var agent: String
    /// The session's title, when known.
    var title: String
    /// Where the agent works: the session's folder or worktree.
    var directory: String
    /// Only for sessions Nook runs: the mode and rights you chose for it.
    var mode: ExecutionMode?
    var permission: PermissionPolicy?

    /// Identifies the caller for terminals it owns: the run, or the agent in its folder.
    var key: String {
        switch kind {
        case .run(let id): return "run:" + id.uuidString
        case .external: return "ext:" + agent + ":" + directory
        }
    }
}

/// What Nook does with a call.
enum BridgeVerdict: Equatable, Sendable {
    enum Reason: String, Sendable {
        /// Agent tools are switched off in Settings.
        case disabled
        /// The session is in Plan mode: it may look, not change.
        case planMode
        /// The command is dangerous (CommandRisk): never through the bridge.
        case dangerous
        /// The command is not clearly harmless.
        case needsReview
        /// It goes outside this Mac (a push, a pull request).
        case outward
        /// It starts another agent session.
        case delegation
    }

    case allow
    case ask(Reason)
    case refuse(Reason)
}

/// The rules of the bridge, the same for every agent. Nook is the gatekeeper for its own tools: the agent's own
/// permission settings never widen them.
enum BridgePolicy {
    static func verdict(tool: BridgeTool, caller: BridgeCaller, command: CommandAssessment.Level? = nil,
                        enabled: Bool = true) -> BridgeVerdict {
        guard enabled else { return .refuse(.disabled) }
        if tool.effect == .read { return .allow }
        if caller.mode == .plan { return .refuse(.planMode) }
        switch tool {
        case .pullRequestCreate:
            return .ask(.outward)
        case .sessionSend:
            return caller.permission == .bypass ? .allow : .ask(.delegation)
        case .delegateTask:
            // A child never has more rights than its parent, and you see it start; with full rights it starts directly.
            return caller.permission == .bypass ? .allow : .ask(.delegation)
        case .terminalRun:
            switch command ?? .review {
            case .danger: return .refuse(.dangerous)
            case .safe: return .allow
            case .review: return caller.permission == .bypass ? .allow : .ask(.needsReview)
            }
        default:
            return .allow
        }
    }
}

/// Which addresses an agent may open in Nook's browser: any https page, and plain http only on this Mac.
enum BridgeURLPolicy {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    /// The address to load, or nil when it is not allowed. "localhost:3000" without a scheme becomes http.
    static func url(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        var candidate = text
        if !text.contains("://") {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let bare = host.split(separator: ":").first.map { String($0).lowercased() } ?? host
            candidate = (isLoopback(bare) ? "http://" : "https://") + text
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        if scheme == "http", isLoopback(host) { return url }
        return nil
    }

    static func isLoopback(_ host: String) -> Bool {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return loopbackHosts.contains(bare) || bare.hasSuffix(".localhost")
    }
}

/// Terminal output as an agent gets it: the last lines, without the empty screen below the prompt.
enum TerminalText {
    static func tail(_ text: String, lines: Int, limit: Int = 12_000) -> String {
        var rows = text.components(separatedBy: "\n").map { line -> String in
            var line = line
            while line.last?.isWhitespace == true { line.removeLast() }
            return line
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        let shown = rows.suffix(max(1, lines)).joined(separator: "\n")
        return shown.count > limit ? "…" + String(shown.suffix(limit)) : shown
    }
}

/// How a session Nook runs gets the bridge: its MCP server added to the agent's command line, and a short note on what it
/// can do with it.
struct BridgeLaunch: Equatable, Sendable {
    /// Path of the `nook-mcp` script.
    var script: String

    /// The note for the agent, after any instructions of your own.
    static let instructions = """
    You are running inside Nook, a Mac app the user is watching while you work. Nook's workspace is available through the \
    `nook` MCP tools: start long-running processes such as dev servers or watchers with terminal_run (the user sees them in \
    Nook's terminal; check their output with terminal_read), open local or https pages in Nook's browser with browser_open \
    and verify them with browser_read or browser_screenshot, and when the work is committed and ready, propose a pull request \
    with pull_request_create (the user approves it in Nook). Short commands whose output you need right away can still run \
    in your own shell. For work that can run on its own (research, a review, a side task) you can hand it to another agent \
    session with delegate_task: it sees only the brief you write, never has more rights than you, and its result comes back \
    through task_status (or Nook tells you when it has finished).
    """

    /// Claude Code: the server as `--mcp-config` (next to the user's own servers) and its tools allowed up front, because
    /// Nook itself decides about each call.
    func claudeArguments(runID: UUID) -> [String] {
        let server: [String: Any] = [
            "type": "stdio",
            "command": script,
            "args": ["--agent", "claude-code"],
            "env": ["NOOK_RUN_ID": runID.uuidString]
        ]
        let config: [String: Any] = ["mcpServers": [BridgeTool.serverName: server]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ["--mcp-config", String(decoding: data, as: UTF8.self),
                "--allowedTools", "mcp__" + BridgeTool.serverName]
    }

    /// Codex: the server as config overrides. Codex passes only a few variables to MCP servers, so the run id goes in
    /// explicitly, and a call may wait for your approval longer than Codex's default minute.
    func codexArguments(runID: UUID) -> [String] {
        let prefix = "mcp_servers." + BridgeTool.serverName
        return [
            "-c", "\(prefix).command=\(Self.toml(script))",
            "-c", "\(prefix).args=[\(Self.toml("--agent")), \(Self.toml("codex"))]",
            "-c", "\(prefix).env={ NOOK_RUN_ID = \(Self.toml(runID.uuidString)) }",
            "-c", "\(prefix).tool_timeout_sec=900"
        ]
    }

    /// Codex over app-server: the same server as `thread/start` config (`mcp_servers`), no command-line overrides needed.
    func codexMCPServers(runID: UUID) -> [String: Any] {
        [BridgeTool.serverName: [
            "command": script,
            "args": ["--agent", "codex"],
            "env": ["NOOK_RUN_ID": runID.uuidString],
            "tool_timeout_sec": 900
        ] as [String: Any]]
    }

    /// A TOML basic string.
    static func toml(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    escaped += String(format: "\\u%04X", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"" + escaped + "\""
    }
}

/// The JSON-RPC side of the MCP server: Nook answers `initialize`, `tools/list` and `tools/call` itself; the script only
/// carries the messages.
enum BridgeRPC {
    static let protocolVersion = "2025-06-18"

    /// The outcome of one tool call, as text and optionally an image.
    struct ToolResult: Equatable {
        var text: String
        var imageBase64: String?
        var imageMimeType = "image/jpeg"
        var isError = false

        static func error(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }

        var content: [[String: Any]] {
            var parts: [[String: Any]] = []
            if !text.isEmpty { parts.append(["type": "text", "text": text]) }
            if let imageBase64 { parts.append(["type": "image", "data": imageBase64, "mimeType": imageMimeType]) }
            if parts.isEmpty { parts.append(["type": "text", "text": "Done."]) }
            return parts
        }
    }

    /// The answer to one message, or nil for a notification (no id), which gets none.
    static func response(to message: [String: Any], instructions: String = BridgeLaunch.instructions,
                         call: (BridgeTool, [String: Any]) async -> ToolResult) async -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }
        let method = (message["method"] as? String) ?? ""
        let params = (message["params"] as? [String: Any]) ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        func failure(_ code: Int, _ text: String) -> [String: Any] {
            ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]
        }
        switch method {
        case "initialize":
            let requested = (params["protocolVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? protocolVersion
            return result([
                "protocolVersion": requested,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": BridgeTool.serverName, "title": "Nook workspace", "version": "1"],
                "instructions": instructions
            ])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": BridgeTool.allCases.map(\.definition)])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = BridgeTool.named(name) else {
                return failure(-32602, "Unknown tool: \((params["name"] as? String) ?? "")")
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            let outcome = await call(tool, arguments)
            return result(["content": outcome.content, "isError": outcome.isError])
        default:
            return failure(-32601, "Method not found: \(method)")
        }
    }
}
