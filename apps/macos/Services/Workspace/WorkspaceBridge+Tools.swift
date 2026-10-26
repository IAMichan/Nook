import Foundation
import AppKit

/// The newer bridge tools: scheduled tasks, pull request watches, clicking and typing in Nook's browser, and asking the
/// user for a secret. The arguments and rules are checked in WorkspaceBridgeArguments and BridgePolicy; this file does
/// the work, with the same approval cards and audit entries as the other tools.
extension WorkspaceBridge {
    // MARK: Retries

    /// Runs `body` once per client_request_id: a retry gets the first answer, and a retry while the first call still
    /// waits for the user gets no second card. Refusals and failures are not remembered, so they can be tried again.
    func once(_ tool: BridgeTool, _ arguments: [String: Any], _ caller: BridgeCaller,
              _ body: () async throws -> BridgeRPC.ToolResult) async throws -> BridgeRPC.ToolResult {
        guard let key = BridgeRequestLedger.key(caller: caller.key, tool: tool, requestID: arguments["client_request_id"]) else {
            return try await body()
        }
        switch ledger.claim(key) {
        case .done(let answer):
            return BridgeRPC.ToolResult(text: answer)
        case .inFlight:
            return .error("The first call with this client_request_id is still waiting for the user's decision. Wait for its answer instead of calling again.")
        case .new:
            break
        }
        do {
            let result = try await body()
            if result.isError { ledger.abandon(key) } else { ledger.finish(key, answer: result.text) }
            return result
        } catch {
            ledger.abandon(key)
            throw error
        }
    }

    // MARK: Scheduled tasks

    /// The session behind a call, when Nook started it.
    private func runID(_ caller: BridgeCaller) -> UUID? {
        if case .run(let id) = caller.kind { return id }
        return nil
    }

    func listScheduledTasks(_ arguments: [String: Any], _ caller: BridgeCaller) -> BridgeRPC.ToolResult {
        let store = ScheduledTaskStore.shared
        let all = BridgeArgs.bool(arguments["all"]) ?? false
        let folder = WorkspacePathPolicy.normalize(caller.directory)
        let session = runID(caller)
        let tasks = store.tasks.filter { task in
            if all { return true }
            switch task.target {
            case .newSession(let path, _, _): return !folder.isEmpty && WorkspacePathPolicy.normalize(path) == folder
            case .existingSession(let id): return id == session
            }
        }
        var lines = [store.isEnabled ? "Scheduled tasks are switched on."
                                     : "Scheduled tasks are switched off in Nook's settings: nothing runs until the user switches them on."]
        if tasks.isEmpty {
            lines.append(all ? "There are no scheduled tasks." : "No scheduled tasks for your folder or session (all: true lists every task).")
        }
        for task in tasks {
            lines.append(BridgeScheduleArguments.render(task, permission: store.permission(for: task.id), running: store.isRunning(task.id)))
        }
        return BridgeRPC.ToolResult(text: lines.joined(separator: "\n"))
    }

