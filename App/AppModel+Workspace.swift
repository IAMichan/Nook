import SwiftUI
import AppKit

extension RunProvider {
    var kind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    var color: Color { kind.color }

    init?(kind: AgentKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .gemini: return nil
        }
    }
}

private final class SheetBox { var sheet: NSWindow? }

/// The workspace window controller. A single window; opening brings it to front.
@MainActor
final class WorkspaceWindowController {
    static let shared = WorkspaceWindowController()
    private var window: NSWindow?

    var isKey: Bool { window?.isKeyWindow ?? false }

    /// Shows `content` as a native sheet on the workspace window. The content gets a closure that ends the sheet;
    /// `onClosed` runs once it has ended, however it was closed.
    func presentSheet<V: View>(size: NSSize, onClosed: @escaping () -> Void,
                               @ViewBuilder content: (@escaping () -> Void) -> V) {
        guard let parent = window, parent.attachedSheet == nil else { onClosed(); return }
        let box = SheetBox()
        let close: () -> Void = { [weak parent] in
            if let sheet = box.sheet { parent?.endSheet(sheet) }
        }
        let host = NSHostingController(rootView: content(close).onExitCommand(perform: close))
        host.sizingOptions = []
        let sheet = NSWindow(contentViewController: host)
        sheet.styleMask = [.titled]
        sheet.setContentSize(size)
        box.sheet = sheet
        parent.beginSheet(sheet) { _ in
            sheet.orderOut(nil)
            box.sheet = nil
            onClosed()
        }
    }

    func show(app: AppModel) {
        if window == nil {
            let root = WorkspaceView()
                .environmentObject(app)
                .environmentObject(app.workspace)
                .environmentObject(app.workspace.settings)
            let host = NSHostingController(rootView: root)
            // The window sets its own minSize; letting the hosting view also drive it makes the inspector's
            // appearance resize the window in a layout loop.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            // Dark for the window and everything presented from it (sheets inherit the window's appearance). Asking for it
            // with `.preferredColorScheme` inside the window and inside each sheet makes the sheets re-negotiate it on every
            // layout pass, which loops ("needing another Update Constraints in Window pass").
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = tr("ws.windowTitle")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = false
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 1240, height: 780))
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("NookWorkspace")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension AppModel {
    // MARK: - Workspace

    /// Connects the workspace to the rest of Nook. Run once at startup.
    func startWorkspace() {
        workspace.executable = { [weak self] provider in
            self?.history.executables[provider.kind]
        }
        workspace.accountEnvironment = { [weak self] profileID in
            guard let self, let profile = self.profiles.profile(id: profileID) else { return [:] }
            return self.profiles.launchEnvironment(profile)
        }
        workspace.onApproval = { [weak self] run, pending in self?.presentWorkspaceApproval(run, pending) }
        workspace.onApprovalGone = { [weak self] requestID in self?.viewModel.dismissCard(id: "wsapproval-" + requestID) }
        workspace.onTurnFinished = { [weak self] run in self?.workspaceTurnFinished(run) }
        workspace.openBuiltInTerminal = { [weak self] folder in self?.openTerminal(in: folder) }
    }

    /// Opens your agents in the notch, optionally on one session or straight into a new one. Everything you do with
    /// agents happens in the notch; the separate window is only for who asks for it (menu bar › Open in window).
    func openWorkspace(run id: UUID? = nil, newSession: Bool = false) {
        if let id {
            workspace.selectedRunID = id
            viewModel.selectedAgentID = "run:" + id.uuidString
        }
        // A new session starts in the Agents tab itself: the + next to Sessions.
        if newSession { viewModel.selectedAgentID = "new" }
        viewModel.sheet = nil
        viewModel.show(.panel(.agents))
    }

    /// The separate main window (chat, agents and workspace side by side), opened only on request.
    func openWindow() {
        if case .panel = viewModel.state { viewModel.show(.idle) }
        WorkspaceWindowController.shared.show(app: self)
    }

    /// Profile associated with a workspace run.
    func profile(for run: WorkspaceRun) -> AgentProfile? {
        profiles.profile(id: run.profileID)
    }

    private func presentWorkspaceApproval(_ run: WorkspaceRun, _ pending: PendingPermission) {
        // If the user is already looking at this session in the workspace, the prompt is shown there; no overlapping card.
        if WorkspaceWindowController.shared.isKey && workspace.selectedRunID == run.id { return }
        if viewModel.state == .panel(.agents), viewModel.selectedAgentID == "run:" + run.id.uuidString { return }
        let runID = run.id
        presentApprovalCard(ApprovalCenter.make(pending, run: run), context: "\(run.provider.displayName) · \(run.title)",
                            open: (label: tr("ws.approval.open"), action: { [weak self] in self?.openWorkspace(run: runID) }))
    }

    private func workspaceTurnFinished(_ run: WorkspaceRun) {
        recap.turnEnded(session: "run-" + run.id.uuidString)
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
                self?.codex.refreshNow()
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
        case .gemini: return
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
        case .gemini:
            return
        }
        history.refresh(minimumInterval: 0)
        codex.refreshNow()
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

extension Notification.Name {
    static let nookWorkspaceNewSession = Notification.Name("nookWorkspaceNewSession")
    /// Switches the main window to a part (object: WorkspacePane raw value).
    static let nookMainWindowPane = Notification.Name("nookMainWindowPane")
    /// Switches Workspace to a tool (object: WorkbenchView.Tool raw value).
    static let nookWorkbenchTool = Notification.Name("nookWorkbenchTool")
}

extension AppModel {
    /// Opens Nook's main window on a part (and, in Workspace, a tool).
    func openMainWindow(_ pane: WorkspacePane, tool: WorkbenchView.Tool? = nil) {
        if case .panel = viewModel.state { viewModel.show(.idle) }
        WorkspaceWindowController.shared.show(app: self)
        NotificationCenter.default.post(name: .nookMainWindowPane, object: pane.rawValue)
        if let tool { NotificationCenter.default.post(name: .nookWorkbenchTool, object: tool.rawValue) }
    }

    /// A terminal in Nook, in `folder`, optionally running `command` first. Opens in the notch's Workspace tab, or in the
    /// window if you are working there.
    func openTerminal(in folder: String, command: String? = nil, title: String? = nil) {
        TerminalStore.shared.open(in: folder, command: command, title: title)
        if WorkspaceWindowController.shared.isKey {
            openMainWindow(.workspace, tool: .terminals)
        } else {
            showWorkbench(.terminals)
        }
    }

    /// The notch's Workspace tab, on one of its tools.
    func showWorkbench(_ tool: WorkbenchView.Tool) {
        UserDefaults.standard.set(tool.rawValue, forKey: "workbench.tool")
        NotificationCenter.default.post(name: .nookWorkbenchTool, object: tool.rawValue)
        viewModel.show(.panel(.workspace))
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
