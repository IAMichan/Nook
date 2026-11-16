import Foundation

/// One Nook session's place on an OpenCode server (`OpenCodeServerHost`): its OpenCode session, what Nook set on it, and
/// what the running turn has told so far.
struct OpenCodeLink {
    struct Tool {
        var name: String
        var input: [String: Any]
    }

    /// The server's key in `openCodeHosts`.
    var host: String
    var directory: String
    var sessionID: String?
    /// The server is starting or the session is being read or made: a message waits in `warmPrompts`.
    var opening = true
    /// The session was just made: the next prompt carries the session instructions.
    var fresh = false
    /// What Nook set on the session, so only a change is sent before the next prompt.
    var appliedModel: String?
    var appliedAgent: String?
    var appliedRules: [OpenCodeServe.Rule]?
    /// The model the session runs, as OpenCode reports it ("provider/model").
    var currentModel: String?
    /// What you allowed "for this session" (`OpenCodeServe.grants`).
    var grants: [OpenCodeServe.Rule] = []
    /// Nook's bridge as this session's MCP server in OpenCode, once added.
    var bridgeServer: String?
    var prepared = false
    var models: [OpenCodeServe.Model] = []
    var commands: [AgentSlashCommand] = []
    /// The running turn's tool calls by id, with the tool's name and input (OpenCode reports them in steps).
    var tools: [String: Tool] = [:]
    /// Subagent sessions of this one, whose permission requests and questions are this session's.
    var children: Set<String> = []
    /// The turn's prompt went out: from now on the end of an execution is this turn's end.
    var promptSent = false
    /// Tokens and cost of the running turn so far.
    var usage = TurnUsage()
}

/// OpenCode over its own server (`opencode serve`, `OpenCodeServe`), for an OpenCode 2.0.18 or newer: one server
/// per account, shared by its sessions, that stays up while one of them is open. A turn is a prompt; the stream says
/// what happens and when the execution ends. Permission requests are answered with a reason when you deny, the agent's
/// questions come as forms, and Stop interrupts the session (`stopOpenCodeTurn`). An OpenCode without that server, or
/// whose server does not start, runs over ACP (`openCodeFallback`).
extension WorkspaceManager {
    private static let openCodeIdleSeconds: UInt64 = 10 * 60
    /// A server without sessions stops after this.
    private static let openCodeHostGraceSeconds: UInt64 = 60
    private static let openCodeInterruptSeconds: TimeInterval = 10

    /// Whether a session of this agent runs over OpenCode's server (`ProviderCapabilities.serverTransport`).
    func usesOpenCodeServer(_ run: WorkspaceRun, _ executable: String) -> Bool {
        switch run.provider.capabilities.serverTransport {
        case .openCodeServe:
            if openCodeLinks[run.id] != nil { return true }
            // The server runs on this Mac: a session on another machine keeps ACP.
            return settings.openCodeServer && !run.isRemote && !openCodeFallback.contains(executable)
        case .none:
            return false
        }
    }

    // MARK: Turns

    func launchOpenCodeTurn(_ id: UUID, prompt: String, executable: String, showPrompt: Bool) {
        guard var run = run(id) else { return }
        openCodeIdleClose.removeValue(forKey: id)?.cancel()
        if showPrompt { append(id, RunEvent(kind: .user, text: shownPrompt(id, prompt))) }
        turns[id] = TurnState()
        openCodeLinks[id]?.promptSent = false
        openCodeLinks[id]?.usage = TurnUsage()
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = turnStart(id)
        replace(run)
        recap?.prompt(session: "run-" + id.uuidString, project: run.projectName, agent: run.provider.displayName)

        if let link = openCodeLinks[id], openCodeHosts[link.host]?.isRunning == true {
            // Open already (warmed up, or idle after a turn): the prompt goes at once, or as soon as the session is open.
            if !link.opening, link.sessionID != nil { sendOpenCodePrompt(id, prompt: prompt) } else { warmPrompts[id] = prompt }
            return
        }
        connectOpenCode(id, executable: executable, prompt: prompt)
    }

    /// Starts (or reuses) the account's server and opens the session on it. With a prompt it is sent once the session
    /// is open; without one (warming up when you open the session) the session waits for your first message.
    func connectOpenCode(_ id: UUID, executable: String, prompt: String?) {
        guard let run = run(id) else { return }
        let host = openCodeHost(run, executable: executable)
        openCodeLinks[id] = OpenCodeLink(host: host.key, directory: run.workingDirectory)
        if let prompt {
            warmPrompts[id] = prompt
            let program = (executable as NSString).lastPathComponent
            append(id, RunEvent(kind: .system, text: ([program] + OpenCodeServe.arguments).joined(separator: " "), tool: "launch"))
        }
        host.whenReady { [weak self] result in
            guard let self, self.openCodeLinks[id]?.host == host.key else { return }
            switch result {
            case .success: self.openOpenCodeSession(id)
            case .failure(let error): self.openCodeStartFailed(id, error, executable: executable)
            }
        }
    }

