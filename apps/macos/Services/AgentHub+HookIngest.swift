import Foundation

/// What the agents' hooks send over Nook's socket: parsed off the main thread into a `HookMessage`, then applied to the
/// session's record here.
extension AgentHub {
    // MARK: Messages

    /// A hook message as the socket's queue parsed it. The JSON objects in it come from `JSONSerialization` and are never
    /// changed afterwards, which is what makes handing them to the main thread safe.
    struct HookMessage: @unchecked Sendable {
        let event: [String: Any]
        let env: [String: Any]
        let agentID: String
        /// "event", "permission", "ask" or "statusline".
        let mode: String
        /// The event's name as Claude Code calls it (`AgentHub.normalize`).
        let kind: String
        /// The account directory from the hook's environment; empty for the standard one.
        let home: String
        /// What the status line reports of the plan's usage (mode "statusline" only).
        let usage: PlanUsage?

        /// A session Nook's workspace runs itself: tracked there, with its own approvals. Its status line still counts.
        var isWorkspaceRun: Bool {
            guard mode != "statusline", let run = env["NOOK_RUN_ID"] as? String else { return false }
            return !run.isEmpty
        }

        static func parse(_ data: Data) -> HookMessage? {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let event = (object["event"] as? [String: Any]) ?? [:]
            let env = (object["env"] as? [String: Any]) ?? [:]
            var agentID = AgentHub.cleanAgentID((object["agent"] as? String) ?? "agent")
            if agentID == "claude-code", (env["CLAUDE_CODE_ENTRYPOINT"] as? String) == "claude-desktop" {
                agentID = "claude-desktop"
            }
            let mode = (object["mode"] as? String) ?? (((object["wait"] as? Bool) ?? false) ? "permission" : "event")
            let kind = AgentHub.normalize((event["hook_event_name"] as? String) ?? (event["type"] as? String) ?? "")
            return HookMessage(event: event, env: env, agentID: agentID, mode: mode, kind: kind,
                               home: AgentHub.accountHome(env, agentID: agentID),
                               usage: mode == "statusline" ? PlanUsage.parse(event) : nil)
        }
    }

    /// Handles one hook message: every record change and every card it opens or closes is published as one rebuild, and
    /// saved as one snapshot.
    func handle(_ message: HookMessage, _ connection: HookConnection) {
        deferringRebuild = true
        let followUp = apply(message, connection)
        deferringRebuild = false
        if rebuildRequested {
            rebuildRequested = false
            rebuild()
        }
        guard let followUp else { return }
        // A new prompt is a new turn: a chat you settled comes back now, whether or not the Agents list is on screen.
        if followUp.reopen, let session = sessions.first(where: { $0.id == followUp.key }) {
            FinishedSessions.shared.reopen(FinishedSessions.key(session: session))
        }
        if followUp.attention, let session = sessions.first(where: { $0.id == followUp.key }) {
            onAttention?(session)
        }
        if followUp.reply { connection.reply(nil) }
    }

    /// What `handle` does after the sessions are rebuilt, for an event that went through to the end of `apply`.
    private struct HookFollowUp {
        let key: String
        let reopen: Bool
        let attention: Bool
        let reply: Bool
    }

