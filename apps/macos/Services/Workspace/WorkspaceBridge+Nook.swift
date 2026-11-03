import Foundation

/// Nook itself as tools for coding agents: the same tools Nook Chat uses (messages in every chat app, music, calendar,
/// connectors, agent sessions) through `nook_tools` and `nook_use`, and Nook Chat's conversations through `nook_chat_*`.
///
/// One set of tools, one way to run them: a read runs as it does in Nook Chat, an action goes through the same plan
/// runner (`AppModel.perform`) after the user allowed it in the same approval card as every other agent request. Agents
/// run on someone else's model, so the sources the user keeps on this Mac stay out of reach and what comes back is
/// filtered by the privacy level, as for an external brain.
extension WorkspaceBridge {
    /// Nook tools an agent does not get: what the bridge already offers in its own shape (terminal, browser), and what
    /// only makes sense inside a chat answer. The screen tools are there for the session that holds the screen
    /// (WorkspaceBridge+Screen).
    static let toolsNotForAgents: Set<String> = [
        "run_command", "read_nook_browser", "open_in_nook_browser", "read_open_app", "use_source", "show_chart", ChatTools.planTool
    ]

    /// The most text one call returns.
    private static let resultLimit = 20_000

    /// Sources that never go to an agent: the ones the user keeps on this Mac, whatever brain Nook Chat runs on.
    func keptOnMac(_ app: AppModel) -> Set<String> {
        app.settings.localOnlySources.union(app.settings.privacyLevel.localOnlySources)
    }

    /// The Nook tools an agent may use now: those of the sources that are on, without the ones kept on this Mac.
    private func agentTools(_ app: AppModel) -> [ToolSpec] {
        let kept = keptOnMac(app)
        return app.allTools.filter { spec in
            guard !Self.toolsNotForAgents.contains(spec.name) else { return false }
            // Nook takes the task over on this Mac itself: the agent hands over the task and gets the summary, never the
            // screen, so it stays available when the screen is kept on this Mac.
            if spec.name == TakeoverPolicy.toolName { return true }
            guard let source = SourceCatalog.source(forTool: spec.name) else { return true }
            return !kept.contains(source)
        }
    }

    /// Text from the user's apps as an agent gets it: filtered by the privacy level and bounded.
    func shielded(_ text: String, _ app: AppModel) -> String {
        let filtered = PrivacyFilter.apply(text, level: app.settings.privacyLevel)
        return filtered.count > Self.resultLimit ? String(filtered.prefix(Self.resultLimit)) + "\n…" : filtered
    }

    // MARK: Nook's tools