    /// The account's server: the running one, or a new one.
    private func openCodeHost(_ run: WorkspaceRun, executable: String) -> OpenCodeServerHost {
        let key = executable + "|" + run.profileID
        openCodeHostStops.removeValue(forKey: key)?.cancel()
        if let host = openCodeHosts[key], host.isRunning { return host }
        let host = OpenCodeServerHost(key: key, executable: executable)
        host.onEvents = { [weak self] events in self?.handleOpenCode(key, events) }
        host.onReconnected = { [weak self] in self?.openCodeReconnected(key) }
        host.onGone = { [weak self] message in self?.openCodeHostGone(key, message) }
        openCodeHosts[key] = host
        var environment = accountEnvironment(run.profileID)
        environment.merge(SudoAskpass.launchEnvironment()) { _, new in new }
        host.start(environment: environment, workingDirectory: NSHomeDirectory())
        return host
    }

    /// The server could not be used: this OpenCode runs over ACP from now on (until Nook restarts), and a waiting message
    /// goes there.
    private func openCodeStartFailed(_ id: UUID, _ error: OpenCodeServerError, executable: String) {
        let link = openCodeLinks.removeValue(forKey: id)
        if let key = link?.host, openCodeHosts[key]?.isRunning != true { openCodeHosts[key] = nil }
        openCodeFallback.insert(executable)
        let waiting = warmPrompts.removeValue(forKey: id)
        if turns[id]?.stopping == true { return openCodeStopped(id) }
        guard let waiting, turns[id] != nil else { return }
        turns[id] = nil
        let reason: String
        switch error {
        case .unsupported: reason = tr("ws.opencode.fallback")
        case .launch, .timeout, .exited: reason = tr("ws.opencode.serverFailed", error.localizedDescription)
        }
        append(id, RunEvent(kind: .system, text: reason))
        launchTurn(id, prompt: waiting, executable: executable, showPrompt: false)
    }

    /// The session continues when OpenCode still has it, else a new one starts (with what happened so far ahead of your
    /// message, as for an ACP agent that lost it). Then its models, commands and Nook's bridge are set up, and a waiting
    /// message goes out.
    private func openOpenCodeSession(_ id: UUID) {
        guard let run = run(id), let link = openCodeLinks[id], let host = openCodeHosts[link.host] else { return }
        Task {
            var sessionID: String?
            if let known = run.providerSessionID, !known.isEmpty {
                let reply = await host.send("GET", "/api/session/\(known)")
                guard self.openCodeLinks[id]?.host == host.key else { return }
                if reply.ok, let info = OpenCodeServe.session(reply.json?.object) {
                    sessionID = info.id
                    self.openCodeLinks[id]?.currentModel = info.model
                } else if reply.notFound {
                    self.append(id, RunEvent(kind: .system, text: tr("ws.acp.noLoad", run.provider.displayName)))
                    self.update(id) { $0.providerSessionID = nil }
                    if let waiting = self.warmPrompts[id] { self.warmPrompts[id] = self.carryOverConversation(id, prompt: waiting) }
                } else {
                    return self.openCodeOpenFailed(id, reply.error)
                }
            }
            if sessionID == nil {
                let rules = self.openCodeRules(id)
                let model = OpenCodeServe.modelRef(run.model, effort: run.effort)
                let agent = OpenCodeServe.agent(for: run.mode)
                let body = OpenCodeServe.newSessionBody(directory: run.workingDirectory, model: model, agent: agent, rules: rules)
                let reply = await host.send("POST", "/api/session", body: body)
                guard self.openCodeLinks[id]?.host == host.key else { return }
                guard reply.ok, let info = OpenCodeServe.session(reply.json?.object) else { return self.openCodeOpenFailed(id, reply.error) }
                sessionID = info.id
                self.openCodeLinks[id]?.fresh = true
                self.openCodeLinks[id]?.appliedRules = rules
                self.openCodeLinks[id]?.appliedAgent = agent
                self.openCodeLinks[id]?.currentModel = info.model
                if model != nil { self.openCodeLinks[id]?.appliedModel = Self.openCodeModelKey(run) }
            }
            guard let sessionID else { return }
            self.openCodeLinks[id]?.sessionID = sessionID
            self.update(id) { $0.providerSessionID = sessionID }
            await self.prepareOpenCodeSession(id)
            guard self.openCodeLinks[id]?.host == host.key else { return }
            self.openCodeLinks[id]?.opening = false
            if self.turns[id]?.stopping == true {
                self.warmPrompts[id] = nil
                return self.openCodeStopped(id)
            }
            if let next = self.warmPrompts.removeValue(forKey: id), self.turns[id] != nil {
                self.sendOpenCodePrompt(id, prompt: next)
            } else {
                self.scheduleOpenCodeIdleClose(id)
            }
        }
    }

    private func openCodeOpenFailed(_ id: UUID, _ message: String?) {
        let waiting = warmPrompts.removeValue(forKey: id)
        closeOpenCodeSession(id)
        if turns[id]?.stopping == true { return openCodeStopped(id) }
        guard waiting != nil, turns[id] != nil else { return }
        failOpenCodeTurn(id, WorkspaceManager.cleanError(message ?? "", status: 1))
    }

