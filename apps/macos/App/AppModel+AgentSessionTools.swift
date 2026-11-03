import Foundation

/// The user's coding agent sessions as tools for Nook Chat: the other half of the bridge, where agents use Nook's tools.
/// Nook Chat reads a session with the same summary an agent gets (`WorkspaceManager.sessionLines`, `sessionSummary`),
/// and sending a message or starting a session is an action the user approves in the chat's plan first.
/// Every agent Nook runs is reachable the same way: nothing here depends on which agent a session runs.
extension AppModel {
    /// The source these tools belong to (`SourceCatalog`).
    static let agentsSource = "agents"

    var agentSessionTools: [ToolSpec] {
        let sessionID: [String: Any] = ["type": "string", "description": "The session id from list_agent_sessions."]
        return [
            ToolSpec(
                name: "list_agent_sessions",
                description: "Lists the user's coding agent sessions in Nook (Claude Code, Codex, Gemini CLI, Cursor and the others), most recent first: id, title, agent, status, folder and branch.",
                schema: ["type": "object", "properties": [
                    "limit": ["type": "integer", "description": "How many sessions (default 15, at most 50)."]
                ], "required": []],
                kind: .read,
                summarize: { _ in "Read agent sessions" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let lines = self.workspace.sessionLines(limit: min(50, max(1, (input["limit"] as? Int) ?? 15)))
                    return lines.isEmpty ? "No agent sessions." : lines.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "read_agent_session",
                description: "Reads what happened in one coding agent session: what was asked, what the agent answered, the commands it ran and the files it changed. Use it to follow up on an agent's work.",
                schema: ["type": "object", "properties": ["session_id": sessionID], "required": ["session_id"]],
                kind: .read,
                summarize: { _ in "Read agent session" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    guard let id = Self.sessionID(input), let summary = self.workspace.sessionSummary(id) else {
                        throw NookError("No such session. Use an id from list_agent_sessions.")
                    }
                    return summary
                }
            ),
            ToolSpec(
                name: "message_agent_session",
                description: "Sends a message to a coding agent session for the user: a follow-up, an answer to its question, or what it should do next. It waits in line when the agent is busy.",
                schema: ["type": "object", "properties": [
                    "session_id": sessionID,
                    "message": ["type": "string", "description": "The complete message for the agent."]
                ], "required": ["session_id", "message"]],
                kind: .action,
                summarize: { [weak self] input in
                    let title = Self.sessionID(input).flatMap { self?.workspace.run($0)?.title } ?? "agent session"
                    return "Message \(title): \(((input["message"] as? String) ?? "").prefix(80))"
                },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let message = ((input["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let id = Self.sessionID(input), let run = self.workspace.run(id) else {
                        throw NookError("No such session. Use an id from list_agent_sessions.")
                    }
                    guard !message.isEmpty else { throw NookError("Give the message for the agent.") }
                    let sent = self.workspace.submit(id, text: message)
                    return sent ? "Sent to \(run.title)" : "Queued for \(run.title): it gets it after its current turn"
                }
            ),
            ToolSpec(
                name: "start_agent_session",
                description: "Starts a new coding agent session in Nook on a task, in one of the user's project folders, with the user's default account, model and rights for that agent. The session shows up in Nook's Agents tab.",
                schema: ["type": "object", "properties": [
                    "task": ["type": "string", "description": "The complete task for the agent; it sees nothing of this chat."],
                    "agent": ["type": "string", "enum": RunProvider.allCases.filter { $0 != .acp }.map(\.rawValue),
                              "description": "Which agent. Defaults to the user's default agent."],
                    "folder": ["type": "string", "description": "The project folder (a path or a folder name the user worked in before). Defaults to the most recent one."],
                    "plan": ["type": "boolean", "description": "Start in Plan mode (read-only). Default false."]
                ], "required": ["task"]],
                kind: .action,
                summarize: { input in
                    "Start \((input["agent"] as? String) ?? "agent") session: \(((input["task"] as? String) ?? "").prefix(80))"
                },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    return try await self.startAgentSession(input)
                }
            )
        ]
    }

    private static func sessionID(_ input: [String: Any]) -> UUID? {
        UUID(uuidString: ((input["session_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Starts a session the way the composer would: the user's remembered account, model, effort and rights for that
    /// agent, only in a folder the user already worked in.
    private func startAgentSession(_ input: [String: Any]) async throws -> String {
        let task = ((input["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw NookError("Give the task for the agent.") }
        let settings = workspace.settings
        let asked = ((input["agent"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let provider = asked.isEmpty ? settings.defaultProvider
            : RunProvider.allCases.first { $0.rawValue == asked || $0.displayName.lowercased() == asked }
        guard let provider, provider != .acp else { throw NookError("Unknown agent \"\(asked)\".") }
        guard connectedProviders.contains(provider), workspace.executable(provider) != nil else {
            throw NookError("\(provider.displayName) is not installed or signed in on this Mac.")
        }

        var seen = Set<String>()
        let projects = (settings.favoriteProjects + settings.recentProjects).map(WorkspacePathPolicy.normalize).filter { path in
            !path.isEmpty && seen.insert(path).inserted && FileManager.default.fileExists(atPath: path)
        }
        let wanted = ((input["folder"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let folder: String?
        if wanted.isEmpty {
            folder = projects.first
        } else {
            let path = WorkspacePathPolicy.normalize((wanted as NSString).expandingTildeInPath)
            folder = projects.first { $0 == path }
                ?? projects.first { ($0 as NSString).lastPathComponent.lowercased() == wanted.lowercased() }
        }
        guard let folder else {
            throw NookError("Agents start only in a project folder the user worked in before: " + projects.prefix(8).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
        }

        let plan = ((input["plan"] as? Bool) ?? false) && provider.capabilities.planMode
        var config = NewRunConfig()
        config.task = task
        config.provider = provider
        let connected = connectedProfiles(for: provider)
        if let saved = settings.profile(for: provider), connected.contains(where: { $0.id == saved }) {
            config.profileID = saved
        } else {
            config.profileID = connected.first?.id ?? profiles.preferredProfile(provider.kind).id
        }
        config.model = settings.model(for: provider)
        config.effort = settings.effort(for: provider)
        config.mode = plan ? .plan : .agent
        let permission = settings.permission(for: provider)
        config.permission = provider.capabilities.policies.contains(permission) ? permission : (provider.capabilities.policies.first ?? .acceptEdits)
        config.isolation = .folder
        config.projectPath = folder
        let id = try await workspace.start(config, allowSharedFolder: true)
        return "Started \(provider.displayName) in \((folder as NSString).lastPathComponent) | session id \(id.uuidString)"
    }
}