    private func apply(_ message: HookMessage, _ connection: HookConnection) -> HookFollowUp? {
        let event = message.event
        let env = message.env
        let agentID = message.agentID
        let mode = message.mode
        let kind = message.kind

        if mode == "statusline" {
            if let usage = message.usage {
                let home = message.home
                // The status line runs on every message update, several times a second: a reading that shows nothing new
                // is only stored once a minute (to keep `updated` fresh), instead of redrawing every view and rewriting
                // UserDefaults each time.
                let known = home.isEmpty ? planUsage : profilePlanUsage[home]
                if let known, !usage.differs(from: known) { connection.reply(nil); return nil }
                if home.isEmpty { planUsage = usage } else { profilePlanUsage[home] = usage }
            }
            connection.reply(nil)
            return nil
        }

        let cwd = (event["cwd"] as? String) ?? (event["workdir"] as? String) ?? ""
        let sessionID = (event["session_id"] as? String)
            ?? (event["thread-id"] as? String)
            ?? (event["thread_id"] as? String)
            ?? (event["conversation_id"] as? String)
            ?? cwd
        let key = "\(agentID):\(sessionID)"
        let name = Self.displayName(agentID)
        // The agent this event comes from, mapped once: what it supports comes from `AgentKind`, not from its name.
        let agentKind = AgentKind(hookAgentID: agentID)

        if kind == "SessionEnd" {
            records[key] = nil
            sessionGrants[key] = nil
            for (id, pending) in pendingApprovals where pending.request.sessionKey == key {
                closeApproval(id, response: nil, status: nil, step: nil)
            }
            for (id, pending) in pendingQuestions where pending.request.sessionKey == key {
                closeQuestion(id, response: nil, status: nil, step: nil)
            }
            rebuild()
            connection.reply(nil)
            return nil
        }

        // The app's prompt was answered in the app (the tool went on), or the turn moved past it: its card goes.
        let finishedTool = (event["tool_name"] as? String) ?? (event["toolName"] as? String) ?? ""
        let promptTool = (kind == "PostToolUse" || kind == "PostToolUseFailure") && ScreenAction(tool: finishedTool)?.asksYou == true
        if promptTool || ["UserPromptSubmit", "Stop", "StopFailure", "Interrupt"].contains(kind) {
            closeAppPrompts(key: key, step: (.running, "answered in \(name)"))
        }

        var record = records[key] ?? Record(
            agentID: agentID,
            agent: name,
            project: Self.projectName(cwd),
            cwd: cwd,
            status: .running,
            steps: [],
            file: "",
            lastMessage: "",
            updated: Date(),
            hostBundleID: "",
            diff: [],
            linesAdded: 0,
            linesRemoved: 0
        )
        // The agent `cd`'ing into a subfolder keeps the session in the folder it started in; nor into a scratch folder
        // outside its project: the branch and changes stay those of the project.
        if !cwd.isEmpty, record.cwd.isEmpty || !cwd.hasPrefix(record.cwd + "/") {
            record.cwd = SessionFolder.follow(current: record.cwd, reported: cwd)
            record.project = Self.projectName(record.cwd)
        }
        if let host = env["__CFBundleIdentifier"] as? String, !host.isEmpty {
            record.hostBundleID = host
        }
        record.home = message.home
        record.updated = Date()
        // Which process this session runs in; the same session resumed in a new process starts over.
        let sameProcess = record.pid.map { connection.lineage.contains($0) } ?? false
        if !connection.lineage.isEmpty, !sameProcess {
            record.lineage = connection.lineage
            record.pid = SessionLiveness.agentProcess(agent: name, lineage: connection.lineage, in: Self.scanned(processes))
        }
        if let id = event["session_id"] as? String, !id.isEmpty { record.sessionID = id }
        if let path = event["transcript_path"] as? String, !path.isEmpty { record.transcriptPath = path }
        if record.transcriptPath.isEmpty, let found = agentKind?.hookTranscript(sessionID: record.sessionID, env: env) {
            record.sessionID = found.sessionID
            record.transcriptPath = found.path
        }

        // A compaction shows while it runs, and is over at the agent's next event: its end (PostCompact, Claude Code's
        // SessionStart from "compact"), or a prompt, a tool or Stop for an agent that does not say when it is done.
        switch HookCompaction.change(kind: kind) {
        case .start:
            if record.compactingSince == nil {
                record.compactingSince = Date()
                Self.push(&record, .running, tr("ws.activity.compacting"))
            }
        case .end:
            if record.compactingSince != nil {
                record.compactingSince = nil
                Self.complete(&record, as: .done)
            }
        }

        let tool = (event["tool_name"] as? String) ?? (event["toolName"] as? String) ?? ""
        let input = (event["tool_input"] as? [String: Any]) ?? (event["toolArgs"] as? [String: Any]) ?? [:]

        // Multiple-choice question from agent.
        if mode == "ask" {
            guard kind == "PreToolUse", tool == "AskUserQuestion", let items = AgentQuestionRequest.parse(input) else {
                records[key] = record
                connection.reply(nil)
                return nil
            }
            askQuestion(key: key, record: &record, items: items, raw: input["questions"] ?? [], connection: connection)
            records[key] = record
            rebuild()
            return nil
        }

        // Permission: agent is waiting for our response.
        if mode == "permission" {
            if kind == "PermissionRequest" {
                guard tool != "AskUserQuestion" else {
                    connection.reply(nil)
                    return nil
                }
                let suggestions = event["permission_suggestions"]
                // Claude Code stores the rule it suggests; the OpenCode and Hermes plugins turn it into their own
                // "always" / "session" answer. Codex and Muse take no rule back.
                let canAlways = (agentKind?.hookTakesAlwaysRule == true || Self.pluginAlways.contains(agentID))
                    && ((suggestions as? [Any])?.isEmpty == false)
                requestApproval(key: key, record: &record, tool: tool, input: input,
                                kind: .permission(suggestions: suggestions, canAlways: canAlways), connection: connection)
                records[key] = record
                rebuild()
                return nil
            }
            if kind == "PreToolUse", PreToolGate.agents.contains(agentID) {
                // The agent's hook runs before every tool call: ask only where the agent would ask (`PreToolGate`).
                Self.push(&record, .running, Self.describe(tool: tool, input: input))
                if record.turnStarted == nil { record.turnStarted = Date() }
                let grant = PreToolGate.grant(tool: tool, input: input)
                if sessionGrants[key]?.contains(grant) == true {
                    connection.reply(Self.response(for: .allow, kind: .preToolUse(grant: nil)))
                } else if PreToolGate.wouldAsk(tool: tool, input: input), !Self.allowsEverything(connection.lineage) {
                    requestApproval(key: key, record: &record, tool: tool, input: input, kind: .preToolUse(grant: grant),
                                    connection: connection)
                    records[key] = record
                    rebuild()
                    return nil
                } else {
                    connection.reply(nil)
                }
                records[key] = record
                rebuild()
                return nil
            }
            if kind == "PreToolUse", tool == "Bash" {
                // Legacy integration (prior to PermissionRequest): only commands that are not clearly safe.
                Self.push(&record, .running, Self.describe(tool: tool, input: input))
                if let command = Self.commandText(input), CommandRisk.assess(command).level != .safe {
                    requestApproval(key: key, record: &record, tool: tool, input: input, kind: .preToolUse(grant: nil), connection: connection)
                    records[key] = record
                    rebuild()
                    return nil
                }
                records[key] = record
                rebuild()
                connection.reply(nil)
                return nil
            }
            connection.reply(nil)
        }

        var attention = false

        switch kind {
        case "SessionStart":
            // Claude Code starts again after a compaction (`source: "compact"`): the session works no more than before.
            if (event["source"] as? String) != "compact" { record.status = .running }
        case "UserPromptSubmit":
            record.status = .running
            record.turnStarted = Date()
            record.diff = []
            // What the agent injects itself (a finished background task …) is not your last prompt.
            if let prompt = (event["prompt"] as? String).flatMap(InjectedPrompt.prompt) {
                record.lastPrompt = prompt
                if record.firstPrompt.isEmpty { record.firstPrompt = prompt }
                record.lastMessage = ""
                Self.push(&record, .done, "prompt: " + Self.shorten(prompt, 60))
            }
            recap?.prompt(session: key, project: record.project, agent: name)
        case "PreToolUse":
            record.status = .running
            if let path = Self.filePath(input) { record.file = Self.shortPath(path) }
            if let edit = Self.editDiff(tool: tool, input: input) { record.diff = edit.lines }
            record.pendingWrites = SessionProjects.writtenFiles(tool: tool, input: input, cwd: record.cwd)
            Self.push(&record, .running, Self.describe(tool: tool, input: input))
            // The prompt was missed (Nook started mid-turn): this turn is at least this old.
            if record.turnStarted == nil { record.turnStarted = Date() }
            recap?.toolUse(tool)
            // The agent's app is about to ask you in its own window (Claude's "Allow Claude to use …?"): ask here too.
            let hosts = AppPrompt.hostBundleIDs(agentID: agentID, hostBundleID: record.hostBundleID, tool: tool)
            if !hosts.isEmpty {
                closeAppPrompts(key: key, step: nil)
                requestApproval(key: key, record: &record, tool: tool, input: input, kind: .appPrompt(bundleIDs: hosts),
                                connection: nil)
            }
        case "PostToolUse":
            Self.complete(&record, as: .done)
            Self.resume(&record, asking: isAsking(key))
            if let edit = Self.editDiff(tool: tool, input: input) {
                record.linesAdded += edit.added
                record.linesRemoved += edit.removed
                recap?.edit(added: edit.added, removed: edit.removed)
            }
            Self.noteProjects(&record, tool: tool, input: input)
        case "PostToolUseFailure":
            Self.complete(&record, as: .failed)
            record.pendingWrites = []
            Self.resume(&record, asking: isAsking(key))
        case "Notification":
            let message = (event["message"] as? String) ?? "waiting for you"
            record.lastMessage = message
            // If the question is already presented as a card in the notch, don't show another alert.
            let asking = isAsking(key)
            // "Claude is waiting for your input" is Claude Code's idle message after finishing a turn: not a prompt to you.
            let idle = message.lowercased().contains("waiting for your input")
            if idle && !asking {
                if record.status != .done { record.status = .done }
                record.turnStarted = nil
                Self.push(&record, .done, "done, waiting for your next prompt")
            } else if !asking {
                record.status = .waiting
                Self.push(&record, .blocked, Self.shorten(message, 70))
                attention = true
            }
        case "Stop":
            record.status = .done
            record.turnStarted = nil
            if let last = (event["last-assistant-message"] as? String) ?? (event["last_assistant_message"] as? String) {
                record.lastMessage = last
            }
            Self.complete(&record, as: .done)
            Self.push(&record, .done, "done")
            attention = true
            recap?.turnEnded(session: key)
        case "StopFailure":
            record.status = .failed
            record.turnStarted = nil
            let error = (event["error"] as? String) ?? (event["message"] as? String) ?? "stopped with an error"
            Self.complete(&record, as: .failed)
            Self.push(&record, .failed, Self.shorten(error, 70))
            attention = true
            recap?.turnEnded(session: key)
        case "SubagentStart":
            let type = (event["agent_type"] as? String) ?? (event["subagent_type"] as? String) ?? ""
            Self.push(&record, .running, type.isEmpty ? "subagent started" : "subagent: \(type)")
        case "SubagentStop":
            Self.complete(&record, as: .done)
        case "Interrupt":
            record.status = .done
            record.turnStarted = nil
            Self.complete(&record, as: .failed)
            Self.push(&record, .failed, "interrupted")
            recap?.turnEnded(session: key)
        default:
            break
        }

        records[key] = record
        rebuild()
        return HookFollowUp(key: key, reopen: kind == "UserPromptSubmit", attention: attention, reply: mode != "permission")
    }
}

extension AgentHub {
    /// A file the tool call wrote in another project than the session's own: the list names both (`SessionProjects`),
    /// the same as for a session Nook runs.
    static func noteProjects(_ record: inout Record, tool: String, input: [String: Any]) {
        let written = SessionProjects.writtenFiles(tool: tool, input: input, cwd: record.cwd)
        let files = written.isEmpty && input.isEmpty ? record.pendingWrites : written
        record.pendingWrites = []
        for file in files {
            if let projects = SessionProjects.adding(file: file, own: record.cwd, to: record.otherProjects) {
                record.otherProjects = projects
            }
        }
    }
}