    /// Once per open session: the models and commands OpenCode offers in this folder (a project can add its own), and
    /// Nook's bridge as an MCP server that only this session may use.
    private func prepareOpenCodeSession(_ id: UUID) async {
        guard let link = openCodeLinks[id], !link.prepared, let host = openCodeHosts[link.host], let run = run(id) else { return }
        openCodeLinks[id]?.prepared = true
        let location = OpenCodeServe.locationQuery(link.directory)
        async let modelsReply = host.send("GET", "/api/model", query: location)
        async let defaultReply = host.send("GET", "/api/model/default", query: location)
        async let commandsReply = host.send("GET", "/api/command", query: location)
        let (models, fallback, commands) = await (modelsReply, defaultReply, commandsReply)
        let offered = OpenCodeServe.models(models.json?.object)
        let standard = OpenCodeServe.models(fallback.json?.object).first?.id
        openCodeLinks[id]?.models = offered
        learnModels(run.provider, offered.map { AgentModel(id: $0.id, name: $0.name, isDefault: $0.id == standard) }, profileID: run.profileID)
        learnOpenCodeEfforts(id)
        let listed = OpenCodeServe.commands(commands.json?.object)
        openCodeLinks[id]?.commands = listed
        if acpCommands[id] != listed { acpCommands[id] = listed }
        if let launch = bridge(for: id) {
            let name = OpenCodeServe.bridgeServer(runID: id)
            let config = OpenCodeServe.bridgeConfig(command: launch.script, arguments: ["--agent", run.provider.rawValue],
                                                    environment: launch.environment(runID: id))
            let reply = await host.send("PUT", "/api/experimental/mcp/\(name)", query: location, body: config)
            if reply.ok { openCodeLinks[id]?.bridgeServer = name }
        }
    }

    /// The effort levels of the session's model: its variants.
    private func learnOpenCodeEfforts(_ id: UUID) {
        guard let run = run(id), let link = openCodeLinks[id] else { return }
        let model = run.model.isEmpty ? link.currentModel : run.model
        guard let variants = link.models.first(where: { $0.id == model })?.variants, !variants.isEmpty else { return }
        learnEfforts(run.provider, variants.map { AgentModel(id: $0, name: $0) }, profileID: run.profileID)
        if let window = link.models.first(where: { $0.id == model })?.contextWindow { turns[id]?.contextWindow = window }
    }

    private static func openCodeModelKey(_ run: WorkspaceRun) -> String {
        run.model + "|" + (run.effort ?? "")
    }

    private func openCodeRules(_ id: UUID) -> [OpenCodeServe.Rule] {
        guard let run = run(id) else { return [] }
        let link = openCodeLinks[id]
        return OpenCodeServe.rules(permission: run.permission, mode: run.mode, grants: link?.grants ?? [], bridgeServer: link?.bridgeServer)
    }

    /// Sets the run's model (with its effort as the variant), agent (build or plan) and rights on the session, each only
    /// when it changed. Also during a turn (`applyLive`): OpenCode uses them from its next step.
    func applyOpenCodeSettings(_ id: UUID) async {
        guard let run = run(id), let link = openCodeLinks[id], let session = link.sessionID, let host = openCodeHosts[link.host] else { return }
        let model = run.model.isEmpty ? link.currentModel : run.model
        let key = Self.openCodeModelKey(run)
        if key != link.appliedModel, !run.model.isEmpty || run.effort != nil || link.appliedModel != nil,
           let model, let ref = OpenCodeServe.modelRef(model, effort: run.effort) {
            openCodeLinks[id]?.appliedModel = key
            let reply = await host.send("POST", "/api/session/\(session)/model", body: ["model": ref])
            if !reply.ok {
                let name = offeredModels(run.provider, profileID: run.profileID).first { $0.id == model }?.name ?? model
                append(id, RunEvent(kind: .system, text: tr("ws.acp.modelFailed", run.provider.displayName, name)))
            }
        }
        let agent = OpenCodeServe.agent(for: run.mode)
        if agent != openCodeLinks[id]?.appliedAgent {
            openCodeLinks[id]?.appliedAgent = agent
            _ = await host.send("POST", "/api/session/\(session)/agent", body: ["agent": agent])
        }
        let rules = openCodeRules(id)
        if rules != openCodeLinks[id]?.appliedRules {
            openCodeLinks[id]?.appliedRules = rules
            _ = await host.send("PATCH", "/api/session/\(session)", body: ["permissions": rules.map(\.json)])
        }
        learnOpenCodeEfforts(id)
    }

