import SwiftUI
import AppKit

extension RunProvider {
    var kind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .cursor: return .cursor
        case .grok: return .grok
        case .antigravity: return .antigravity
        case .acp: return .acp
        }
    }

    var color: Color { kind.color }
    var composerTint: Color { kind.composerTint }

    init?(kind: AgentKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .gemini: self = .gemini
        case .opencode: self = .opencode
        case .cursor: self = .cursor
        case .grok: self = .grok
        case .antigravity: self = .antigravity
        case .acp: self = .acp
        }
    }
}

/// The main window's controller. A single window; opening brings it to front.
@MainActor
final class WorkspaceWindowController {
    static let shared = WorkspaceWindowController()
    private var window: NSWindow?

    var isKey: Bool { window?.isKeyWindow ?? false }
    var isVisible: Bool { window?.isVisible ?? false }

    func show(app: AppModel) {
        if window == nil {
            let root = WorkspaceView()
                .environmentObject(app)
                .environmentObject(app.workspace)
                .environmentObject(app.workspace.settings)
            let host = NSHostingController(rootView: root)
            // The window sets its own minSize; letting the hosting view also drive it makes a pane's appearance resize
            // the window in a layout loop.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            // Dark for the window and everything presented from it (sheets inherit the window's appearance). Asking for it
            // with `.preferredColorScheme` inside the window and inside each sheet makes the sheets re-negotiate it on every
            // layout pass, which loops ("needing another Update Constraints in Window pass").
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = tr("ws.windowTitle")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            // The panel runs up under the traffic lights, as the open notch runs up under the camera; the title is in the
            // Dock and ⌘Tab.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Black, as the notch.
            window.backgroundColor = .black
            window.setContentSize(NSSize(width: 1240, height: 800))
            window.minSize = NSSize(width: 900, height: 580)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("NookWorkspace")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        if let window { DockPresence.shared.track(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension AppModel {
    // MARK: - Workspace

    /// Connects the workspace to the rest of Nook. Run once at startup.
    func startWorkspace() {
        workspace.executable = { [weak self] provider in
            // Antigravity sessions run on Google's ACP server that Nook installs, not on the Antigravity app.
            if provider == .antigravity { return AntigravityInstaller.shared.installed?.executable }
            return self?.history.executables[provider.kind]
        }
        workspace.accountEnvironment = { [weak self] profileID in
            guard let self, let profile = self.profiles.profile(id: profileID) else { return [:] }
            return self.profiles.launchEnvironment(profile)
        }
        workspace.accountHome = { [weak self] profileID in self?.profiles.profile(id: profileID)?.homeURL.path ?? profileID }
        workspace.onApproval = { [weak self] run, pending in self?.presentWorkspaceApproval(run, pending) }
        workspace.onApprovalGone = { [weak self] requestID in self?.viewModel.dismissCard(id: "wsapproval-" + requestID) }
        workspace.onTurnFinished = { [weak self] run in self?.workspaceTurnFinished(run) }
        workspace.onQuestion = { [weak self] run, pending in
            CompanionNotifier.shared.question(run, pending)
            self?.workspaceQuestion(run)
        }
        // Codex reports new limits while it works: show them right away.
        workspace.onRateLimits = { [weak self] in self?.refreshQuotas() }
        // Signed in to Antigravity (when linking it, or in a session): its limits show right away.
        workspace.onAntigravitySignedIn = { [weak self] in
            self?.antigravityUsage.refreshNow(force: true)
            self?.history.refresh(minimumInterval: 0)
        }
        workspace.openBuiltInTerminal = { [weak self] folder in self?.openTerminal(in: folder) }
        // The git button finds and opens pull requests through the GitHub connector, when it is set up.
        // GitHub, or a GitLab merge request (with its token from Settings).
        workspace.pullRequestSnapshot = { url in
            if GitHubPullRequests.parse(url) != nil { return await GitHubPullRequests.snapshot(url: url) }
            return await GitLabMergeRequests.snapshot(url: url)
        }
        workspace.pullRequestLookup = { repo, branch in
            guard let found = await SourceForge.requests(repo: repo, branch: branch) else { return nil }
            return found.first { $0.state.isOpen }.flatMap { URL(string: $0.url) }
        }
        workspace.pullRequestCreate = { repo, title, body, head, base in
            guard SourceForge.canCreate(repo) else { return nil }
            return try await SourceForge.create(repo: repo, title: title, body: body, head: head, base: base, draft: false)
        }
        // Project scripts run in a terminal that belongs to the session's folder, without taking you away from where you are.
        workspace.runScript = { folder, command, title in _ = TerminalStore.shared.open(in: folder, command: command, title: title) }
        startWorkspaceBridge()
        // Sessions a restart cut off go on, once the agents' executables are known (history loads in the background).
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            self?.workspace.continueInterruptedRuns()
        }
    }

    /// Nook's terminal, browser and pull requests for the agents (see WorkspaceBridge): requests that need you appear as
    /// the same approval card as any other agent request, and sessions Nook starts get the bridge on their command line.
    private func startWorkspaceBridge() {
        let bridge = WorkspaceBridge.shared
        bridge.app = self
        bridge.onApproval = { [weak self] request in self?.presentBridgeApproval(request) }
        bridge.onApprovalGone = { [weak self] id in self?.viewModel.dismissCard(id: "bridge-" + id) }
        bridge.start()
        workspace.bridgeLaunch = { WorkspaceBridge.shared.launch }
    }

    private func presentBridgeApproval(_ request: BridgeRequest) {
        var open: (label: String, action: () -> Void)?
        switch request.caller.kind {
        case .run(let runID):
            // Already looking at this session: the request is shown there, no card on top of it.
            if viewModel.isShowing(.agents), viewModel.selectedAgentID == "run:" + runID.uuidString,
               viewModel.sessionTool == .conversation { return }
            open = (label: tr("ws.approval.open"), action: { [weak self] in self?.openWorkspace(run: runID) })
        case .external:
            open = nil
        }
        let folder = URL(fileURLWithPath: request.caller.directory).lastPathComponent
        let context = request.caller.title.isEmpty ? "\(request.caller.agent) · \(folder)"
            : "\(request.caller.agent) · \(AgentFormat.title(request.caller.title))"
        presentApprovalCard(ApprovalCenter.make(request), context: context, open: open)
    }

    /// Opens your agents in the notch (or in the main window while that is in front), optionally on one session or
    /// straight into a new one.
    func openWorkspace(run id: UUID? = nil, newSession: Bool = false) {
        if let id {
            workspace.selectedRunID = id
            viewModel.selectedAgentID = "run:" + id.uuidString
        }
        // A new session starts in the Agents tab itself: the + next to Sessions.
        if newSession { viewModel.selectedAgentID = "new" }
        viewModel.sheet = nil
        viewModel.windowSheet = nil
        viewModel.show(.panel(.agents))
    }

    /// The main window: the notch's tabs with more room, opened only on request. `continuing`: the tab you were on in the
    /// notch, which the window opens on.
    func openWindow(continuing tab: PanelTab? = nil) {
        if case .panel = viewModel.state { viewModel.show(.idle) }
        if let tab {
            viewModel.windowSheet = nil
            viewModel.windowTab = tab == .nook ? .chat : tab
        } else if !WorkspaceWindowController.shared.isVisible {
            // Already open, it stays where you are.
            viewModel.prepareWindow()
        }
        WorkspaceWindowController.shared.show(app: self)
    }

    /// Profile associated with a workspace run.
    func profile(for run: WorkspaceRun) -> AgentProfile? {
        profiles.profile(id: run.profileID)
    }

    private func presentWorkspaceApproval(_ run: WorkspaceRun, _ pending: PendingPermission) {
        CompanionNotifier.shared.approval(run, pending)
        // Looking at the conversation (in the notch or the main window): the request is right there. With the terminal or
        // browser open it is not, so a card.
        if viewModel.isShowing(.agents), viewModel.selectedAgentID == "run:" + run.id.uuidString,
           viewModel.sessionTool == .conversation { return }
        let runID = run.id
        presentApprovalCard(ApprovalCenter.make(pending, run: run), context: "\(run.provider.displayName) · \(run.title)",
                            open: (label: tr("ws.approval.open"), action: { [weak self] in self?.openWorkspace(run: runID) }))
    }

    /// The agent asks a question in a session you are not looking at: a short notice that opens it.
    private func workspaceQuestion(_ run: WorkspaceRun) {
        if viewModel.isShowing(.agents), viewModel.selectedAgentID == "run:" + run.id.uuidString,
           viewModel.sessionTool == .conversation { return }
        NookSound.play(.attention)
        let runID = run.id
        viewModel.notify(tr("ws.notice.question", run.provider.displayName, run.title), button: tr("ws.notice.open")) { [weak self] in
            self?.openWorkspace(run: runID)
        }
    }

    private func workspaceTurnFinished(_ run: WorkspaceRun) {
        CompanionNotifier.shared.turnFinished(run)
        recap.turnEnded(session: "run-" + run.id.uuidString)
        // An agent may have pushed or opened a pull request: the list refreshes when you look next.
        PullRequestStore.shared.markStale()
        let state: AgentAttention = run.status == .failed ? (run.limitedAt != nil ? .limited : .failed) : .ready
        guard attentionLedger.shouldNotify(id: run.id.uuidString, state: state, turn: Int(run.updatedAt.timeIntervalSince1970)) else { return }
        // Only notify if the user is not already looking at the workspace window.
        guard !WorkspaceWindowController.shared.isKey else { return }
        NookSound.play(run.status == .failed ? .error : .done)
        switch viewModel.state {
        case .idle, .music, .track, .done: break
        default: return
        }
        let message = run.status == .failed ? tr("ws.notice.failed", run.title) : tr("ws.notice.done", run.title)
        let runID = run.id
        viewModel.finish(message, button: tr("ws.notice.open")) { [weak self] in self?.openWorkspace(run: runID) }
    }

    // MARK: - Accounts

    /// Reauthenticates this account in its own Terminal window. Other accounts and active sessions remain unaffected.
    func reauthenticate(_ profile: AgentProfile) {
        let command: String
        switch profile.kind {
        case .claude: command = profile.environmentPrefixOnly + "claude /login"
        case .codex: command = profile.environmentPrefixOnly + "codex login"
        case .gemini: command = "gemini"
        // Antigravity signs in again through Nook, in your browser.
        case .antigravity:
            if agentConnect[profile.id]?.isBusy != true { connectAntigravity(profile, fresh: true) }
            return
        case .opencode, .cursor, .grok: command = profile.kind.loginCommand
        // ACP agents sign in themselves, in their first session.
        case .acp: return
        }
        let intro = "echo " + TerminalLauncher.shellQuote(tr("accounts.reauthIntro", profile.kind.name))
        do {
            try runVisibly(intro + " && " + command, in: FileManager.default.homeDirectoryForCurrentUser.path,
                           name: "nook-login-\(profile.id)", title: tr("accounts.terminalTitle.login", profile.kind.name))
        } catch {
            viewModel.finish(tr("accounts.terminalFailed", error.localizedDescription))
            return
        }
        Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.history.refresh(minimumInterval: 0)
                self?.refreshQuotas()
            }
        }
    }

    /// Signs out: only for this account. Codex has a dedicated command; Claude Code uses /logout.
    func logout(_ profile: AgentProfile) {
        if profile.kind == .claude, profile.usesAPIKey {
            profiles.setAPIKey("", for: profile)
            history.refresh(minimumInterval: 0)
            return
        }
        let command: String
        switch profile.kind {
        case .claude: command = profile.environmentPrefixOnly + "claude /logout"
        case .codex: command = profile.environmentPrefixOnly + "codex logout"
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp: return
        }
        do {
            try runVisibly(command, in: FileManager.default.homeDirectoryForCurrentUser.path,
                           name: "nook-logout-\(profile.id)", title: tr("accounts.terminalTitle.logout", profile.kind.name))
        } catch {
            viewModel.finish(tr("accounts.terminalFailed", error.localizedDescription))
            return
        }
        Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.history.refresh(minimumInterval: 0)
            }
        }
    }

