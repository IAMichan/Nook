import Foundation

/// The user's coding agent sessions as tools for Nook Chat: the other half of the bridge, where agents use Nook's tools.
/// Nook Chat reads a session with the same summary an agent gets (`WorkspaceManager.sessionLines`, `sessionSummary`),
/// and sending a message or starting a session is an action the user approves in the chat's plan first.
/// Every agent Nook runs is reachable the same way: nothing here depends on which agent a session runs.
/// The machines sessions can run on over SSH (Settings › Machines) are here too: an agent can list them, add one (an
/// action the user approves) and start a session on one. A password never passes through a tool: the user types it in
/// Nook itself (RemotePasswordField).
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
                    "folder": ["type": "string", "description": "The project folder (a path or a folder name the user worked in before). Defaults to the most recent one. With machine: the folder on that machine (~/code/app or /srv/app), default ~."],
                    "machine": ["type": "string", "description": "Run it on another machine over SSH: the name or host of a machine from list_remote_machines. Leave out to run on this Mac."],
                    "plan": ["type": "boolean", "description": "Start in Plan mode (read-only). Default false."]
                ], "required": ["task"]],
                kind: .action,
                summarize: { input in
                    let place = (input["machine"] as? String).map { " on \($0)" } ?? ""
                    return "Start \((input["agent"] as? String) ?? "agent") session\(place): \(((input["task"] as? String) ?? "").prefix(80))"
                },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    return try await self.startAgentSession(input)
                }
            ),
            ToolSpec(
                name: "list_remote_machines",
                description: "Lists the machines the user's agent sessions can run on over SSH (Settings › Machines): name, ssh host, port, key file, whether it logs in with a password and whether Nook has that password now, and when it was last used.",
                schema: ["type": "object", "properties": [:], "required": []],
                kind: .read,
                summarize: { _ in "Read machines" },
                tag: { _ in ("", .neutral) },
                run: { _ in
                    let lines = RemoteMachines.load().map(Self.machineLine)
                    return lines.isEmpty ? "No machines yet. add_remote_machine adds one." : lines.joined(separator: "\n")
                }
            ),
            ToolSpec(
                name: "add_remote_machine",
                description: "Adds a machine agent sessions can run on over SSH, then tests the connection and reports which agents (Claude Code, Codex, …) are installed there. Nook uses the user's own ssh: an alias from ~/.ssh/config or user@host, a key in their SSH agent or a key file. Never ask the user for a password: when the machine needs one, the user types it once in Nook itself.",
                schema: ["type": "object", "properties": [
                    "host": ["type": "string", "description": "How ssh reaches it: an alias from ~/.ssh/config or user@host."],
                    "name": ["type": "string", "description": "A short name to show (default: the host)."],
                    "port": ["type": "integer", "description": "The ssh port when it is not 22."],
                    "identity_file": ["type": "string", "description": "A key file on this Mac for this machine only, like ~/.ssh/id_ed25519. Leave out to use the user's ssh config and agent."]
                ], "required": ["host"]],
                kind: .action,
                summarize: { input in
                    let host = ((input["host"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    let name = ((input["name"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                    let port = (input["port"] as? Int).map { ":\($0)" } ?? ""
                    return "Add machine \(name.isEmpty ? host : name): \(host)\(port)"
                },
                tag: { _ in ("SSH", .neutral) },
                run: { input in try await Self.addRemoteMachine(input) }
            )
        ]
    }

    /// The commands of the agents Nook can run on another machine, to look for there.
    nonisolated static var remoteAgentCommands: [String] { AgentKind.allCases.filter { $0 != .acp }.map(\.command) }

    /// The names of the agents a connection test found, in Nook's order.
    nonisolated static func agentNames(_ commands: [String]) -> [String] {
        AgentKind.allCases.filter { commands.contains($0.command) }.map(\.name)
    }

    private static func machineLine(_ machine: RemoteMachine) -> String {
        var parts = [machine.name, "host " + machine.host + (machine.port.map { ":\($0)" } ?? "")]
        if let key = machine.identityFile { parts.append("key " + key) }
        if machine.usesPassword {
            parts.append(RemotePasswords.shared.isUnlocked(machine) ? "password: unlocked" : "password: locked (the user types it in Nook)")
        }
        parts.append(machine.lastUsedAt.map { "last used " + ISO8601DateFormatter().string(from: $0) } ?? "never used")
        return parts.joined(separator: " | ")
    }

    /// Saves the machine (or finds it, when that host and port are there already) and tests it the way Settings does.
    private static func addRemoteMachine(_ input: [String: Any]) async throws -> String {
        let host = ((input["host"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard RemoteMachines.isValidHost(host) else {
            throw NookError("Give the host as an ssh alias or user@host: letters, digits and @ . - _ : only, not starting with a dash.")
        }
        let port = input["port"] as? Int
        if let port, !(1...65535).contains(port) { throw NookError("The port must be between 1 and 65535.") }
        let key = ((input["identity_file"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        guard key.isEmpty || RemoteMachines.isValidIdentityFile(key) else {
            throw NookError("The key file must be a path on this Mac, like ~/.ssh/id_ed25519.")
        }
        let name = ((input["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var machine: RemoteMachine
        let added: Bool
        if let existing = RemoteMachines.load().first(where: { $0.host == host && $0.port == port }) {
            machine = existing
            added = false
        } else {
            machine = RemoteMachine(name: name.isEmpty ? host : String(name.prefix(60)), host: host, port: port,
                                    identityFile: key.isEmpty ? nil : key)
            RemoteMachines.upsert(machine)
            added = true
        }
        let commands = remoteAgentCommands
        let probed = machine
        let result = await Task.detached(priority: .userInitiated) {
            RemoteShell.check(probed, password: nil, commands: commands)
        }.value
        let opening = added ? "Added \(machine.name) (\(machine.host))." : "\(machine.name) (\(machine.host)) was already there."
        switch result {
        case .success(let found):
            RemoteMachines.markUsed(id: machine.id)
            let names = agentNames(found)
            return opening + " The connection works. " + (names.isEmpty
                ? "No agent was found in the login shell there: install one there before starting a session."
                : "Agents there: " + names.joined(separator: ", ") + ". start_agent_session with machine \"\(machine.name)\" runs a session on it.")
        case .failure(let error) where error.needsPassword:
            machine = RemoteMachines.update(id: machine.id) { $0.passwordLogin = true } ?? machine
            return opening + " It logs in with a password. Do not ask for it in the chat: the user types it once in Nook (Settings › Machines, or when starting a session on it) and can keep it in the Keychain."
        case .failure(let error):
            return opening + " The connection test failed: " + (error.message.isEmpty ? "ssh exited with code \(error.status)." : error.message)
                + " The machine is saved; once ssh works from this Mac, it can be used."
        }
    }

    private static func sessionID(_ input: [String: Any]) -> UUID? {
        UUID(uuidString: ((input["session_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Starts a session the way the composer would: the user's remembered agent for that folder and the account, model,
    /// effort and rights for that agent, only in a folder the user already worked in.
    private func startAgentSession(_ input: [String: Any]) async throws -> String {
        let task = ((input["task"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { throw NookError("Give the task for the agent.") }
        let settings = workspace.settings
        let asked = ((input["agent"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = asked.isEmpty ? settings.defaultProvider
            : RunProvider.allCases.first { $0.rawValue == asked || $0.displayName.lowercased() == asked }
        guard var provider = named, provider != .acp else { throw NookError("Unknown agent \"\(asked)\".") }
        let machineName = ((input["machine"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !machineName.isEmpty {
            return try await startRemoteAgentSession(task: task, provider: provider, machineName: machineName, input: input)
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

        // Without a named agent, the one you last used in this folder, while it can run here.
        let folderProvider = settings.composerDefaults(for: folder).provider
        if asked.isEmpty, folderProvider != .acp, connectedProviders.contains(folderProvider),
           workspace.executable(folderProvider) != nil {
            provider = folderProvider
        }
        guard connectedProviders.contains(provider), workspace.executable(provider) != nil else {
            throw NookError("\(provider.displayName) is not installed or signed in on this Mac.")
        }

        var config = sessionConfig(task: task, provider: provider, folder: folder, plan: (input["plan"] as? Bool) ?? false)
        config.projectPath = folder
        let id = try await workspace.start(config, allowSharedFolder: true)
        return "Started \(provider.displayName) in \((folder as NSString).lastPathComponent) | session id \(id.uuidString)"
    }

    /// A session on a saved machine, in a folder there. The agent runs under that machine's own login, so it is not
    /// looked up on this Mac; a machine that logs in with a password must have been unlocked in Nook first. An agent
    /// that cannot run there is refused by the configuration check (`NewRunConfig.problem`), as in the composer.
    private func startRemoteAgentSession(task: String, provider: RunProvider, machineName: String,
                                         input: [String: Any]) async throws -> String {
        let machines = RemoteMachines.load()
        let wanted = machineName.lowercased()
        guard let machine = machines.first(where: { $0.name.lowercased() == wanted || $0.host.lowercased() == wanted || $0.id == machineName }) else {
            let known = machines.map(\.name).joined(separator: ", ")
            throw NookError("No machine \"\(machineName)\". " + (known.isEmpty ? "Add one with add_remote_machine." : "Machines: \(known)."))
        }
        guard RemotePasswords.shared.isUnlocked(machine) else {
            throw NookError("\(machine.name) logs in with a password that Nook does not have yet. Do not ask for it in the chat: the user types it once in Nook (Settings › Machines, or when starting a session on it), then try again.")
        }
        let folder = ((input["folder"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let directory = folder.isEmpty ? "~" : folder
        guard RemoteMachines.isValidDirectory(directory) else {
            throw NookError("Give the folder on \(machine.name) as an absolute path or one from its home, like ~/code/app.")
        }
        var config = sessionConfig(task: task, provider: provider, folder: nil, plan: (input["plan"] as? Bool) ?? false)
        config.remote = RemoteTarget(machine: machine, directory: directory)
        let id = try await workspace.start(config, allowSharedFolder: true)
        UserDefaults.standard.set(directory, forKey: "agents.remoteFolder." + machine.id)
        return "Started \(provider.displayName) on \(machine.name) in \(directory) | session id \(id.uuidString)"
    }

    /// The user's remembered account, model, effort and rights for the agent in this folder, as the composer would use them.
    func sessionConfig(task: String, provider: RunProvider, folder: String?, plan wantsPlan: Bool) -> NewRunConfig {
        let defaults = workspace.settings.composerDefaults(for: folder)
        let plan = wantsPlan && provider.capabilities.planMode
        var config = NewRunConfig()
        config.task = task
        config.provider = provider
        config.profileID = defaults.profile(for: provider, connected: connectedProfiles(for: provider).map(\.id))
            ?? profiles.preferredProfile(provider.kind).id
        config.model = defaults.model(for: provider)
        config.effort = defaults.effort(for: provider)
        config.mode = plan ? .plan : .agent
        let permission = defaults.permission(for: provider)
        config.permission = provider.capabilities.policies.contains(permission) ? permission : (provider.capabilities.policies.first ?? .acceptEdits)
        config.isolation = .folder
        return config
    }
}