    private func sendOpenCodePrompt(_ id: UUID, prompt: String) {
        Task {
            await self.applyOpenCodeSettings(id)
            guard let run = self.run(id), let link = self.openCodeLinks[id], let session = link.sessionID,
                  let host = self.openCodeHosts[link.host], self.turns[id] != nil else { return }
            // Stopped while the settings went out: the prompt never went.
            if self.turns[id]?.stopping == true { return self.openCodeStopped(id) }
            self.openCodeLinks[id]?.promptSent = true
            let reply: OpenCodeReply
            if let command = OpenCodeServe.command(in: prompt, known: link.commands) {
                // OpenCode's own `/` commands: `/compact` summarizes, the others (`/goal`, `/review`, a project's) run.
                if command.name == "compact" {
                    reply = await host.send("POST", "/api/session/\(session)/compact", body: [String: Any]())
                } else {
                    reply = await host.send("POST", "/api/session/\(session)/command", body: ["name": command.name, "text": command.text])
                }
            } else {
                var text = prompt
                // Your instructions, and how to use Nook's tools, go with the first prompt of a new session (as for ACP).
                let instructions = AgentCredits.launchInstructions(self.launchInstructions(run), bridgeNote: self.bridge(for: id)?.note)
                if link.fresh, !instructions.isEmpty { text = instructions + "\n\n" + text }
                self.openCodeLinks[id]?.fresh = false
                // Pictures you added go as files OpenCode reads itself; one that is gone would fail the whole prompt.
                let pictures = ImageAttachment.splittingPaths(from: prompt).images.map(\.path)
                    .filter { FileManager.default.fileExists(atPath: $0) }
                reply = await host.send("POST", "/api/session/\(session)/prompt", body: OpenCodeServe.promptBody(text: text, files: pictures))
            }
            guard !reply.ok, self.turns[id] != nil, self.openCodeLinks[id]?.sessionID == session else { return }
            if self.turns[id]?.stopping == true { return self.openCodeStopped(id) }
            self.failOpenCodeTurn(id, WorkspaceManager.cleanError(reply.error ?? "", status: 1))
        }
    }

    // MARK: Stop

    /// Stops the turn: `interrupt`, which answers whether anything ran. The turn ends with the execution's end; an
    /// interrupt that nothing answers leaves it to the stop clock, whose force stop ends it in Nook (`beginStop`).
    func stopOpenCodeTurn(_ id: UUID) -> Bool {
        guard let link = openCodeLinks[id], run(id)?.status.isActive == true else { return false }
        if turns[id]?.stopping == true { return true }
        turns[id]?.stopping = true
        cancelOpenCodeRequests(id, answer: false)
        expireApprovals(id)
        dropOpenCodeQuestions(id)
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopping")))
        // Still opening: the open ends as stopped.
        guard let session = link.sessionID, !link.opening, let host = openCodeHosts[link.host] else { return true }
        // The prompt never went (the settings were still going out): stopped here.
        guard link.promptSent else {
            openCodeStopped(id)
            return true
        }
        Task {
            let reply = await host.send("POST", "/api/session/\(session)/interrupt", timeout: Self.openCodeInterruptSeconds)
            guard self.turns[id]?.stopping == true, self.openCodeLinks[id]?.sessionID == session else { return }
            // Nothing was running any more: the end of the execution may never come.
            if reply.ok, OpenCodeServe.interrupted(reply.json?.object) == false { self.finishOpenCodeTurn(id, .interrupted(reason: "user")) }
        }
        return true
    }

    /// The stop clock gave up on the interrupt (`forceFinalizeStop`): the turn ends in Nook, the session is asked once
    /// more to stop, and its link closes so whatever it still does is not followed (the next message opens it again).
    func forceStopOpenCode(_ id: UUID) {
        guard let link = openCodeLinks[id] else { return }
        if let session = link.sessionID, let host = openCodeHosts[link.host] {
            Task { _ = await host.send("POST", "/api/session/\(session)/interrupt", timeout: Self.openCodeInterruptSeconds) }
        }
        closeOpenCodeSession(id)
    }

    /// The turn you stopped is over.
    private func openCodeStopped(_ id: UUID) {
        pauseLive(id)
        expireApprovals(id)
        dropOpenCodeQuestions(id)
        turns[id] = nil
        openCodeLinks[id]?.promptSent = false
        settleOpenWork(id, reason: .stopped)
        update(id) { $0.move(to: .stopped) }
        append(id, RunEvent(kind: .system, text: tr("ws.event.stopped")))
        sendPendingNow(id)
        scheduleOpenCodeIdleClose(id)
    }

    // MARK: Approvals and Questions

