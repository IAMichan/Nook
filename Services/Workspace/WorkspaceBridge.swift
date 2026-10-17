import Foundation
import AppKit

/// A request from an agent that waits for your decision in the notch: a command that is not clearly harmless, or a
/// pull request.
struct BridgeRequest: Identifiable, Equatable {
    let id: String
    let caller: BridgeCaller
    let tool: BridgeTool
    let title: String
    /// Everything that will happen, never shortened: what you allow is what you saw.
    let detail: String
    let note: String
    let danger: Bool
    let created: Date
    /// The agent's connection; when it goes away (the agent stopped), the request is withdrawn.
    let connection: String
}

/// The workspace bridge: Nook's terminal, browser and pull requests for coding agents (see WorkspaceBridgeProtocol for
/// the tools and the rules). Agents reach it through `nook-mcp`, which forwards each MCP message over `bridge.sock`.
///
/// Nook is the gatekeeper: reading runs directly; a command runs directly only when it is clearly harmless (or the
/// session has full rights), dangerous commands are refused, and a pull request always waits for you. Everything an
/// agent does here is visible (its terminal and the browser sit next to its session) and lands in the audit log.
@MainActor
final class WorkspaceBridge: ObservableObject {
    static let shared = WorkspaceBridge()

    /// Requests waiting for your decision, oldest first.
    @Published private(set) var pending: [BridgeRequest] = []
    /// Per folder, the tools ("terminal", "browser") an agent used there that you have not looked at yet: a dot on that
    /// tool's icon next to the session.
    @Published private(set) var unseen: [String: Set<String>] = [:]

    weak var app: AppModel?
    var onApproval: ((BridgeRequest) -> Void)?
    var onApprovalGone: ((String) -> Void)?

    private let server = UnixSocketServer(path: NookPaths.bridgeSocketURL.path)
    private var waiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var installed = false
    private var started = false

