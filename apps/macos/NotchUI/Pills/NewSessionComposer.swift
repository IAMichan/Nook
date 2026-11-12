import SwiftUI
import AppKit

/// Starting a session in the notch: one question, one field, and a few quiet choices underneath.
/// "What should we build in nook?" — type the task, press Return. Agent and account, mode, permissions, effort,
/// where it works (this folder or a new worktree) and the branch it starts from are small menus, already set to
/// your last choices in this folder. Nothing else to fill in: title, branch name and worktree location are derived.
struct NewSessionComposer: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var workspace: WorkspaceManager
    @EnvironmentObject var settings: WorkspaceSettings
    @ObservedObject var antigravity = AntigravityInstaller.shared
    /// The panels' icons (terminal, browser, bottom and side panel) at the top right, as in a running session.
    var headerAccessory: AnyView? = nil
    /// Called with the folder the new session will work in, so its panels open there; empty on another machine.
    var onDirectory: (String) -> Void = { _ in }
    /// Called with the new session once it runs.
    let onStarted: (UUID) -> Void

    /// Every choice for the new session. Its `task` stays empty while you type: the words live in `task` below, and
    /// `checkedConfig` puts them in when the session starts.
    @State var config = NewRunConfig()
    /// The words in the box, held outside the panel's own state: only the field reads them, so a keystroke redraws the
    /// field and not every menu, the heading and the tray of this panel (that cost a frame or more per key).
    @State var task = NewSessionTask()
    /// Whether the box holds more than whitespace: all the panel itself needs of the words (the start button, the
    /// notice). It changes only when the box becomes empty or not.
    @State var hasTask = false
    @State var images: [ImageAttachment] = []
    @State var project: ProjectInfo?
    @State var inspecting = false
    @State var starting = false
    @State var error: String?
    @State var allowShared = false
    @State var showClone = false
    /// A project just made with "New project…": the sheet that offers to publish it.
    @State var newProjectPlan: PublishPlan?
    /// The last project request from the Agents list this composer applied (`PromptLinkInbox.requestProject`).
    @State var appliedProjectRequest: UUID?
    @State var cloneURL = ""
    @State var cloning = false
    @State var pendingID = UUID()
    /// On another machine over SSH (see RemoteMachines): which one, and the folder there.
    @State var remoteMachine: RemoteMachine?
    @State var remoteFolder = ""
    /// Held, not observed: only its suggestion list watches it (`ComposerSuggestionSlot`), so a key that changes the
    /// list does not redraw this whole panel.
    @State var composerModel = ComposerModel()
    @ObservedObject var promptLinks = PromptLinkInbox.shared
    @State var linkNotice: String?
    /// A pull request link's branch is being checked out (`promptLinks.pendingCheckout`).
    @State var checkingOut = false
    /// Set once the session started: what is left in the box then is not worth bringing back.
    @State var started = false
    /// The other models the prompt also goes to, each in a session and worktree of its own (`ModelComparison`).
    @State var comparing: [ComparisonTarget] = []
    /// "New session in this worktree": the session works in the folder as it is, whatever this folder's default says.
    @State var keepCheckout = false
    @FocusState var focused: Bool

    /// Where this draft's words are kept in `ComposerDraftStore`: one draft per folder, or per machine over SSH, so what
    /// you typed for one project waits there (and in the list's unsent rows) while you start something in another.
    var draftKey: String {
        if let remoteMachine { return NewSessionDraftKey.machine(remoteMachine.id) }
        return NewSessionDraftKey.folder(config.projectPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let headerAccessory {
                HStack(spacing: NookTheme.Spacing.md) {
                    Spacer(minLength: 8)
                    headerAccessory
                }
                .frame(height: 30)
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { restoreOrPrepare(); app.refreshAgentModels(); applyPromptLink(); applyRequestedProject() }
        .onChange(of: draftKey) { _, key in ComposerDraftStore.shared.openNewSession = key }
        .onReceive(ComposerDraftStore.shared.$unsentNewSessions) { _ in dropIfDiscarded() }
        .composerFocusOnAppear($focused)
        // Closing the notch (or switching tabs) drops this view; what you typed and chose waits for its return.
        .onDisappear(perform: keepDraft)
        .onChange(of: promptLinks.pending) { _, _ in applyPromptLink() }
        .onChange(of: promptLinks.pendingProject) { _, _ in applyRequestedProject() }
        .onChange(of: workingDirectory, initial: true) { _, directory in onDirectory(directory) }
        // ⌥⌘↩, and ⌘↩ here too: start it and keep a fresh box for the next one. Return starts and opens it.
        // Above the box's own ⌘↩ (`priority`), which would only send.
        .keyCommands(["composer.startInBackground": startInBackgroundKey, "composer.send": startInBackgroundKey],
                     enabled: focused, priority: 1)
    }

    private func startInBackgroundKey() -> Bool {
        // With the `/`, `@`, `#` list open the key takes the chosen line, in the box's own handler.
        guard !composerModel.isOpen, canStart, !starting else { return false }
        start(background: true)
        return true
    }

    /// The draft on screen was discarded from the list: the box empties too.
    private func dropIfDiscarded() {
        guard hasTask, !started, ComposerDraftStore.shared.draft(for: draftKey) == nil else { return }
        NewSessionDraft.discard(draftKey)
        setTask("")
        images = []
    }

    func setTask(_ text: String) {
        guard text != task.text else { return }
        task.text = text
        let filled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if filled != hasTask { hasTask = filled }
        // Typing again after a start begins the next draft.
        if !text.isEmpty { started = false }
        if !started { ComposerDraftStore.shared.save(sessionID: draftKey, text: text) }
    }

    /// The folder the panels open in: none for a session on another machine.
    private var workingDirectory: String {
        remoteMachine == nil ? config.projectPath : ""
    }

    private var content: some View {
        VStack(spacing: NookTheme.Spacing.xl) {
            Spacer(minLength: 0)
            heading
            if showClone { cloneRow }
            if remoteMachine != nil { remoteRow }
            // A machine that logs in with a password asks for it once, before its first session in this run of Nook.
            if let machine = remoteMachine, !RemotePasswords.shared.isUnlocked(machine) {
                RemotePasswordField(machine: machine) { remoteMachine = $0 }
                    .frame(maxWidth: 640)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                // Where it works and the branch it starts from sit in a tray tucked under the box.
                VStack(spacing: 0) {
                    box.zIndex(1)
                    belowBox
                }
                // The tray's choices show their tips like the box's own (`composerTip`), not as slow system tooltips.
                .composerTips()
                notice
            }
            .frame(maxWidth: 640)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The box

    /// The same composer a running session answers in, with the choices for the new session inside it.
    private var box: some View {
        // The words are read in `TaskField`, not here: SwiftUI reads a binding's value when it compares the composer it
        // was given with the last one, and a binding made in this `body` would then redraw the whole panel per key.
        TaskField(task: task, set: setTask) { taskBinding in
            composer(taskBinding)
        }
    }

    private func composer(_ taskBinding: Binding<String>) -> some View {
        SessionComposer(
            text: taskBinding,
            prompt: tr("compose.prompt"),
            minHeight: 56,
            lines: 3...8,
            canSend: canStart,
            sending: starting,
            sendLabel: blockingReason ?? tr("ws.new.start"),
            focus: $focused,
            onSend: { start() }
        ) {
            // The same row as in a running session and in the chat: plus menu, the agent and model, then mode and rights.
            ComposerPlusMenu(attach: attachFile, screenshot: { app.captureFrontWindow() }) {}
            agentMenu
            ComposerDivider()
            if config.mode == .plan {
                modeMenu
                ComposerDivider()
            }
            usageLimits
        }
        .rich(composerModel, composerConfig)
        .images($images)
        .dictating()
        // One step more or less effort without opening the picker.
        .keyCommands(["effort.increase": { stepEffort(.up) }, "effort.decrease": { stepEffort(.down) }])
    }

    private var composerConfig: ComposerConfig {
        var rich = ComposerConfig()
        rich.fileRoot = config.projectPath.isEmpty ? nil : config.projectPath
        rich.keepsBigPastes = true
        // The session has no id yet: its pasted secrets wait in the composer's own folder. Not for another machine.
        rich.secretScope = remoteMachine == nil ? SecretFiles.composerScope : nil
        return rich
    }

    private func attachFile() {
        guard !config.projectPath.isEmpty,
              let ref = ComposerFilePicker.pick(startingIn: config.projectPath) else { return }
        setTask(ComposerAttachments.appending(ref, to: task.text))
        focused = true
    }

    // MARK: State

    var projectMenu: (favorites: [String], recent: [String]) {
        // Folders of sessions without a project stay out of Recent; one you turned into a project is a favorite.
        // An archived project stays out (Settings › Projects brings it back), unless it is the one chosen now.
        ProjectSettings.projectMenu(
            favorites: ProjectSettings.withoutArchived(settings.favoriteProjects, overrides: settings.projectOverrides),
            recent: ProjectSettings.withoutArchived(
                [config.projectPath, settings.lastProject] + settings.recentProjects + app.history.sessions.map(\.cwd),
                overrides: settings.projectOverrides)
                .filter { !ScratchProjects.isScratch($0) }
        )
    }

    var worktreeAllowed: Bool {
        guard let project, project.verdict == .ok else { return false }
        return project.repoRoot != nil && project.hasCommits && workspace.gitAvailable == true
    }

    var worktreeBlockedReason: String {
        if workspace.gitAvailable == false { return tr("ws.error.noGit") }
        guard let project else { return tr("ws.new.pickWorkspace") }
        if project.repoRoot == nil { return tr("ws.new.worktreeNeedsRepo") }
        if !project.hasCommits { return tr("ws.new.worktreeNeedsCommit") }
        return ""
    }

    var sharing: [WorkspaceRun] {
        guard let project, project.verdict == .ok else { return [] }
        return workspace.activeRuns(sharing: project.repoRoot ?? project.path)
    }

    var blockingReason: String? {
        if let problem = shownConfig.problem { return tr("ws.error.config." + problem.rawValue) }
        // On another machine the agent is looked up there, not on this Mac.
        if let machine = remoteMachine {
            return RemotePasswords.shared.isUnlocked(machine) ? nil : tr("remote.password.needed", machine.name)
        }
        if project?.verdict != .ok { return tr("ws.error.config.missingWorkspace") }
        if !settings.isAgentOn(config.provider, for: config.projectPath) { return tr("sc.agents.offHere", config.provider.displayName) }
        if config.provider == .antigravity, antigravity.installed == nil { return tr("ws.antigravity.installFirst") }
        if workspace.executable(config.provider) == nil { return tr("ws.error.noExecutable", config.provider.displayName) }
        if !comparing.isEmpty {
            // Every model works in a worktree of its own.
            if !worktreeBlockedReason.isEmpty { return tr("compare.needsWorktree", worktreeBlockedReason) }
            if let missing = comparisonTargets.first(where: { workspace.executable($0.provider) == nil }) {
                return tr("ws.error.noExecutable", missing.provider.displayName)
            }
            return nil
        }
        if config.isolation == .folder, !allowShared, !sharing.isEmpty { return tr("ws.new.sharedBlocked") }
        return nil
    }

    /// Every model the prompt goes to, the chosen one first.
    var comparisonTargets: [ComparisonTarget] {
        ModelComparison.targets(primary: ComparisonTarget(provider: config.provider, profileID: config.profileID, model: config.model),
                                extras: comparing)
    }

    var canStart: Bool { !starting && blockingReason == nil }

    /// The configuration as it will start: with the branch name derived from the task, which only gets filled in at the
    /// moment of starting. Checking `config` itself would see an empty branch name and refuse every new worktree.
    var checkedConfig: NewRunConfig { configured(task: task.text) }

    /// `checkedConfig` as the panel checks it while you type, without reading the words (see `task`): the check only
    /// asks whether there are any, and a branch name derived from words is always a valid one.
    private var shownConfig: NewRunConfig { configured(task: hasTask ? "task" : "") }

    func configured(task text: String) -> NewRunConfig {
        var copy = config
        copy.task = text
        copy.branchName = WorktreeNaming.branchName(task: text, id: pendingID)
        if let remoteMachine {
            copy.remote = RemoteTarget(machine: remoteMachine, directory: remoteFolder.trimmingCharacters(in: .whitespaces))
            copy.baseBranch = config.baseBranch.trimmingCharacters(in: .whitespaces)
        }
        return copy
    }

    /// The default branch first ("origin/main"), then the rest alphabetically.
    func sortedBranches(_ branches: [String]) -> [String] {
        let base = project?.defaultBase
        return branches.sorted { a, b in
            if a == base { return true }
            if b == base { return false }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }

}

/// A new-session draft as you left it: the task, its pictures and big pastes, and every choice around it. One per folder
/// (or machine), kept in memory only; the task alone also goes to `ComposerDraftStore` for after a relaunch.
@MainActor
struct NewSessionDraft {
    static var saved: [String: NewSessionDraft] = [:]
    /// The draft the box showed when it last closed, which it opens on again.
    static var lastKey: String?

    /// Forgets a draft you discarded from the list.
    static func discard(_ key: String) {
        saved[key] = nil
        if lastKey == key { lastKey = nil }
    }

    var config: NewRunConfig
    var images: [ImageAttachment]
    var project: ProjectInfo?
    var allowShared: Bool
    var showClone: Bool
    var cloneURL: String
    var pendingID: UUID
    var remoteMachine: RemoteMachine?
    var remoteFolder: String
    var excerpts: [String: String]
    var comparing: [ComparisonTarget]
    var keepCheckout: Bool
}

/// The words typed in the new-session box (`NewSessionComposer.task`): observed by the field alone, so a keystroke does
/// not redraw the panel around it.
@MainActor
@Observable
final class NewSessionTask {
    var text = ""
}

/// Hands the composer a binding to the box's words, so only this view, not the panel around it, observes them.
private struct TaskField<Content: View>: View {
    let task: NewSessionTask
    let set: (String) -> Void
    @ViewBuilder let content: (Binding<String>) -> Content

    var body: some View {
        content(Binding(get: { task.text }, set: set))
    }
}

/// A quiet line under the composer's question that is underlined while the pointer is on it, like a link.
struct HoverUnderlinedLabel: View {
    let title: String
    let color: Color
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(color)
            .underline(hovering, color: color)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