    /// Answers an OpenCode permission request. A denial carries your reason (or a plain "declined"), so the turn goes on
    /// without the action; "Always" allows what OpenCode offered to save for the rest of this session.
    func decideOpenCode(_ runID: UUID, requestID: String, _ decision: Decision, reason: String) -> Bool {
        guard let request = openCodeRequests.removeValue(forKey: requestID) else { return false }
        let pending = approvals[runID]?.first { $0.id == requestID }
        approvals[runID]?.removeAll { $0.id == requestID }
        recap?.decision(allowed: decision != .deny)
        if let pending { mutateEvent(runID, pending.eventID) { $0.state = decision == .deny ? .denied : .allowed } }
        if (approvals[runID]?.isEmpty ?? true), !waitsOnQuestion(runID) { update(runID) { $0.move(to: .running) } }
        onApprovalGone?(requestID)
        if decision == .deny, !reason.isEmpty { append(runID, RunEvent(kind: .system, text: tr("ws.approval.deniedBecause", reason))) }
        guard let link = openCodeLinks[runID], let host = openCodeHosts[link.host] else { return true }
        let permission = request.permission
        Task {
            if decision == .always {
                for grant in OpenCodeServe.grants(action: permission.action, save: permission.save)
                where !(self.openCodeLinks[runID]?.grants.contains(grant) ?? true) {
                    self.openCodeLinks[runID]?.grants.append(grant)
                }
                await self.applyOpenCodeSettings(runID)
            }
            let reply = await host.send("POST", "/api/session/\(permission.sessionID)/permission/\(permission.id)/reply",
                                        body: OpenCodeServe.permissionReply(allow: decision != .deny, reason: reason))
            if !reply.ok, !reply.notFound {
                self.append(runID, RunEvent(kind: .error, text: tr("ws.opencode.answerFailed", reply.error ?? "")))
            }
        }
        return true
    }

    /// Answers a question OpenCode asked as a form.
    func answerOpenCode(_ runID: UUID, form: OpenCodeForm, answers: [String: [String]]) {
        guard let link = openCodeLinks[runID], let host = openCodeHosts[link.host] else { return }
        Task {
            let reply = await host.send("POST", "/api/session/\(form.sessionID)/form/\(form.id)/reply",
                                        body: OpenCodeServe.formAnswer(form, answers: answers))
            if !reply.ok, !reply.notFound {
                self.append(runID, RunEvent(kind: .error, text: tr("ws.opencode.answerFailed", reply.error ?? "")))
            }
        }
    }

    /// Permission requests of this session still waiting: answered as denied (`answer`) or only forgotten.
    private func cancelOpenCodeRequests(_ id: UUID, answer: Bool) {
        for (key, request) in openCodeRequests where request.runID == id {
            openCodeRequests[key] = nil
            guard answer, let link = openCodeLinks[id], let host = openCodeHosts[link.host] else { continue }
            let permission = request.permission
            Task { _ = await host.send("POST", "/api/session/\(permission.sessionID)/permission/\(permission.id)/reply",
                                       body: ["decision": "reject"]) }
        }
    }

    private func dropOpenCodeQuestions(_ id: UUID) {
        guard let list = questions[id] else { return }
        let left = list.filter { if case .openCode = $0.origin { return false } else { return true } }
        if left.count != list.count { questions[id] = left.isEmpty ? nil : left }
    }

    private func presentOpenCodePermission(_ id: UUID, _ permission: OpenCodePermission) {
        guard let run = run(id) else { return }
        pauseLive(id)
        let requestID = "oc-" + permission.id
        guard openCodeRequests[requestID] == nil else { return }
        let subject = permission.resources.joined(separator: ", ")
        var input: [String: Any] = ["action": permission.action]
        switch permission.action {
        case "shell": input["command"] = subject
        case "edit", "read", "external_directory": input["path"] = permission.resources.first ?? ""
        default: input["resources"] = permission.resources
        }
        let tool = permission.action == "edit" ? "Edit" : permission.action
        let summary = subject.isEmpty ? permission.action : permission.action + " · " + ToolSummary.oneLine(subject, 200)
        let event = RunEvent(kind: .approval, text: summary, tool: tool, callID: requestID, detail: ToolSummary.json(input), state: .pending)
        append(id, event)
        let pending = PendingPermission(id: requestID, runID: id, tool: tool, summary: summary, input: JSONBox(input),
                                        suggestions: JSONBox(["always"]), eventID: event.id, created: Date(),
                                        ask: PermissionAsk(reason: permission.message ?? ""))
        openCodeRequests[requestID] = (id, permission)
        approvals[id, default: []].append(pending)
        update(id) { $0.move(to: .waitingApproval) }
        onApproval?(run, pending)
    }

    private func presentOpenCodeForm(_ id: UUID, _ form: OpenCodeForm) {
        if form.unsupported != nil {
            // Nook cannot show it (a link to open, a number, a field that depends on another): OpenCode hears it was
            // cancelled, and the timeline says so.
            append(id, RunEvent(kind: .system, text: tr("ws.opencode.formUnsupported")))
            guard let link = openCodeLinks[id], let host = openCodeHosts[link.host] else { return }
            Task { _ = await host.send("DELETE", "/api/session/\(form.sessionID)/form/\(form.id)") }
            return
        }
        pauseLive(id)
        let pending = PendingQuestion(id: "ocform-" + form.id, runID: id, questions: form.questions, origin: .openCode(form), created: Date())
        guard !(questions[id] ?? []).contains(where: { $0.id == pending.id }) else { return }
        questions[id, default: []].append(pending)
        update(id) { $0.move(to: .waitingApproval) }
        asked(id, pending)
    }

