import AppKit

/// Permission requests and questions from agents in a terminal: held on the hook's connection until you answer in Nook
/// (or in the terminal), they time out, or the session's rights already allow them.
extension AgentHub {
    // MARK: Permissions

    func requestApproval(
        key: String,
        record: inout Record,
        tool: String,
        input: [String: Any],
        kind: PendingKind,
        connection: HookConnection?
    ) {
        let id = UUID().uuidString
        var summary = Self.approvalSummary(tool: tool, input: input)
        let edit = Self.editDiff(tool: tool, input: input)
        var assessment = Self.assess(tool: tool, input: input, edit: edit)
        var canAlways = false
        var title: String?
        var timeout = Self.approvalTimeout
        switch kind {
        case .permission(_, let always):
            canAlways = always
        case .preToolUse(let grant):
            canAlways = grant != nil
        case .appPrompt:
            summary = AppPrompt.summary(input: input)
            title = AppPrompt.title(tool: tool, agent: record.agent)
            assessment = CommandAssessment(level: .review, title: "", note: tr("ws.approval.appPromptNote", record.agent))
            timeout = Self.appPromptTimeout
        }

        let request = ApprovalRequest(
            id: id,
            sessionKey: key,
            agentName: record.agent,
            project: record.project,
            tool: tool,
            summary: summary,
            diff: edit?.lines ?? [],
            assessment: assessment,
            canAlways: canAlways,
            created: Date(),
            customTitle: title
        )
        pendingApprovals[id] = PendingApproval(request: request, connection: connection, kind: kind)
        approvals.append(request)

        record.status = .waiting
        if let edit { record.diff = edit.lines }
        Self.replaceLast(&record, .blocked, "waiting for you: " + Self.shorten(summary, 50))

        connection?.onPeerClosed { [weak self] in
            Task { @MainActor in
                self?.closeApproval(id, response: nil, status: .running, step: (.running, "answered in the terminal"))
            }
        }
        let wait = timeout
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            // No answer received: the agent will prompt directly, as normal.
            self?.closeApproval(id, response: nil, status: .waiting, step: (.blocked, "waiting for you in the terminal"))
        }
        onApproval?(request)
    }

    /// Answers the app's own prompt by pressing its button. When Nook cannot find the button for sure (the app shows
    /// another conversation, or Nook has no Accessibility access), it opens the app, so you answer there.
    func answerAppPrompt(_ id: String, bundleIDs: [String], allow: Bool) {
        guard answering.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            let pressed = await AppPromptPresser.press(allow ? .allow : .deny, bundleIDs: bundleIDs)
            guard let self else { return }
            self.answering.remove(id)
            guard self.pendingApprovals[id] != nil else { return }
            if pressed {
                self.recap?.decision(allowed: allow)
                if allow {
                    self.closeApproval(id, response: nil, status: .running, step: (.running, "allowed via Nook"), message: "Allowed")
                } else {
                    self.closeApproval(id, response: nil, status: .running, step: (.failed, "denied via Nook"), message: "Denied")
                }
            } else {
                self.closeApproval(id, response: nil, status: .waiting, step: (.blocked, "waiting for you in the app"))
                let app = bundleIDs.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
                app?.activate(options: [.activateAllWindows])
            }
        }
    }

    /// Plugin agents that answer "Always" themselves (see `AgentPlugins`).
    static let pluginAlways: Set<String> = ["opencode", "hermes"]

    /// The agent was started allowing every tool (`--allow-all-tools`, `--yolo`): it never asks, so Nook does not either.
    static func allowsEverything(_ lineage: [Int32]) -> Bool {
        lineage.contains { pid in LocalAgentScanner.commandLine(pid).map(PreToolGate.allowsEverything) ?? false }
    }

    /// Closes the app-prompt cards of a session.
    func closeAppPrompts(key: String, step: (AgentStep.Mark, String)?) {
        for (id, pending) in pendingApprovals where pending.request.sessionKey == key {
            guard case .appPrompt = pending.kind else { continue }
            closeApproval(id, response: nil, status: .running, step: step)
        }
    }

    func closeApproval(
        _ id: String,
        response: Data?,
        status: AgentStatus?,
        step: (AgentStep.Mark, String)?,
        message: String? = nil
    ) {
        guard let pending = pendingApprovals.removeValue(forKey: id) else { return }
        pending.connection?.reply(response)
        approvals.removeAll { $0.id == id }
        let key = pending.request.sessionKey
        if var record = records[key] {
            if let status, record.status == .waiting { record.status = status }
            if let step { Self.replaceLast(&record, step.0, step.1) }
            records[key] = record
        }
        rebuild()
        onApprovalGone?(id, message)
    }

    static func response(for decision: ApprovalDecision, kind: PendingKind, reason: String = "") -> Data? {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let denied = reason.isEmpty ? "Denied via Nook" : "Denied via Nook: " + reason
        let payload: [String: Any]
        switch kind {
        case .preToolUse:
            let value: String
            switch decision {
            case .allow, .always: value = "allow"
            case .deny: value = "deny"
            case .terminal: return nil
            }
            payload = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": value,
                    "permissionDecisionReason": value == "allow" ? "Approved via Nook" : denied
                ]
            ]
        case .appPrompt:
            return nil
        case .permission(let suggestions, let canAlways):
            var result: [String: Any]
            switch decision {
            case .allow:
                result = ["behavior": "allow"]
            case .always:
                result = ["behavior": "allow"]
                // Claude Code persists rule itself, just like "Yes, and don't ask again".
                if canAlways, let suggestions = suggestions as? [Any], !suggestions.isEmpty {
                    result["updatedPermissions"] = suggestions
                }
            case .deny:
                result = ["behavior": "deny", "message": denied]
            case .terminal:
                return nil
            }
            payload = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": result]]
        }
        return try? JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: Questions

    func askQuestion(
        key: String,
        record: inout Record,
        items: [AgentQuestionItem],
        raw: Any,
        connection: HookConnection
    ) {
        let id = UUID().uuidString
        let request = AgentQuestionRequest(id: id, sessionKey: key, agentName: record.agent, project: record.project, items: items)
        pendingQuestions[id] = PendingQuestion(request: request, connection: connection, rawQuestions: raw)
        record.status = .waiting
        Self.push(&record, .blocked, "question: " + Self.shorten(items[0].question, 60))

        connection.onPeerClosed { [weak self] in
            Task { @MainActor in
                self?.closeQuestion(id, response: nil, status: .running, step: (.done, "answered in the terminal"))
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.questionTimeout * 1_000_000_000)
            self?.closeQuestion(id, response: nil, status: .waiting, step: (.blocked, "question is in the terminal"))
        }
        onQuestion?(request)
    }

    func closeQuestion(
        _ id: String,
        response: Data?,
        status: AgentStatus?,
        step: (AgentStep.Mark, String)?,
        message: String? = nil
    ) {
        guard let pending = pendingQuestions.removeValue(forKey: id) else { return }
        pending.connection.reply(response)
        let key = pending.request.sessionKey
        if var record = records[key] {
            if let status, record.status == .waiting { record.status = status }
            if let step { Self.replaceLast(&record, step.0, step.1) }
            records[key] = record
        }
        rebuild()
        onQuestionGone?(id, message)
    }
}