    func scheduleTask(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async throws -> BridgeRPC.ToolResult {
        if case .refuse(let reason) = verdict(.scheduleTask, caller) { return .error(Self.refusal(reason)) }
        let draft: BridgeScheduleDraft
        switch BridgeScheduleArguments.create(arguments, caller: caller.permission) {
        case .failure(let error): return .error(error.message)
        case .success(let value): draft = value
        }
        let target: ScheduledTaskTarget
        switch draft.target {
        case .thisSession:
            guard let id = runID(caller) else {
                return .error("target this_session only works in a session Nook started; use new_session with project_path.")
            }
            target = .existingSession(id: id)
        case .newSession(let path, let agent):
            let folder = try resolveFolder(path ?? "", caller)
            let own = runID(caller).flatMap { app?.workspace.run($0) }
            let provider: RunProvider
            if let agent {
                guard let found = RunProvider.allCases.first(where: { $0.rawValue == agent || $0.displayName.lowercased() == agent }) else {
                    return .error("Unknown agent \"\(agent)\". Use claude, codex, gemini, opencode, cursor, grok or antigravity.")
                }
                provider = found
            } else {
                provider = own?.provider ?? .claude
            }
            target = .newSession(projectPath: folder, provider: provider.rawValue,
                                 profileID: own?.provider == provider ? own?.profileID : nil)
        }
        return try await once(.scheduleTask, arguments, caller) {
            let store = ScheduledTaskStore.shared
            let task = ScheduledTask(title: draft.title, prompt: draft.prompt, rule: draft.rule, target: target,
                                     enabled: draft.enabled, createdAt: Date())
            var note = tr("bridge.approval.scheduleNote", draft.permission.rawValue)
            if !store.isEnabled { note += " " + tr("bridge.approval.scheduleOff") }
            let allowed = await ask(caller, tool: .scheduleTask, title: tr("bridge.approval.schedule", caller.agent),
                                    detail: Self.scheduleDetail(task, permission: draft.permission), note: note, danger: false,
                                    connection: context.connection)
            guard allowed else {
                audit(.scheduleTask, caller, draft.title, "niet toegestaan")
                return .error(Self.refusal(.schedule))
            }
            store.save(task, permission: draft.permission)
            audit(.scheduleTask, caller, "\(draft.title) · \(BridgeScheduleArguments.describe(draft.rule))", task.id.uuidString.lowercased())
            let saved = store.task(task.id) ?? task
            var text = "Scheduled. The user can change or remove it in Nook's settings.\n"
                + BridgeScheduleArguments.render(saved, permission: draft.permission, running: false)
            if !store.isEnabled { text += "\nScheduled tasks are switched off: it runs once the user switches them on." }
            return BridgeRPC.ToolResult(text: text)
        }
    }

    func updateScheduledTask(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        if case .refuse(let reason) = verdict(.updateScheduledTask, caller) { return .error(Self.refusal(reason)) }
        let change: BridgeScheduleChange
        switch BridgeScheduleArguments.update(arguments, caller: caller.permission) {
        case .failure(let error): return .error(error.message)
        case .success(let value): change = value
        }
        let store = ScheduledTaskStore.shared
        guard let task = store.task(change.id) else { return .error("No such scheduled task. Use an id from list_scheduled_tasks.") }
        if change.rule != nil, task.rule.isWebhook {
            return .error("This task runs on a webhook; its schedule can only be changed in Nook's settings.")
        }
        let updated = change.applied(to: task)
        let permission = change.permission ?? store.permission(for: task.id)
        let allowed = await ask(caller, tool: .updateScheduledTask, title: tr("bridge.approval.scheduleChange", caller.agent),
                                detail: Self.scheduleDetail(updated, permission: permission),
                                note: tr("bridge.approval.scheduleBefore", Self.scheduleLine(task, permission: store.permission(for: task.id))),
                                danger: false, connection: context.connection)
        guard allowed else {
            audit(.updateScheduledTask, caller, task.title, "niet toegestaan")
            return .error(Self.refusal(.schedule))
        }
        // The task may have been removed while the card was open.
        guard store.task(change.id) != nil else { return .error("The task was removed in the meantime.") }
        store.save(updated, permission: permission)
        audit(.updateScheduledTask, caller, updated.title, "gewijzigd")
        let saved = store.task(change.id) ?? updated
        return BridgeRPC.ToolResult(text: "Changed.\n" + BridgeScheduleArguments.render(saved, permission: permission, running: store.isRunning(saved.id)))
    }

    func runScheduledTaskNow(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async throws -> BridgeRPC.ToolResult {
        if case .refuse(let reason) = verdict(.runScheduledTaskNow, caller) { return .error(Self.refusal(reason)) }
        guard let raw = BridgeArgs.string(arguments["task_id"]), let id = UUID(uuidString: raw) else {
            return .error("Give the task_id from list_scheduled_tasks.")
        }
        let store = ScheduledTaskStore.shared
        guard let task = store.task(id) else { return .error("No such scheduled task. Use an id from list_scheduled_tasks.") }
        guard store.isEnabled else { return .error("not available: scheduled tasks are switched off in Nook's settings.") }
        return try await once(.runScheduledTaskNow, arguments, caller) {
            if store.isRunning(id) { return BridgeRPC.ToolResult(text: "busy: the task is running already.") }
            let allowed = await ask(caller, tool: .runScheduledTaskNow, title: tr("bridge.approval.scheduleRun", caller.agent),
                                    detail: Self.scheduleDetail(task, permission: store.permission(for: id)),
                                    note: tr("bridge.approval.scheduleRunNote"), danger: false, connection: context.connection)
            guard allowed else {
                audit(.runScheduledTaskNow, caller, task.title, "niet toegestaan")
                return .error(Self.refusal(.schedule))
            }
            let result = store.runNow(id)
            audit(.runScheduledTaskNow, caller, task.title, "\(result)")
            switch result {
            case .started: return BridgeRPC.ToolResult(text: "started: the task runs now; list_scheduled_tasks shows how it went.")
            case .busy: return BridgeRPC.ToolResult(text: "busy: the task is running already.")
            case .notAvailable: return .error("not available: scheduled tasks are switched off, or the task is gone.")
            }
        }
    }

    /// Everything the task will do, for the approval card: what you allow is what you saw.
    private static func scheduleDetail(_ task: ScheduledTask, permission: PermissionPolicy) -> String {
        "\(task.title)\n\(scheduleLine(task, permission: permission))\n\n\(task.prompt)"
    }

    private static func scheduleLine(_ task: ScheduledTask, permission: PermissionPolicy) -> String {
        let place: String
        switch task.target {
        case .newSession(let path, let provider, _):
            place = tr("bridge.schedule.newSession", RunProvider(rawValue: provider)?.displayName ?? provider, AgentPathFormat.tilde(path))
        case .existingSession:
            place = tr("bridge.schedule.thisSession")
        }
        return [scheduleText(task.rule), place, permission.rawValue, tr(task.enabled ? "bridge.schedule.on" : "bridge.schedule.off")]
            .joined(separator: " · ")
    }

    private static func scheduleText(_ rule: ScheduleRule) -> String {
        switch rule {
        case .interval(let seconds):
            let minutes = max(1, seconds / 60)
            return minutes % 60 == 0 ? tr("bridge.schedule.everyHours", minutes / 60) : tr("bridge.schedule.every", minutes)
        case .fixedTime(let hour, let minute, let weekdays):
            let time = String(format: "%02d:%02d", hour, minute)
            let symbols = Calendar.current.shortWeekdaySymbols
            let days = weekdays.sorted().compactMap { (1...7).contains($0) && symbols.count == 7 ? symbols[$0 - 1] : nil }
            return days.isEmpty || days.count == 7 ? tr("bridge.schedule.daily", time)
                : tr("bridge.schedule.days", time, days.joined(separator: ", "))
        case .webhook:
            return tr("bridge.schedule.webhook")
        }
    }

    // MARK: Pull requests

    /// The pull request a call is about: a url, a number in a repository (the folder's own by default), or the open
    /// pull request of the caller's branch.
    private func pullRequestURL(_ arguments: [String: Any], _ caller: BridgeCaller) async throws -> URL {
        let target: BridgePullRequestTarget.Parsed
        switch BridgePullRequestTarget.parse(arguments) {
        case .failure(let error): throw NookError(error.message)
        case .success(let value): target = value
        }
        let directory = caller.directory
        let facts = await Task.detached(priority: .userInitiated) { () -> (branch: String?, remote: RemoteRepository?) in
            guard let git = GitService.shared else { return (nil, nil) }
            return (git.currentBranch(directory), SourceForge.repository(remoteURL: git.remoteURL(directory)))
        }.value
        switch target {
        case .ref(let ref):
            if let url = ref.url { return url }
            if let repository = ref.repository {
                // Same forge as the folder; without a remote, github.com.
                if var repo = facts.remote {
                    repo.path = repository
                    if let url = repo.pullRequestURL(number: ref.number) { return url }
                }
                guard let url = URL(string: "https://github.com/\(repository)/pull/\(ref.number)") else { throw NookError("Invalid repository.") }
                return url
            }
            guard let repo = facts.remote, let url = repo.pullRequestURL(number: ref.number) else {
                throw NookError("This folder has no remote Nook recognises; pass url, or number with repository.")
            }
            return url
        case .current:
            if let id = runID(caller) {
                if let url = app?.workspace.openPullRequests[id] { return url }
                if let link = PullRequestSync.shared.links[id]?.first(where: { $0.state.isOpen }), let url = URL(string: link.url) { return url }
            }
            guard let branch = facts.branch else { throw NookError("Your folder is not on a branch; pass url or number.") }
            if let link = PullRequestSync.shared.folderLinks[PullRequestSync.folderKey(path: directory, branch: branch)]?
                .first(where: { $0.state.isOpen }), let url = URL(string: link.url) {
                return url
            }
            if let repo = facts.remote, let found = await SourceForge.requests(repo: repo, branch: branch),
               let link = found.first(where: { $0.state.isOpen }), let url = URL(string: link.url) {
                return url
            }
            throw NookError("Nook found no open pull request for \(branch). Pass url or number.")
        }
    }

    /// Uses the watch Nook already has for a session (WorkspaceManager.watchPullRequest): news lands in the timeline,
    /// and what the agent can act on reaches it as a message. It is kept with the session, also across restarts.
    func watchPullRequest(_ arguments: [String: Any], _ caller: BridgeCaller) async throws -> BridgeRPC.ToolResult {
        guard let app, let id = runID(caller), let run = app.workspace.run(id) else {
            return .error("watch_pull_request works in sessions Nook started. Use get_pull_request_status to check a pull request now.")
        }
        if case .refuse(let reason) = verdict(.watchPullRequest, caller) { return .error(Self.refusal(reason)) }
        if BridgeArgs.bool(arguments["stop"]) == true {
            guard let watch = run.prWatch else { return BridgeRPC.ToolResult(text: "This session was not watching a pull request.") }
            app.workspace.watchPullRequest(id, url: nil)
            audit(.watchPullRequest, caller, watch.url, "gestopt")
            return BridgeRPC.ToolResult(text: "Stopped watching \(watch.url).")
        }
        let url = try await pullRequestURL(arguments, caller)
        guard PullRequestWatch.canWatch(url) else {
            return .error("Nook watches GitHub pull requests and GitLab merge requests; \(url.absoluteString) is neither. get_pull_request_status may still read it.")
        }
        if let watch = app.workspace.run(id)?.prWatch, watch.url == url.absoluteString, watch.state == "open" {
            return BridgeRPC.ToolResult(text: "Already watching \(url.absoluteString). End your turn; Nook tells you when something needs you.")
        }
        let replaced = app.workspace.run(id)?.prWatch?.url
        app.workspace.watchPullRequest(id, url: url, wakeAgent: true)
        audit(.watchPullRequest, caller, url.absoluteString, "volgt")
        var text = "Watching \(url.absoluteString). Nook tells you when CI fails or a review or comment arrives; the merge and passing CI show in your timeline. End your turn now."
        if let replaced, replaced != url.absoluteString { text += " (This replaces the watch on \(replaced): a session watches one pull request.)" }
        return BridgeRPC.ToolResult(text: text)
    }

    func pullRequestStatus(_ arguments: [String: Any], _ caller: BridgeCaller) async throws -> BridgeRPC.ToolResult {
        let url = try await pullRequestURL(arguments, caller)
        guard let fetch = app?.workspace.pullRequestSnapshot else { return .error("Nook is not ready yet.") }
        guard let snapshot = await fetch(url) else {
            return .error("Nook could not read \(url.absoluteString). It reads GitHub pull requests with the user's GitHub connection and GitLab merge requests with the token set in Nook.")
        }
        return BridgeRPC.ToolResult(text: BridgePullRequestStatus.render(snapshot, url: url.absoluteString))
    }

    // MARK: Browser interaction

    private static let nothingOpen = "Nothing is open in Nook's browser. Open a page with browser_open first."

    func browserSnapshot(_ arguments: [String: Any]) async throws -> BridgeRPC.ToolResult {
        // Looking must not start the browser.
        guard let browser = BrowserStore.existing, browser.webView.url != nil else { return .error(Self.nothingOpen) }
        let limit = min(400, max(1, BridgeArgs.int(arguments["limit"]) ?? 150))
        let object = BridgeBrowserScript.result(try await browser.webView.evaluateJavaScript(BridgeBrowserScript.snapshot(limit: limit)))
        let lines = (object["lines"] as? [String]) ?? []
        var text = "# \((object["title"] as? String) ?? "")\nURL: \((object["url"] as? String) ?? "")\n\n"
        text += lines.isEmpty ? "(nothing to interact with)" : lines.joined(separator: "\n")
        if (object["more"] as? Bool) == true { text += "\n… more elements; pass a higher limit (at most 400)." }
        return BridgeRPC.ToolResult(text: text)
    }

    func browserInteract(_ tool: BridgeTool, _ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async throws -> BridgeRPC.ToolResult {
        guard let browser = BrowserStore.existing, let page = browser.webView.url else { return .error(Self.nothingOpen) }
        let target: BridgeBrowserScript.Target
        switch BridgeBrowserScript.target(arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let value): target = value
        }
        var value = ""
        if tool == .browserType {
            guard let typed = arguments["value"] as? String else { return .error("Give the value to type.") }
            value = typed
        }
        let host = page.host ?? page.absoluteString
        switch verdict(tool, caller, localPage: page.host.map(BridgeURLPolicy.isLoopback) ?? false) {
        case .refuse(let reason):
            return .error(Self.refusal(reason))
        case .ask:
            let action = tool == .browserClick ? target.summary : "\(target.summary)\n\n\(value)"
            let allowed = await ask(caller, tool: tool,
                                    title: tr(tool == .browserClick ? "bridge.approval.browserClick" : "bridge.approval.browserType", caller.agent, host),
                                    detail: "\(page.absoluteString)\n\n\(action)", note: tr("bridge.approval.browserNote"),
                                    danger: false, connection: context.connection)
            guard allowed else {
                audit(tool, caller, "\(host) · \(target.summary)", "niet toegestaan")
                return .error(Self.refusal(.needsReview))
            }
        case .allow:
            break
        }
        let script = tool == .browserClick ? BridgeBrowserScript.click(target)
            : BridgeBrowserScript.type(target, value: value, append: BridgeArgs.bool(arguments["append"]) ?? false,
                                       submit: BridgeArgs.bool(arguments["submit"]) ?? false)
        let object = BridgeBrowserScript.result(try await browser.webView.evaluateJavaScript(script))
        markUnseen(caller.directory, SessionTool.browser.rawValue)
        // Only where and on what: typed text can be private and never goes into the audit log.
        guard (object["ok"] as? Bool) == true else {
            audit(tool, caller, "\(host) · \(target.summary)", "mislukt")
            return .error((object["error"] as? String) ?? "Nook's browser could not do that.")
        }
        audit(tool, caller, "\(host) · \(target.summary)", "gedaan")
        // A click often starts a navigation; give it a moment so the next call sees the new page.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let element = (object["element"] as? String) ?? target.summary
        let verb = tool == .browserClick ? "Clicked" : ((object["submitted"] as? Bool) == true ? "Typed into and submitted" : "Typed into")
        return BridgeRPC.ToolResult(text: "\(verb) \(element) on \(page.absoluteString). Check the result with browser_snapshot, browser_read or browser_wait_for.")
    }

    func browserWaitFor(_ arguments: [String: Any]) async -> BridgeRPC.ToolResult {
        let text = BridgeArgs.string(arguments["text"])
        let selector = BridgeArgs.string(arguments["selector"])
        guard text != nil || selector != nil else { return .error("Give the text or selector to wait for.") }
        guard let browser = BrowserStore.existing, browser.webView.url != nil else { return .error(Self.nothingOpen) }
        let gone = BridgeArgs.bool(arguments["gone"]) ?? false
        let timeout = min(30, max(1, BridgeArgs.int(arguments["timeout_seconds"]) ?? 10))
        let script = BridgeBrowserScript.condition(text: text, selector: selector, gone: gone)
        let what = [text.map { "\"\($0)\"" }, selector].compactMap { $0 }.joined(separator: " and ")
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while true {
            // A page that is still loading cannot answer yet.
            if !browser.webView.isLoading, let value = try? await browser.webView.evaluateJavaScript(script) {
                let object = BridgeBrowserScript.result(value)
                if let error = object["error"] as? String { return .error(error) }
                if (object["met"] as? Bool) == true {
                    return BridgeRPC.ToolResult(text: (gone ? "Gone: " : "Found: ") + what + " on \(browser.webView.url?.absoluteString ?? "").")
                }
            }
            if Date() >= deadline || Task.isCancelled {
                return .error("Waited \(timeout) s; \(what) \(gone ? "is still there" : "did not appear"). Check the page with browser_snapshot or browser_screenshot.")
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    // MARK: Secrets

    /// A secret by name, after the user allowed it: the value kept for agents in Nook's keychain, or one the user pastes
    /// (and may keep there). It goes back over this call's own connection only; the audit log gets the name.
    func requestSecret(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async -> BridgeRPC.ToolResult {
        guard let name = BridgeSecret.name(arguments["name"]) else {
            return .error("name must be 1 to 64 letters, digits, dots, dashes or underscores, such as STRIPE_TEST_KEY.")
        }
        guard let reason = BridgeArgs.string(arguments["reason"]) else { return .error("Say in one sentence why you need it.") }
        if case .refuse(let why) = verdict(.requestSecret, caller) { return .error(Self.refusal(why)) }
        let account = BridgeSecret.account(name)
        let stored = SecretStore.read(account) != nil
        let allowed = await ask(caller, tool: .requestSecret, title: tr("bridge.approval.secret", caller.agent, name),
                                detail: "\(name)\n\n\(String(reason.prefix(500)))",
                                note: tr(stored ? "bridge.approval.secretStored" : "bridge.approval.secretPaste"),
                                danger: false, connection: context.connection)
        guard allowed else {
            audit(.requestSecret, caller, name, "niet toegestaan")
            return .error(Self.refusal(.secret))
        }
        var value = SecretStore.read(account)
        if value == nil {
            guard let pasted = BridgeSecretPrompt.ask(name: name, agent: caller.agent) else {
                audit(.requestSecret, caller, name, "geannuleerd")
                return .error("The user did not give a value for \(name).")
            }
            if pasted.remember { SecretStore.write(pasted.value, account: account) }
            value = pasted.value
        }
        guard let value, !value.isEmpty else { return .error("The user did not give a value for \(name).") }
        audit(.requestSecret, caller, name, stored ? "uit sleutelhanger" : "geplakt")
        return BridgeRPC.ToolResult(text: BridgeSecret.envelope(name: name, value: value))
    }
}

/// Where you paste a secret an agent asked for and Nook does not keep yet: a secure field, never shown, never logged.
@MainActor
enum BridgeSecretPrompt {
    static func ask(name: String, agent: String) -> (value: String, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = tr("bridge.secret.prompt.title", name)
        alert.informativeText = tr("bridge.secret.prompt.detail", agent)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = name
        alert.accessoryView = field
        alert.addButton(withTitle: tr("bridge.secret.prompt.give"))
        alert.addButton(withTitle: tr("button.cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = tr("bridge.secret.prompt.remember")
        alert.suppressionButton?.state = .off
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runAboveNotch() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return (value, alert.suppressionButton?.state == .on)
    }
}