    /// Configures how an account authenticates. A Claude key is saved in the Keychain; a Codex key is passed via stdin to
    /// `codex login --with-api-key`, saving it to that account's directory. The key never appears in arguments or logs.
    func setAPIKey(_ key: String, for profile: AgentProfile) async throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        switch profile.kind {
        case .claude:
            profiles.setAuth(profile.id, clean.isEmpty ? .cli : .apiKey)
            profiles.setAPIKey(clean, for: profile)
        case .codex:
            guard !clean.isEmpty else { return }
            guard let executable = history.executables[.codex] else { throw NookError(tr("ws.error.noExecutable", "Codex")) }
            var prepared = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: executable,
                                                    extra: profile.environment)
            prepared["NOOK_INTERNAL"] = "1"
            let environment = prepared
            try await Task.detached(priority: .userInitiated) {
                try Self.pipeKey(clean, to: executable, arguments: ["login", "--with-api-key"], environment: environment)
            }.value
            profiles.setAuth(profile.id, .apiKey)
        case .gemini, .antigravity, .opencode, .cursor, .grok, .acp:
            return
        }
        history.refresh(minimumInterval: 0)
        refreshQuotas()
    }

    /// Adds an account authenticating via API key. If saving the key fails, the account is removed.
    func addAccount(_ kind: AgentKind, label: String, apiKey: String) async throws {
        let profile = profiles.add(kind: kind, label: label)
        do {
            try await setAPIKey(apiKey, for: profile)
        } catch {
            profiles.remove(profile.id)
            throw error
        }
        connect(profiles.profile(id: profile.id) ?? profile)
    }

    /// Reverts to CLI login via the agent itself. Any Claude key is removed from the Keychain.
    func useCLILogin(_ profile: AgentProfile) {
        if profile.kind == .claude { profiles.setAPIKey("", for: profile) }
        profiles.setAuth(profile.id, .cli)
        history.refresh(minimumInterval: 0)
    }

    private nonisolated static func pipeKey(_ key: String, to executable: String, arguments: [String], environment: [String: String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data((key + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // The output cannot contain the key (passed via stdin), but only the last line is displayed.
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw NookError(tr("accounts.codexKeyFailed") + (last.isEmpty ? "" : " " + String(last.prefix(200))))
        }
    }
}

extension AgentProfile {
    /// Only the account directory prefix (no key), used for login and logout commands.
    var environmentPrefixOnly: String {
        guard let home, let variable = kind.homeVariable else { return "" }
        return "\(variable)=\(AgentProfile.shellPath(home)) "
    }
}

extension AppModel {
    /// A terminal in Nook, in `folder`, optionally running `command` first. In the notch it opens with the agent session
    /// working in that folder, or under Agents › Terminals when no session is; in the main window while that is in front.
    func openTerminal(in folder: String, command: String? = nil, title: String? = nil) {
        TerminalStore.shared.open(in: folder, command: command, title: title)
        if let session = sessionID(workingIn: folder) {
            viewModel.selectedAgentID = session
            viewModel.sessionTool = .terminal
        } else {
            viewModel.selectedAgentID = AgentsPage.terminals
        }
        viewModel.show(.panel(.agents))
    }

    /// The Agents tab on one of the tools that belong to no single session.
    func showWorkbench(_ tool: WorkbenchTool) {
        switch tool {
        case .terminals: viewModel.selectedAgentID = AgentsPage.terminals
        case .browser: viewModel.selectedAgentID = AgentsPage.browser
        case .worktrees: viewModel.selectedAgentID = AgentsPage.worktrees
        }
        viewModel.show(.panel(.agents))
    }

    /// The session in the Agents list whose folder (or worktree) is `folder`: one Nook runs first, then one it sees.
    private func sessionID(workingIn folder: String) -> String? {
        let target = URL(fileURLWithPath: folder).standardizedFileURL.path
        func same(_ path: String) -> Bool { !path.isEmpty && URL(fileURLWithPath: path).standardizedFileURL.path == target }
        if let run = workspace.activeRuns.first(where: { !$0.archived && same($0.workingDirectory) })
            ?? workspace.runs.first(where: { !$0.archived && same($0.workingDirectory) }) {
            return "run:" + run.id.uuidString
        }
        return agentSessions.first { same($0.cwd) }?.id
    }

    /// Runs a command for the user where they can see it: the built-in terminal, or the terminal app they chose.
    func runVisibly(_ command: String, in folder: String, name: String, title: String) throws {
        if workspace.settings.terminalBundleID == WorkspaceSettings.builtInTerminal {
            openTerminal(in: folder, command: command, title: title)
        } else {
            try TerminalLauncher.run(command: command, in: folder, name: name)
        }
    }
}