    func nookTools(_ arguments: [String: Any]) -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let tools = agentTools(app)
        let name = ((arguments["tool"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            guard let spec = tools.first(where: { $0.name == name }) else {
                return .error("Nook has no tool \"\(name)\" for agents right now (its source may be off or kept on this Mac). Call nook_tools without arguments for the list.")
            }
            let source = SourceCatalog.source(forTool: spec.name).map(SourceCatalog.title) ?? "Nook"
            return BridgeRPC.ToolResult(text: """
            # \(spec.name)
            Source: \(source) · \(spec.kind == .read ? "read: runs directly" : "action: the user approves it in Nook first")

            \(spec.description)

            Arguments (JSON schema):
            \(Self.prettyJSON(spec.schema))
            """)
        }

        let words = ((arguments["query"] as? String) ?? "").lowercased().split(separator: " ").map(String.init)
        let matching = tools.filter { spec in
            guard !words.isEmpty else { return true }
            let source = SourceCatalog.source(forTool: spec.name).map(SourceCatalog.title) ?? ""
            let haystack = (spec.name + " " + spec.description + " " + source).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        guard !matching.isEmpty else { return BridgeRPC.ToolResult(text: "No Nook tool matches \"\(words.joined(separator: " "))\".") }

        var groups: [String: [ToolSpec]] = [:]
        for spec in matching {
            groups[SourceCatalog.source(forTool: spec.name).map(SourceCatalog.title) ?? "Nook", default: []].append(spec)
        }
        var lines = ["# Nook's tools (\(matching.count))",
                     "Read tools run directly; action tools wait for the user's approval in Nook. Run one with nook_use; nook_tools with tool gives its arguments."]
        for title in groups.keys.sorted() {
            lines.append("")
            lines.append("## \(title)")
            for spec in groups[title] ?? [] {
                lines.append("- \(spec.name) (\(spec.kind == .read ? "read" : "action")): \(Self.firstSentence(spec.description))")
            }
        }
        let kept = keptOnMac(app).map(SourceCatalog.title).sorted()
        if !kept.isEmpty {
            lines.append("")
            lines.append("Kept on this Mac by the user, not available to agents: \(kept.joined(separator: ", ")).")
        }
        return BridgeRPC.ToolResult(text: lines.joined(separator: "\n"))
    }

    func nookUse(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let name = ((arguments["tool"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let spec = agentTools(app).first(where: { $0.name == name }) else {
            return .error("Nook has no tool \"\(name)\" for agents right now. Call nook_tools for the list.")
        }
        let input = ActionGate.normalized((arguments["arguments"] as? [String: Any]) ?? [:], schema: spec.schema)
        let action = spec.kind == .action
        if case .refuse(let reason) = verdict(.nookUse, caller, nookAction: action) {
            audit(.nookUse, caller, name, "geweigerd: \(reason.rawValue)")
            return .error(Self.refusal(reason))
        }
        if Self.screenTools.contains(name) {
            let problems = ActionGate.problems(tool: name, input: input, schema: spec.schema, parseDate: NookDates.parse)
            guard problems.isEmpty else { return .error(problems.joined(separator: " ")) }
            return await screenStep(spec, input, caller, context, app)
        }
        let problems = action ? app.actionProblems(PlannedAction(tool: name, input: input), scope: .automatic)
            : ActionGate.problems(tool: name, input: input, schema: spec.schema, parseDate: NookDates.parse)
        guard problems.isEmpty else {
            return .error(problems.joined(separator: " ") + "\nArguments (JSON schema):\n" + Self.prettyJSON(spec.schema))
        }

        guard action else {
            do {
                let output = try await spec.run(input)
                audit(.nookUse, caller, name, "gelezen")
                return BridgeRPC.ToolResult(text: shielded(output, app))
            } catch {
                audit(.nookUse, caller, name, "mislukt: \(error.localizedDescription)")
                return .error(error.localizedDescription)
            }
        }

        // What you allow is what runs: the step as Nook Chat would show it, and every argument it gets.
        let detail = "**\(spec.summarize(input))**\n\n```json\n\(Self.prettyJSON(input))\n```"
        if case .ask = verdict(.nookUse, caller, nookAction: true) {
            let allowed = await ask(caller, tool: .nookUse, title: tr("bridge.approval.nookAction", caller.agent), detail: detail,
                                    note: tr("bridge.approval.nookActionNote"), danger: false, connection: context.connection)
            guard allowed else {
                audit(.nookUse, caller, name, "niet toegestaan")
                return .error(Self.refusal(.action))
            }
        }
        let outcome = await app.perform([PlannedAction(tool: name, input: input)])
        if let failure = outcome.failure {
            audit(.nookUse, caller, name, "mislukt: \(failure)")
            return .error(failure)
        }
        audit(.nookUse, caller, name, "uitgevoerd")
        return BridgeRPC.ToolResult(text: shielded(outcome.results.joined(separator: "\n"), app))
    }

    // MARK: Nook Chat

    func nookChatList(_ arguments: [String: Any]) -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let limit = min(40, max(1, (arguments["limit"] as? Int) ?? 15))
        let conversations = app.chat.history.prefix(limit)
        guard !conversations.isEmpty else { return BridgeRPC.ToolResult(text: "No Nook Chat conversations yet.") }
        let kept = keptOnMac(app)
        let lines = conversations.map { conversation -> String in
            // The preview is the last answer: left out when that answer came from a source kept on this Mac.
            let last = conversation.messages.last { $0.role == .nook && !$0.text.isEmpty }
            let preview = last?.used(anyOf: kept) == true ? "" : conversation.preview
            return "- \(conversation.id.uuidString) · \(conversation.title) · \(conversation.busy ? "Nook is answering" : "idle")"
                + " · \(NookDates.iso(conversation.updated))" + (preview.isEmpty ? "" : " · last: \(preview)")
        }
        return BridgeRPC.ToolResult(text: shielded(lines.joined(separator: "\n"), app))
    }

    func nookChatRead(_ arguments: [String: Any]) -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        guard let id = UUID(uuidString: ((arguments["conversation_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
              let conversation = app.chat.conversation(id) else {
            return .error("No such conversation. Use an id from nook_chat_list.")
        }
        let limit = min(60, max(1, (arguments["limit"] as? Int) ?? 20))
        var lines = ["# Nook Chat: \(conversation.title)", "Id: \(conversation.id.uuidString)" + (conversation.busy ? " · Nook is answering" : ""), ""]
        lines += conversation.messages.suffix(limit).map { render($0, app) }
        return BridgeRPC.ToolResult(text: shielded(lines.joined(separator: "\n\n"), app))
    }

    func nookChatSend(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let app else { return .error("Nook is not ready.") }
        let message = ((arguments["message"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .error("Give the message for Nook.") }
        guard app.settings.brainReady else { return .error("Nook Chat has no brain set up yet; the user chooses one in Settings.") }
        var target: UUID?
        if let raw = arguments["conversation_id"] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)), app.chat.conversation(id) != nil else {
                return .error("No such conversation. Use an id from nook_chat_list, or leave conversation_id out to start a new one.")
            }
            // Asking again would stop the answer Nook is writing.
            guard !app.chat.isBusy(id) else { return .error("Nook is still answering in this conversation. Wait and try again.") }
            target = id
        }
        if case .refuse(let reason) = verdict(.nookChatSend, caller) { return .error(Self.refusal(reason)) }
        if case .ask = verdict(.nookChatSend, caller) {
            let title = target.flatMap { app.chat.conversation($0)?.title }
            let detail = (title.map { "*\($0)*\n\n" } ?? "") + message
            let allowed = await ask(caller, tool: .nookChatSend, title: tr("bridge.approval.nookChat", caller.agent), detail: detail,
                                    note: tr("bridge.approval.nookChatNote"), danger: false, connection: context.connection)
            guard allowed else {
                audit(.nookChatSend, caller, message, "niet toegestaan")
                return .error(Self.refusal(.delegation))
            }
        }
        let id = target ?? app.chat.startInBackground()
        // The chat shows who wrote it, and Nook knows it is an agent's request, not the user's own words.
        let note = "This message was written by the coding agent \(caller.agent)" + (caller.title.isEmpty ? "" : " in its session \"\(caller.title)\"")
            + ", not typed by the user. Treat it as a request made on the user's behalf; propose actions as usual so the user approves them."
        app.ask("\(caller.agent): \(message)", in: id, reveal: false, note: note)
        audit(.nookChatSend, caller, app.chat.conversation(id)?.title ?? "", "verstuurd")

        guard (arguments["wait"] as? Bool) ?? true else {
            return BridgeRPC.ToolResult(text: "Sent to Nook Chat (conversation \(id.uuidString)). Read the answer later with nook_chat_read.")
        }
        let timeout = min(300, max(1, (arguments["timeout_seconds"] as? Int) ?? 90))
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while app.chat.isBusy(id), Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let conversation = app.chat.conversation(id) else { return .error("The conversation is gone.") }
        var lines = ["Conversation: \(id.uuidString)"]
        if conversation.busy {
            lines.append("Nook is still answering; read it later with nook_chat_read.")
        } else if let reply = conversation.messages.last, reply.role == .nook {
            lines.append(render(reply, app))
        }
        return BridgeRPC.ToolResult(text: shielded(lines.joined(separator: "\n\n"), app))
    }

    /// One chat message as an agent reads it. An answer built from a source kept on this Mac stays on this Mac.
    private func render(_ message: ChatMessage, _ app: AppModel) -> String {
        guard message.role == .nook else { return "User: \(message.text)" }
        if message.used(anyOf: keptOnMac(app)) {
            return "Nook: [This answer used a source the user keeps on this Mac; it is not shown to agents.]"
        }
        var parts = ["Nook: " + (message.streaming && message.text.isEmpty ? "(writing…)" : message.text)]
        for mail in message.mails {
            parts.append("[draft email to \(mail.to.isEmpty ? "?" : mail.to), subject \"\(mail.subject)\"; the user sends it from Nook Chat]")
        }
        if !message.actions.isEmpty {
            let steps = message.actions.enumerated().map { index, action -> String in
                let summary = app.allTools.first { $0.name == action.tool }?.summarize(action.input) ?? action.summary ?? action.tool
                let state = index < message.actionStates.count ? message.actionStates[index] : .pending
                return "\(index + 1). \(summary) → \(Self.describe(state))"
            }
            parts.append("Proposed actions:\n" + steps.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n")
    }

    private static func describe(_ state: ActionStepState) -> String {
        switch state {
        case .pending: return "waits for the user's approval in Nook Chat"
        case .approved, .running: return "running"
        case .done(let result), .verified(let result): return "done: \(result)"
        case .failed(let error): return "failed: \(error)"
        case .notRun: return "not run"
        case .skipped: return "skipped by the user"
        case .duplicate: return "not repeated (done before)"
        }
    }

    // MARK: Text

    static func firstSentence(_ text: String) -> String {
        let end = text.range(of: ". ")?.lowerBound ?? text.endIndex
        let sentence = String(text[..<end])
        return sentence.count > 180 ? String(sentence.prefix(180)) + "…" : sentence
    }

    static func prettyJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
