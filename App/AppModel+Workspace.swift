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

/// Het venster van de werkruimte. Eén venster; openen brengt het naar voren.
@MainActor
final class WorkspaceWindowController {
    static let shared = WorkspaceWindowController()
    private var window: NSWindow?

    var isKey: Bool { window?.isKeyWindow ?? false }

    func show(app: AppModel) {
        if window == nil {
            let root = WorkspaceView()
                .environmentObject(app)
                .environmentObject(app.workspace)
                .environmentObject(app.workspace.settings)
            let host = NSHostingController(rootView: root)
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
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
    // MARK: Werkruimte

    /// Verbindt de werkruimte met de rest van Nook. Eén keer, bij het opstarten.
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
    }

    /// Opent de werkruimte, eventueel meteen op een sessie.
    func openWorkspace(run id: UUID? = nil, newSession: Bool = false) {
        if case .panel = viewModel.state { viewModel.show(.idle) }
        if let id { workspace.selectedRunID = id }
        WorkspaceWindowController.shared.show(app: self)
        if newSession { NotificationCenter.default.post(name: .nookWorkspaceNewSession, object: nil) }
    }

    /// Account van een werkruimte-sessie.
    func profile(for run: WorkspaceRun) -> AgentProfile? {
        profiles.profile(id: run.profileID)
    }

    /// Eerdere sessies uit de transcripten, zonder die van de werkruimte (die staan daar al, met meer detail).
    var pastSessionsOutsideWorkspace: [PastSession] {
        let own = Set(workspace.runs.compactMap(\.providerSessionID))
        return history.sessions.filter { !own.contains($0.sessionID) }
    }

    private func presentWorkspaceApproval(_ run: WorkspaceRun, _ pending: PendingPermission) {
        // Kijk je al naar deze sessie in de werkruimte, dan staat de vraag daar; geen kaart erbovenop.
        if WorkspaceWindowController.shared.isKey && workspace.selectedRunID == run.id { return }
        let token = "wsapproval-" + pending.id
        let runID = run.id
        let requestID = pending.id
        viewModel.register("\(token)#yes") { [weak self] in self?.workspace.decide(runID, requestID: requestID, .allow) }
        viewModel.register("\(token)#always") { [weak self] in self?.workspace.decide(runID, requestID: requestID, .always) }
        viewModel.register("\(token)#no") { [weak self] in self?.workspace.decide(runID, requestID: requestID, .deny) }
        viewModel.register("\(token)#open") { [weak self] in self?.openWorkspace(run: runID) }

        let input = pending.input.dictionary
        let assessment: CommandAssessment
        if let command = ToolSummary.command(input) {
            assessment = CommandRisk.assess(command)
        } else {
            assessment = CommandAssessment(level: .review, title: "", note: tr("ws.approval.note"))
        }
        let detail: CardDetail
        let height: CGFloat
        if let edit = AgentHub.editDiff(tool: pending.tool, input: input) {
            detail = .diff(title: pending.summary, lines: edit.lines, note: assessment.note)
            height = 150 + min(166, CGFloat(edit.lines.count) * 15 + 34)
        } else {
            detail = .command(String((ToolSummary.command(input) ?? pending.summary).prefix(160)), note: assessment.note)
            height = 214
        }
        var extra = [CardAction(label: tr("ws.approval.open"), outcome: .callback("\(token)#open", ""))]
        if pending.canAlways { extra.insert(CardAction(label: tr("button.always"), outcome: .callback("\(token)#always", "")), at: 0) }
        let card = NookCard(
            id: token,
            mood: assessment.level == .danger ? .worry : .waiting,
            context: "\(run.provider.displayName) · \(run.title)",
            title: tr("ws.approval.title", run.provider.kind.shortName, pending.tool),
            detail: detail,
            primary: CardAction(label: tr("button.allow"), outcome: .callback("\(token)#yes", "")),
            secondary: CardAction(label: tr("button.deny"), outcome: .callback("\(token)#no", "")),
            contentHeight: height,
            extra: extra,
            urgent: true
        )
        viewModel.presentUrgent(card)
        NookSound.play(.attention)
    }

    private func workspaceTurnFinished(_ run: WorkspaceRun) {
        // Alleen melden als je niet al in de werkruimte kijkt.
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

    // MARK: Accounts

    /// Opnieuw inloggen met dit account, in een eigen Terminal-venster. Andere accounts en lopende sessies merken er niets van.
    func reauthenticate(_ profile: AgentProfile) {
        let command: String
        switch profile.kind {
        case .claude: command = profile.environmentPrefixOnly + "claude /login"
        case .codex: command = profile.environmentPrefixOnly + "codex login"
        case .gemini: command = "gemini"
        }
        let intro = "echo " + TerminalLauncher.shellQuote(tr("accounts.reauthIntro", profile.kind.name))
        do {
            try TerminalLauncher.run(command: intro + " && " + command, in: FileManager.default.homeDirectoryForCurrentUser.path,
                                     name: "nook-login-\(profile.id)")
        } catch {
            viewModel.finish(tr("accounts.terminalFailed", error.localizedDescription))
            return
        }
        Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.history.refresh(minimumInterval: 0)
            }
        }
    }

    /// Uitloggen: alleen voor dit account. Codex heeft er een eigen commando voor; Claude Code doet het met /logout.
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
            try TerminalLauncher.run(command: command, in: FileManager.default.homeDirectoryForCurrentUser.path,
                                     name: "nook-logout-\(profile.id)")
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

    /// Kiest hoe een account inlogt. Een Claude-sleutel gaat naar de Keychain; een Codex-sleutel geeft Nook via stdin aan
    /// `codex login --with-api-key`, dat hem in de map van dit account bewaart. De sleutel komt nooit in een argument of log.
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
    }

    /// Terug naar inloggen via de agent zelf. Een Claude-sleutel wordt uit de Keychain gehaald.
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
            // De uitvoer kan de sleutel niet bevatten (hij ging via stdin), maar we tonen alleen de laatste regel.
            let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw NookError(tr("accounts.codexKeyFailed") + (last.isEmpty ? "" : " " + String(last.prefix(200))))
        }
    }
}

extension AgentProfile {
    /// Alleen de accountmap (geen sleutel), voor login- en logoutcommando's.
    var environmentPrefixOnly: String {
        guard let home, let variable = kind.homeVariable else { return "" }
        return "\(variable)=\(AgentProfile.shellPath(home)) "
    }
}

extension Notification.Name {
    static let nookWorkspaceNewSession = Notification.Name("nookWorkspaceNewSession")
}