    // MARK: Events

    private func handleOpenCode(_ key: String, _ events: [OpenCodeEvent]) {
        for event in events {
            guard let session = event.sessionID else { continue }
            if let found = openCodeRun(key, session: session) {
                if found.child {
                    applyOpenCodeChild(found.id, event)
                } else {
                    applyOpenCode(found.id, event)
                }
                continue
            }
            // A subagent's session asks: it is found through its parent.
            switch event {
            case .permission, .form: adoptOpenCodeChild(key, session: session, event)
            default: continue
            }
        }
    }

    private func openCodeRun(_ key: String, session: String) -> (id: UUID, child: Bool)? {
        for (id, link) in openCodeLinks where link.host == key {
            if link.sessionID == session { return (id, false) }
            if link.children.contains(session) { return (id, true) }
        }
        return nil
    }

    private func adoptOpenCodeChild(_ key: String, session: String, _ event: OpenCodeEvent) {
        guard let host = openCodeHosts[key] else { return }
        Task {
            let reply = await host.send("GET", "/api/session/\(session)")
            guard let parent = OpenCodeServe.session(reply.json?.object)?.parentID,
                  let id = self.openCodeRun(key, session: parent)?.id else { return }
            self.openCodeLinks[id]?.children.insert(session)
            self.applyOpenCodeChild(id, event)
        }
    }

    /// What a subagent's session says that is this session's business: its requests and questions.
    private func applyOpenCodeChild(_ id: UUID, _ event: OpenCodeEvent) {
        switch event {
        case .permission, .form, .permissionSettled, .formSettled: applyOpenCode(id, event)
        default: break
        }
    }

    private func applyOpenCode(_ id: UUID, _ event: OpenCodeEvent) {
        guard run(id) != nil else { return }
        switch event {
        case .executionStarted:
            // Work the session started without a message of yours (another client's prompt, a scheduled one).
            if turns[id] == nil, run(id)?.status.isActive != true { wakeOpenCode(id) }
            return
        case .executionEnded(_, let outcome):
            guard turns[id] != nil, openCodeLinks[id]?.promptSent == true || turns[id]?.unprompted == true
                    || turns[id]?.stopping == true else { return }
            return finishOpenCodeTurn(id, outcome)
        case .permission(let permission):
            // Outside a turn (after a force stop) nobody answers: the rejection without a message ends that execution.
            guard turns[id] != nil, turns[id]?.stopping != true else {
                if let link = openCodeLinks[id], let host = openCodeHosts[link.host] {
                    Task { _ = await host.send("POST", "/api/session/\(permission.sessionID)/permission/\(permission.id)/reply",
                                               body: ["decision": "reject"]) }
                }
                return
            }
            return presentOpenCodePermission(id, permission)
        case .permissionSettled(_, let request):
            // Answered elsewhere (OpenCode's own app on the same server): the card goes.
            let requestID = "oc-" + request
            if openCodeRequests.removeValue(forKey: requestID) != nil {
                expireApproval(id, requestID: requestID)
                if (approvals[id]?.isEmpty ?? true), !waitsOnQuestion(id), turns[id] != nil { update(id) { $0.move(to: .running) } }
            }
            return
        case .form(let form):
            guard turns[id] != nil, turns[id]?.stopping != true else {
                if let link = openCodeLinks[id], let host = openCodeHosts[link.host] {
                    Task { _ = await host.send("DELETE", "/api/session/\(form.sessionID)/form/\(form.id)") }
                }
                return
            }
            return presentOpenCodeForm(id, form)
        case .formSettled(_, let formID):
            if let list = questions[id], list.contains(where: { $0.id == "ocform-" + formID }) {
                let left = list.filter { $0.id != "ocform-" + formID }
                questions[id] = left.isEmpty ? nil : left
                if (approvals[id]?.isEmpty ?? true), !waitsOnQuestion(id), turns[id] != nil { update(id) { $0.move(to: .running) } }
            }
            return
        case .modelSelected(_, let model, _):
            openCodeLinks[id]?.currentModel = model
            if run(id)?.resolvedModel != model { update(id) { $0.resolvedModel = model } }
            return
        default:
            break
        }
        // The rest is the work of a turn; after one (a force stop) it is not followed any more.
        guard turns[id] != nil else { return }
        switch event {
        case .textDelta(_, let item, let thinking, let text):
            if thinking {
                feed(id, .thinkingDelta(text, item: item))
            } else {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { turns[id]?.acpReplied = true }
                feed(id, .textDelta(text, item: item))
            }
        case .textDone(_, let item, let thinking, let text):
            if thinking {
                feed(id, .thinking(text, item: item))
            } else {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { turns[id]?.acpReplied = true }
                feed(id, .text(text, item: item))
            }
        case .toolStarted(_, let call, let name):
            // A question shows as the question panel, not as a step.
            guard name != "question" else { return }
            openCodeLinks[id]?.tools[call] = OpenCodeLink.Tool(name: name, input: [:])
            feed(id, .toolStarted(AgentToolCall(id: call, name: OpenCodeTools.name(name), title: name)))
        case .toolCalled(_, let call, let input):
            guard let tool = openCodeLinks[id]?.tools[call] else { return }
            openCodeLinks[id]?.tools[call]?.input = input.dictionary
            let directory = openCodeLinks[id]?.directory ?? ""
            let mapped = OpenCodeTools.input(tool: tool.name, input.dictionary, directory: directory)
            feed(id, .toolStarted(AgentToolCall(id: call, name: OpenCodeTools.name(tool.name),
                                                title: ToolSummary.describe(tool: tool.name, input: mapped),
                                                detail: ToolSummary.json(input.object), input: JSONBox(mapped))))
        case .toolSucceeded(_, let call, let output, let metadata):
            guard let tool = openCodeLinks[id]?.tools[call] else { return }
            let directory = openCodeLinks[id]?.directory ?? ""
            let paths = OpenCodeTools.changedPaths(tool: tool.name, input: tool.input, metadata: metadata.dictionary, directory: directory)
            // A command OpenCode moved to the background reports success at once and keeps running.
            let running = (metadata.dictionary["status"] as? String) == "running"
            feed(id, .toolUpdated(id: call, output: output.isEmpty ? nil : output, state: running ? .running : .done, paths: paths))
        case .toolFailed(_, let call, _, let message):
            guard openCodeLinks[id]?.tools[call] != nil else { return }
            feed(id, .toolUpdated(id: call, output: message.isEmpty ? nil : message, state: .failed))
        case .stepEnded(_, let tokens, let cost):
            guard var usage = openCodeLinks[id]?.usage else { return }
            if let tokens {
                usage.inputTokens = (usage.inputTokens ?? 0) + tokens.input
                usage.outputTokens = (usage.outputTokens ?? 0) + tokens.output + tokens.reasoning
                usage.cacheReadTokens = (usage.cacheReadTokens ?? 0) + tokens.cacheRead
                usage.cacheWriteTokens = (usage.cacheWriteTokens ?? 0) + tokens.cacheWrite
                turns[id]?.lastContext = tokens.context
            }
            if let cost { usage.reportedCostUSD = (usage.reportedCostUSD ?? 0) + cost }
            openCodeLinks[id]?.usage = usage
        case .retrying(_, let message):
            append(id, RunEvent(kind: .system, text: message.isEmpty ? tr("pi.event.retrying") : tr("pi.event.retrying") + " " + message))
        case .compactionStarted:
            compactionStarted(id)
        case .compactionEnded(_, let failed):
            if let failed { compactionFailed(id, message: failed.isEmpty ? nil : failed) } else { compactionFinished(id) }
        default:
            break
        }
    }