    /// How long a request waits for you before the agent hears "not approved".
    private static let approvalTimeout: UInt64 = 600

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        installed = (try? WorkspaceBridgeScript.install()) != nil
        server.onMessage = { [weak self] data, connection in
            Task { @MainActor in
                if let self { self.handle(data, connection) } else { connection.reply(nil) }
            }
        }
        do {
            try server.start()
        } catch {
            Log.agents.error("Workspace bridge socket: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What a session Nook starts gets on its command line; nil when agent tools are off or the script is missing.
    var launch: BridgeLaunch? {
        guard installed, WorkspaceSettings.shared.agentTools else { return nil }
        return BridgeLaunch(script: NookPaths.bridgeScriptURL.path)
    }

    // MARK: Decisions

    func decide(_ id: String, allow: Bool) { finish(id, allowed: allow) }

    private func finish(_ id: String, allowed: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        onApprovalGone?(id)
        waiter.resume(returning: allowed)
    }

    private func ask(_ caller: BridgeCaller, tool: BridgeTool, title: String, detail: String, note: String, danger: Bool,
                     connection: String) async -> Bool {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let request = BridgeRequest(id: id, caller: caller, tool: tool, title: title, detail: detail, note: note,
                                    danger: danger, created: Date(), connection: connection)
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            pending.append(request)
            onApproval?(request)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.approvalTimeout * 1_000_000_000)
                self?.finish(id, allowed: false)
            }
        }
    }

    /// The agent hung up (stopped, or its turn ended): its open requests are withdrawn.
    private func connectionClosed(_ connection: String) {
        for request in pending where request.connection == connection { finish(request.id, allowed: false) }
    }

    // MARK: Seen

    /// You looked at `tool` for the session in `directory`: its dot goes away.
    func markSeen(_ directory: String, _ tool: String) {
        let key = WorkspacePathPolicy.normalize(directory)
        guard unseen[key]?.contains(tool) == true else { return }
        unseen[key]?.remove(tool)
        if unseen[key]?.isEmpty == true { unseen[key] = nil }
    }

    /// The browser is shared by every session: looking at it anywhere counts for all of them.
    func markBrowserSeen() {
        guard unseen.values.contains(where: { $0.contains("browser") }) else { return }
        for key in Array(unseen.keys) {
            unseen[key]?.remove("browser")
            if unseen[key]?.isEmpty == true { unseen[key] = nil }
        }
    }

    func hasUnseen(_ directory: String, _ tool: String) -> Bool {
        guard !directory.isEmpty else { return false }
        return unseen[WorkspacePathPolicy.normalize(directory)]?.contains(tool) == true
    }

    private func markUnseen(_ directory: String, _ tool: String) {
        guard !directory.isEmpty else { return }
        unseen[WorkspacePathPolicy.normalize(directory), default: []].insert(tool)
    }

    // MARK: Messages

    private struct Context {
        let agentID: String
        let cwd: String
        let env: [String: Any]
        let connection: String
    }

    private func handle(_ data: Data, _ connection: HookConnection) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any] else {
            connection.reply(nil)
            return
        }
        let context = Context(agentID: (object["agent"] as? String) ?? "agent", cwd: (object["cwd"] as? String) ?? "",
                              env: (object["env"] as? [String: Any]) ?? [:], connection: UUID().uuidString)
        connection.onPeerClosed { [weak self] in
            Task { @MainActor in self?.connectionClosed(context.connection) }
        }
        Task { @MainActor [weak self] in
            guard let self else { connection.reply(nil); return }
            let response = await BridgeRPC.response(to: message) { tool, arguments in
                await self.call(tool, arguments, context)
            }
            guard let response, let reply = try? JSONSerialization.data(withJSONObject: response) else {
                connection.reply(nil)
                return
            }
            connection.reply(reply)
        }
    }

    /// The session behind a call: the run Nook started (its id is in the environment), a run working in that folder,
    /// or an agent you started in a terminal that linked the bridge itself.
    private func caller(_ context: Context) -> BridgeCaller? {
        guard let app else { return nil }
        if let raw = context.env["NOOK_RUN_ID"] as? String, let id = UUID(uuidString: raw), let run = app.workspace.run(id) {
            return caller(run)
        }
        let folder = WorkspacePathPolicy.normalize(context.cwd)
        guard !folder.isEmpty else { return nil }
        if let run = app.workspace.activeRuns.first(where: { WorkspacePathPolicy.normalize($0.workingDirectory) == folder }) {
            return caller(run)
        }
        let session = app.hub.sessions.first { !$0.cwd.isEmpty && WorkspacePathPolicy.normalize($0.cwd) == folder }
        return BridgeCaller(kind: .external, agent: session?.name ?? Self.displayName(context.agentID),
                            title: session?.summary ?? "", directory: folder, mode: nil, permission: nil)
    }

    private func caller(_ run: WorkspaceRun) -> BridgeCaller {
        BridgeCaller(kind: .run(run.id), agent: run.provider.displayName, title: run.title,
                     directory: run.workingDirectory, mode: run.mode, permission: run.permission)
    }

    private static func displayName(_ agentID: String) -> String {
        switch agentID {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return agentID.isEmpty ? "Agent" : agentID.prefix(1).uppercased() + agentID.dropFirst()
        }
    }

    // MARK: Tools

    private func call(_ tool: BridgeTool, _ arguments: [String: Any], _ context: Context) async -> BridgeRPC.ToolResult {
        guard let caller = self.caller(context) else {
            return .error("Nook could not tell which session this is. Start the agent from a project folder.")
        }
        do {
            switch tool {
            case .workspaceInfo: return try await workspaceInfo(caller)
            case .terminalRun: return try await terminalRun(arguments, caller, context)
            case .terminalRead: return try terminalRead(arguments, caller)
            case .terminalList: return terminalList(caller)
            case .terminalStop: return try terminalStop(arguments, caller)
            case .browserOpen: return try await browserOpen(arguments, caller)
            case .browserRead: return try await browserRead(caller)
            case .browserScreenshot: return try await browserScreenshot(arguments, caller)
            case .pullRequestCreate: return try await pullRequestCreate(arguments, caller, context)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func verdict(_ tool: BridgeTool, _ caller: BridgeCaller, command: CommandAssessment.Level? = nil) -> BridgeVerdict {
        BridgePolicy.verdict(tool: tool, caller: caller, command: command, enabled: WorkspaceSettings.shared.agentTools)
    }

    /// The answer for a refused call, in words the agent can act on.
    private static func refusal(_ reason: BridgeVerdict.Reason) -> String {
        switch reason {
        case .disabled: return "The user has switched off agent access to Nook's workspace (Settings › Agents › Workspace)."
        case .planMode: return "This session is in Plan mode: it may read, not start processes or open pull requests. Describe the step in your plan instead."
        case .dangerous: return "Nook refuses this command through its terminal because it is dangerous. Ask the user to run it themselves if it is really needed."
        case .needsReview, .outward: return "The user did not approve this in Nook."
        }
    }

    private func audit(_ tool: BridgeTool, _ caller: BridgeCaller, _ args: String, _ result: String) {
        app?.store.audit(tool: "agent_" + tool.rawValue, args: "\(caller.agent) · \(args)", result: result)
    }

    // MARK: Workspace

    private func workspaceInfo(_ caller: BridgeCaller) async throws -> BridgeRPC.ToolResult {
        var lines = ["# Nook workspace for \(caller.agent)"]
        lines.append("Folder: \(caller.directory)")
        let directory = caller.directory
        let git = await Task.detached(priority: .userInitiated) { () -> (branch: String?, changed: Int?, remote: String?) in
            guard let service = GitService.shared else { return (nil, nil, nil) }
            return (service.currentBranch(directory), service.changedFileCount(directory), service.remoteURL(directory))
        }.value
        if let branch = git.branch { lines.append("Branch: \(branch)") }
        if case .run(let id) = caller.kind, let base = app?.workspace.run(id)?.baseBranch, !base.isEmpty {
            lines.append("Base branch: \(base)")
        }
        if let changed = git.changed { lines.append("Uncommitted changes: \(changed) file(s)") }
        if let mode = caller.mode, let permission = caller.permission {
            lines.append("Session: mode \(mode.rawValue), rights \(permission.rawValue)")
        }

        lines.append("")
        lines.append("## Terminals in this folder")
        let terminals = TerminalStore.shared.sessions(in: directory)
        if terminals.isEmpty { lines.append("- none") }
        for terminal in terminals { lines.append("- " + describe(terminal, caller)) }

        let servers = await Task.detached(priority: .utility) { DevServerScanner.scan(folder: WorkspacePathPolicy.normalize(directory)) }.value
        lines.append("")
        lines.append("## Local servers in this folder")
        if servers.isEmpty { lines.append("- none listening") }
        for server in servers { lines.append("- \(server.command) (pid \(server.pid)) · \(server.url.absoluteString) — open it with browser_open") }

        lines.append("")
        lines.append("## Browser")
        let browser = BrowserStore.shared
        if let url = browser.webView.url {
            lines.append("- \(browser.webView.title ?? "") · \(url.absoluteString)" + (browser.openedBy.map { " (opened by \($0))" } ?? ""))
        } else {
            lines.append("- nothing open")
        }

        lines.append("")
        lines.append("## Pull requests")
        if let remote = git.remote, let repo = GitHubRemote.repository(from: remote) {
            lines.append(GitHubPullRequests.isAvailable
                ? "- \(repo): pull_request_create pushes the branch and opens the pull request with the user's GitHub connection, after their approval."
                : "- \(repo): no GitHub connection in Nook; pull_request_create pushes the branch and opens GitHub's page for the user to finish, after their approval.")
        } else {
            lines.append("- this folder has no GitHub remote")
        }

        lines.append("")
        lines.append("## Rules")
        if !WorkspaceSettings.shared.agentTools {
            lines.append("- The user has switched agent access off: only reading works.")
        } else if caller.mode == .plan {
            lines.append("- Plan mode: you can read terminals and the browser, but not start processes or open pull requests.")
        } else {
            lines.append("- Reading terminals and the browser, opening pages and stopping your own terminals run directly.")
            lines.append(caller.permission == .bypass
                ? "- Commands run directly; dangerous ones are refused."
                : "- Clearly harmless commands run directly; others wait for the user's approval; dangerous ones are refused.")
            lines.append("- A pull request always waits for the user's approval.")
        }
        return BridgeRPC.ToolResult(text: lines.joined(separator: "\n"))
    }

    private func describe(_ terminal: TerminalSession, _ caller: BridgeCaller) -> String {
        var line = "\(terminal.shortID) · \(terminal.title) · "
        if terminal.running {
            line += "running"
        } else {
            line += "exited" + (terminal.exitCode.map { " (\($0))" } ?? "")
        }
        line += " · \(terminal.directory)"
        if let owner = terminal.owner {
            line += owner.key == caller.key ? " · started by you" : " · started by \(owner.agent)"
        } else {
            line += " · the user's own terminal"
        }
        return line
    }

    // MARK: Terminal

    private func terminalRun(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async throws -> BridgeRPC.ToolResult {
        let command = ((arguments["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .error("Give the command to run.") }
        let folder = try resolveFolder((arguments["cwd"] as? String) ?? "", caller)
        let assessment = CommandRisk.assess(command)
        switch verdict(.terminalRun, caller, command: assessment.level) {
        case .refuse(let reason):
            audit(.terminalRun, caller, command, "geweigerd: \(reason.rawValue)")
            return .error(Self.refusal(reason) + (reason == .dangerous ? " (\(assessment.note))" : ""))
        case .ask:
            let allowed = await ask(caller, tool: .terminalRun, title: tr("bridge.approval.terminal", caller.agent),
                                    detail: command, note: [AgentPathFormat.tilde(folder), assessment.note]
                                        .filter { !$0.isEmpty }.joined(separator: " · "),
                                    danger: false, connection: context.connection)
            guard allowed else {
                audit(.terminalRun, caller, command, "niet toegestaan")
                return .error(Self.refusal(.needsReview))
            }
        case .allow:
            break
        }
        let title = ((arguments["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = TerminalStore.shared.open(in: folder, command: command,
                                                 title: title.isEmpty ? String(command.prefix(40)) : String(title.prefix(40)),
                                                 owner: TerminalOwner(agent: caller.agent, key: caller.key))
        markUnseen(caller.directory, SessionTool.terminal.rawValue)
        audit(.terminalRun, caller, command, terminal.shortID)
        // Give it a moment, so the agent sees whether it started (or failed) without another call.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let output = terminal.output(lines: 40)
        return BridgeRPC.ToolResult(text: """
        Started in Nook terminal \(terminal.shortID) in \(folder); the user can see it next to your session. \
        Read more output with terminal_read {"terminal_id": "\(terminal.shortID)"} and stop it with terminal_stop.

        Output so far:
        \(output.isEmpty ? "(nothing yet)" : output)
        """)
    }

    /// A folder for a command: absolute, `~/…`, or relative to the caller's folder. It must exist and not be a system folder.
    private func resolveFolder(_ raw: String, _ caller: BridgeCaller) throws -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = caller.directory.isEmpty ? home : caller.directory
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { path = base }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = URL(fileURLWithPath: base).appendingPathComponent(path).path }
        let normalized = WorkspacePathPolicy.normalize(path)
        switch WorkspacePathPolicy.verdict(for: normalized) {
        case .ok: return normalized
        case .forbidden where normalized == WorkspacePathPolicy.normalize(home): return normalized
        case .forbidden: throw NookError("Nook does not run commands in system folders (\(normalized)).")
        default: throw NookError("That folder does not exist: \(normalized)")
        }
    }

    /// A terminal the caller may see: one in its folder (or below it), or one it started itself.
    private func terminal(_ arguments: [String: Any], _ caller: BridgeCaller) throws -> TerminalSession {
        let reference = (arguments["terminal_id"] as? String) ?? ""
        guard let terminal = TerminalStore.shared.session(reference) else {
            throw NookError("There is no Nook terminal \"\(reference)\". Use terminal_list to see the terminals in your folder.")
        }
        let mine = terminal.owner?.key == caller.key
        let inFolder = TerminalStore.shared.sessions(in: caller.directory).contains { $0 === terminal }
        guard mine || inFolder else { throw NookError("Terminal \(terminal.shortID) belongs to another folder.") }
        return terminal
    }

    private func terminalRead(_ arguments: [String: Any], _ caller: BridgeCaller) throws -> BridgeRPC.ToolResult {
        let terminal = try terminal(arguments, caller)
        let lines = min(400, max(1, (arguments["lines"] as? Int) ?? 80))
        let state = terminal.running ? "running" : "exited" + (terminal.exitCode.map { " with code \($0)" } ?? "")
        let output = terminal.output(lines: lines)
        return BridgeRPC.ToolResult(text: "Terminal \(terminal.shortID) · \(terminal.title) · \(state)\n\n"
                                    + (output.isEmpty ? "(no output)" : output))
    }

    private func terminalList(_ caller: BridgeCaller) -> BridgeRPC.ToolResult {
        let store = TerminalStore.shared
        var list = store.sessions(in: caller.directory)
        for terminal in store.sessions where terminal.owner?.key == caller.key && !list.contains(where: { $0 === terminal }) {
            list.append(terminal)
        }
        guard !list.isEmpty else { return BridgeRPC.ToolResult(text: "No Nook terminals in \(caller.directory).") }
        return BridgeRPC.ToolResult(text: list.map { "- " + describe($0, caller) }.joined(separator: "\n"))
    }

    private func terminalStop(_ arguments: [String: Any], _ caller: BridgeCaller) throws -> BridgeRPC.ToolResult {
        let terminal = try terminal(arguments, caller)
        guard terminal.owner?.key == caller.key else {
            throw NookError("You can only stop terminals you started with terminal_run; \(terminal.shortID) is not one of them.")
        }
        if case .refuse(let reason) = verdict(.terminalStop, caller) { return .error(Self.refusal(reason)) }
        terminal.interrupt()
        let close = (arguments["close"] as? Bool) ?? false
        if close { TerminalStore.shared.close(terminal.id) }
        audit(.terminalStop, caller, terminal.command ?? terminal.title, close ? "gesloten" : "gestopt")
        return BridgeRPC.ToolResult(text: close ? "Stopped and closed terminal \(terminal.shortID)."
                                                : "Sent Ctrl-C to terminal \(terminal.shortID); it stays open with its output.")
    }

    // MARK: Browser

    private func browserOpen(_ arguments: [String: Any], _ caller: BridgeCaller) async throws -> BridgeRPC.ToolResult {
        let raw = (arguments["url"] as? String) ?? ""
        guard let url = BridgeURLPolicy.url(raw) else {
            return .error("Nook's browser opens https addresses, and http only on this Mac (localhost, 127.0.0.1). \"\(raw)\" is neither.")
        }
        if case .refuse(let reason) = verdict(.browserOpen, caller) { return .error(Self.refusal(reason)) }
        let browser = BrowserStore.shared
        let failure = await browser.load(url, by: caller.agent)
        markUnseen(caller.directory, SessionTool.browser.rawValue)
        audit(.browserOpen, caller, url.absoluteString, failure ?? "geladen")
        if let failure { return .error("Opened \(url.absoluteString) in Nook's browser, but it did not load: \(failure)") }
        let title = browser.webView.title ?? ""
        return BridgeRPC.ToolResult(text: "Opened \(browser.webView.url?.absoluteString ?? url.absoluteString) in Nook's browser"
                                    + (title.isEmpty ? "" : " · \(title)")
                                    + ". The user can see it next to your session. Check it with browser_read or browser_screenshot.")
    }

    private func browserRead(_ caller: BridgeCaller) async throws -> BridgeRPC.ToolResult {
        let browser = BrowserStore.shared
        let page = try await browser.pageText()
        let console = await browser.consoleMessages()
        var text = "# \(page.title)\nURL: \(page.url)\n\n\(page.text.isEmpty ? "(no visible text)" : page.text)"
        text += "\n\n## Console errors and warnings\n" + (console.isEmpty ? "none" : console.suffix(40).joined(separator: "\n"))
        return BridgeRPC.ToolResult(text: text)
    }

    private func browserScreenshot(_ arguments: [String: Any], _ caller: BridgeCaller) async throws -> BridgeRPC.ToolResult {
        let browser = BrowserStore.shared
        let image = try await browser.screenshot(maxWidth: (arguments["max_width"] as? Int) ?? 1280)
        let address = browser.webView.url?.absoluteString ?? ""
        return BridgeRPC.ToolResult(text: "Screenshot of \(address)", imageBase64: image.base64EncodedString(),
                                    imageMimeType: "image/jpeg")
    }

    // MARK: Pull request

    private func pullRequestCreate(_ arguments: [String: Any], _ caller: BridgeCaller, _ context: Context) async throws -> BridgeRPC.ToolResult {
        let title = ((arguments["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .error("Give the pull request a title.") }
        let body = (arguments["body"] as? String) ?? ""
        let draft = (arguments["draft"] as? Bool) ?? true
        if case .refuse(let reason) = verdict(.pullRequestCreate, caller) { return .error(Self.refusal(reason)) }
        guard let git = GitService.shared else { throw NookError("Git is not available on this Mac.") }

        let directory = caller.directory
        let sessionBase: String? = {
            if case .run(let id) = caller.kind { return app?.workspace.run(id)?.baseBranch }
            return nil
        }()
        let requestedBase = ((arguments["base"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = await Task.detached(priority: .userInitiated) { () -> (branch: String?, remote: String, url: String?, base: String?, changed: Int?) in
            let remotes = git.remotes(directory)
            let remote = remotes.contains("origin") ? "origin" : (remotes.first ?? "origin")
            let base = requestedBase.isEmpty ? (sessionBase ?? git.defaultBaseBranch(directory)) : requestedBase
            return (git.currentBranch(directory), remote, git.remoteURL(directory, remote: remote), base, git.changedFileCount(directory))
        }.value
        guard let branch = facts.branch else { throw NookError("The folder is not on a branch (detached HEAD). Create a branch first.") }
        guard let remoteURL = facts.url, let repo = GitHubRemote.repository(from: remoteURL) else {
            throw NookError("This folder has no GitHub remote, so Nook cannot open a pull request for it.")
        }
        var base = facts.base ?? ""
        for prefix in ["origin/", facts.remote + "/"] where base.hasPrefix(prefix) { base = String(base.dropFirst(prefix.count)) }
        guard !base.isEmpty else { throw NookError("Nook could not tell which branch to merge into; pass base.") }
        guard base != branch else { throw NookError("You are on \(branch) itself. Work on a separate branch, then propose the pull request.") }

        let viaConnector = GitHubPullRequests.isAvailable
        var detail = "\(repo) · \(branch) → \(base)\(draft && viaConnector ? " · draft" : "")\n\n\(title)"
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty { detail += "\n\n" + clean }
        var notes = [tr("bridge.approval.prPush", branch, facts.remote)]
        if let changed = facts.changed, changed > 0 { notes.append(tr("bridge.approval.prUncommitted", changed)) }
        if !viaConnector { notes.append(tr("bridge.approval.prBrowser")) }
        let allowed = await ask(caller, tool: .pullRequestCreate, title: tr("bridge.approval.pr", caller.agent), detail: detail,
                                note: notes.joined(separator: " "), danger: false, connection: context.connection)
        guard allowed else {
            audit(.pullRequestCreate, caller, "\(repo) \(branch) → \(base)", "niet toegestaan")
            return .error(Self.refusal(.outward))
        }

        let remote = facts.remote
        do {
            try await Task.detached(priority: .userInitiated) { try git.push(directory, remote: remote, branch: branch) }.value
        } catch {
            audit(.pullRequestCreate, caller, "\(repo) \(branch) → \(base)", "push mislukt")
            throw NookError("Pushing \(branch) to \(remote) failed: \(error.localizedDescription)")
        }
        if case .run(let id) = caller.kind { app?.workspace.refreshGit(id) }

        guard viaConnector else {
            if let compare = GitHubRemote.compareURL(repo: repo, base: base, head: branch) { NSWorkspace.shared.open(compare) }
            audit(.pullRequestCreate, caller, "\(repo) \(branch) → \(base)", "pagina op github.com geopend")
            return BridgeRPC.ToolResult(text: "Pushed \(branch) to \(remote). Nook has no GitHub connection, so it opened GitHub's compare page in the user's browser for them to finish the pull request.")
        }
        let link = try await GitHubPullRequests.create(repo: repo, title: title, body: body, head: branch, base: base, draft: draft)
        audit(.pullRequestCreate, caller, "\(repo) \(branch) → \(base)", link.absoluteString)
        return BridgeRPC.ToolResult(text: "Pushed \(branch) to \(remote) and opened the pull request\(draft ? " as draft" : ""): \(link.absoluteString)")
    }
}