    /// The session works without a message of yours: a live turn of its own, ended by the execution's end.
    private func wakeOpenCode(_ id: UUID) {
        guard var run = run(id) else { return }
        openCodeIdleClose.removeValue(forKey: id)?.cancel()
        var state = TurnState()
        state.unprompted = true
        turns[id] = state
        openCodeLinks[id]?.usage = TurnUsage()
        append(id, RunEvent(kind: .system, text: tr("ws.wake.background"), tool: "wake"))
        if run.status == .completed || run.status == .failed || run.status == .stopped { run.move(to: .preparing) }
        run.move(to: .running)
        run.turnStartedAt = turnStart(id, continuing: true)
        replace(run)
    }

    private func finishOpenCodeTurn(_ id: UUID, _ outcome: OpenCodeEvent.Outcome) {
        guard let state = turns[id] else { return }
        pauseLive(id)
        var usage = openCodeLinks[id]?.usage ?? TurnUsage()
        usage.contextTokens = state.lastContext
        usage.contextWindow = state.contextWindow
        usage.durationSeconds = Date().timeIntervalSince(state.started)
        turns[id] = nil
        openCodeLinks[id]?.usage = TurnUsage()
        openCodeLinks[id]?.promptSent = false
        openCodeLinks[id]?.tools = [:]
        cancelOpenCodeRequests(id, answer: false)
        dropOpenCodeQuestions(id)
        var failure: (kind: String, message: String)?
        if case .failed(let kind, let message) = outcome { failure = (kind, message) }
        var stopped = state.stopping
        if case .interrupted = outcome { stopped = true }
        if stopped { failure = nil }
        let detail = failure.map { failure -> String in
            let text = WorkspaceManager.cleanError(failure.message.isEmpty ? failure.kind : failure.message, status: 1)
            let command = run(id)?.provider.kind.loginCommand ?? ""
            return failure.kind.contains("auth") && !command.isEmpty ? text + " " + tr("ws.acp.login", command) : text
        }
        update(id) { run in
            run.usage.add(usage)
            if stopped { run.move(to: .stopped) } else if let detail { run.move(to: .failed, detail: detail) } else { run.move(to: .completed) }
        }
        if stopped { append(id, RunEvent(kind: .system, text: tr("ws.event.stopped"))) }
        if let detail, let failure {
            append(id, RunEvent(kind: .error, text: detail))
            noteFailure(id, text: failure.message)
        }
        // A turn that ends without a word should not look like an answer.
        if !stopped, failure == nil, !state.acpReplied, !state.unprompted {
            append(id, RunEvent(kind: .system, text: tr("ws.acp.silent", run(id)?.provider.displayName ?? "")))
        }
        append(id, RunEvent(kind: .result, text: resultLine(usage, denials: 0, for: id), state: failure != nil ? .failed : .done))
        expireApprovals(id)
        turnDidFinish(id)
        scheduleGitRefresh(id, delay: 0.5)
        if !sendPendingNow(id) { sendQueued(id) }
        scheduleOpenCodeIdleClose(id)
    }

    private func failOpenCodeTurn(_ id: UUID, _ message: String) {
        pauseLive(id)
        cancelOpenCodeRequests(id, answer: false)
        expireApprovals(id)
        dropOpenCodeQuestions(id)
        turns[id] = nil
        openCodeLinks[id]?.promptSent = false
        update(id) { $0.move(to: .failed, detail: message) }
        append(id, RunEvent(kind: .error, text: message))
        noteFailure(id, text: message)
        turnDidFinish(id)
    }

    // MARK: Connection

    /// The stream was gone for a moment: a turn whose end was missed ends now, and requests asked meanwhile show.
    private func openCodeReconnected(_ key: String) {
        guard let host = openCodeHosts[key] else { return }
        for (id, link) in openCodeLinks where link.host == key && turns[id] != nil {
            guard let session = link.sessionID else { continue }
            Task {
                let info = await host.send("GET", "/api/session/\(session)")
                if let state = OpenCodeServe.session(info.json?.object), !state.busy, self.turns[id] != nil,
                   self.openCodeLinks[id]?.promptSent == true {
                    switch state.outcome {
                    case "interrupted": self.finishOpenCodeTurn(id, .interrupted(reason: "user"))
                    case "failed": self.finishOpenCodeTurn(id, .failed(kind: "", message: tr("ws.opencode.lostEnd")))
                    default: self.finishOpenCodeTurn(id, .succeeded)
                    }
                    return
                }
                let pending = await host.send("GET", "/api/session/\(session)/permission")
                for item in (pending.json?.dictionary["data"] as? [[String: Any]]) ?? [] {
                    guard let permission = OpenCodePermission(item), self.turns[id] != nil else { continue }
                    self.presentOpenCodePermission(id, permission)
                }
            }
        }
    }

    /// The server ended (or stopped talking): its sessions' turns fail with what it said, and the next message starts it
    /// again.
    private func openCodeHostGone(_ key: String, _ message: String) {
        openCodeHosts[key] = nil
        for (id, link) in openCodeLinks where link.host == key {
            let active = turns[id] != nil
            let stopping = turns[id]?.stopping == true
            closeOpenCodeSession(id)
            if stopping {
                openCodeStopped(id)
            } else if active {
                failOpenCodeTurn(id, WorkspaceManager.cleanError(message, status: 1))
            }
        }
    }

    /// An idle session lets go of the server after a while; the next message opens it again (OpenCode keeps it).
    private func scheduleOpenCodeIdleClose(_ id: UUID) {
        openCodeIdleClose[id]?.cancel()
        let seconds = idleSeconds(id, Self.openCodeIdleSeconds)
        openCodeIdleClose[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.run(id)?.status.isActive != true else { return }
            self.closeOpenCodeSession(id)
        }
    }

    /// Lets go of a session: its bridge leaves OpenCode, and a server no session uses any more stops after a grace.
    func closeOpenCodeSession(_ id: UUID) {
        openCodeIdleClose.removeValue(forKey: id)?.cancel()
        cancelOpenCodeRequests(id, answer: false)
        guard let link = openCodeLinks.removeValue(forKey: id) else { return }
        warmPrompts[id] = nil
        guard let host = openCodeHosts[link.host] else { return }
        if let server = link.bridgeServer {
            let location = OpenCodeServe.locationQuery(link.directory)
            Task { _ = await host.send("DELETE", "/api/experimental/mcp/\(server)", query: location, timeout: 5) }
        }
        guard !openCodeLinks.values.contains(where: { $0.host == link.host }) else { return }
        let key = link.host
        openCodeHostStops[key]?.cancel()
        openCodeHostStops[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.openCodeHostGraceSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.openCodeLinks.values.contains(where: { $0.host == key }) else { return }
            self.openCodeHostStops[key] = nil
            self.openCodeHosts.removeValue(forKey: key)?.stop()
        }
    }

    /// Nook quits: every server stops (each is an agent process, so the quit also waits for it, `QuitShutdown`).
    func closeOpenCodeServers() {
        for id in Array(openCodeLinks.keys) { closeOpenCodeSession(id) }
        for task in openCodeHostStops.values { task.cancel() }
        openCodeHostStops.removeAll()
        for host in openCodeHosts.values { host.stop() }
        openCodeHosts.removeAll()
    }
}
