import SwiftUI
import SystemConfiguration
import AppKit

/// App and file icons by path. `NSWorkspace.icon(forFile:)` asks Launch Services each time, and the menus and settings
/// rows that show icons redraw often.
enum FileIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    static func icon(_ path: String) -> NSImage {
        if let known = cache.object(forKey: path as NSString) { return known }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

/// Where "Open in" opens a session's folder: Finder, Nook's terminal, an installed terminal app or an editor.
struct OpenInTarget: Identifiable, Hashable {
    static let finder = "com.apple.finder"
    static let nookTerminal = WorkspaceSettings.builtInTerminal

    let id: String
    let name: String
    let appURL: URL?

    /// Finder first, then Nook's own terminal, the terminal apps and the editors installed on this Mac.
    @MainActor
    static func available() -> [OpenInTarget] {
        var targets = [OpenInTarget(id: finder, name: "Finder", appURL: NSWorkspace.shared.urlForApplication(withBundleIdentifier: finder))]
        for choice in WorkspaceSettings.installed(WorkspaceSettings.terminalCandidates) + WorkspaceSettings.installed(WorkspaceSettings.editorCandidates) {
            let url = choice.bundleID == nookTerminal ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: choice.bundleID)
            let name = choice.bundleID == nookTerminal ? tr("agents.panel.nookTerminal") : choice.name
            targets.append(OpenInTarget(id: choice.bundleID, name: name, appURL: url))
        }
        return targets
    }

    /// The app's own icon; Nook's terminal has none, so it gets a symbol.
    @ViewBuilder
    var icon: some View {
        if let appURL {
            Image(nsImage: FileIcons.icon(appURL.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal").font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.textSecondary)
        }
    }
}

/// This Mac's name, as Finder shows it (Settings › General › Sharing). Read from the system configuration, which answers
/// at once; `Host.current()` resolves every host name and address first and can block for seconds.
enum MachineName {
    static let local: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}

/// What you can do with a session at a glance: the machine it runs on, open its folder in the app you
/// use, run or add a project script, the branch it started from, the one git action its branch needs (with the others
/// behind the arrow), and what changed. Every git step is your click; the agent only writes the commit message and the
/// pull request.
struct SessionPanel: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject var model: FolderGitModel
    /// A session Nook runs: commit, push and pull request go through its workspace (and its agent writes the texts).
    let runID: UUID?
    let agentWorking: Bool
    let showChanges: () -> Void
    let close: () -> Void

    @AppStorage("agents.panel.openIn") private var openInID = OpenInTarget.finder
    @State private var targets: [OpenInTarget] = []
    @State private var machine = ""
    @State private var scripts: [ProjectScript] = []
    @State private var addingScript = false
    @State private var scriptName = ""
    @State private var scriptCommand = ""
    @State private var quick: GitQuickState?
    @State private var progress: String?
    @State private var confirmDefault: GitQuickAction?
    @State private var error: String?

    private var directory: String { model.directory }
    private var run: WorkspaceRun? { runID.flatMap { workspace.run($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            machineRow
            openInRow
            scriptRows
            if model.isRepository {
                DropdownDivider()
                branchRow
                commitRow
                changesRow
            }
            if let confirmDefault { defaultBranchConfirmation(confirmDefault) }
            // A failed action shows as a toast; this is only the script form's own problem.
            if let message = error {
                Text(message)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, NookTheme.Spacing.sm)
            }
        }
        .padding(NookTheme.Spacing.sm)
        .frame(width: 300, alignment: .leading)
        .background(DropdownStyle.panel)
        .task(id: directory) {
            targets = OpenInTarget.available()
            let folder = directory
            machine = await Task.detached(priority: .utility) { MachineName.local }.value
            scripts = await Task.detached(priority: .utility) { ProjectScripts.load(folder: folder) }.value
            await model.refresh()
        }
        // Looked at again whenever git does (after a turn, a commit, a refresh).
        .task(id: runID.flatMap { workspace.git[$0]?.updated }) {
            guard let runID, progress == nil else { return }
            quick = await workspace.quickGitState(runID)
        }
    }

    // MARK: Machine and folder

    private var machineRow: some View {
        PanelRow(icon: AnyView(HStack(spacing: NookTheme.Spacing.xxs) {
            Image(systemName: "laptopcomputer")
            Image(systemName: "folder")
        }.font(NookTheme.font(11, .medium)).foregroundStyle(NookTheme.textSecondary).fixedSize()),
                 title: machine.isEmpty ? "Mac" : machine,
                 detail: AgentPathFormat.tilde(directory),
                 iconWidth: 34,
                 menu: AnyView(Group {
                     Button(tr("button.openTerminalHere")) { done { app.openTerminal(in: directory) } }
                     Button(tr("agents.panel.copyPath")) { Pasteboard.copy(directory) }
                 }))
    }

    private var openInRow: some View {
        let target = targets.first { $0.id == openInID } ?? targets.first
        return PanelRow(icon: target.map { AnyView($0.icon) } ?? symbol("folder"),
                        title: tr("agents.panel.openIn", target?.name ?? "Finder"),
                        disabledReason: FileManager.default.fileExists(atPath: directory) ? nil : tr("ws.inspector.worktreeRemoved"),
                        action: { if let target { open(target) } },
                        menu: AnyView(Group {
                            ForEach(targets) { option in
                                Button {
                                    openInID = option.id
                                    open(option)
                                } label: {
                                    if option.id == target?.id { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                                }
                            }
                        }))
    }

    private func open(_ target: OpenInTarget) {
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        done {
            switch target.id {
            case OpenInTarget.finder: NSWorkspace.shared.open(url)
            case OpenInTarget.nookTerminal: app.openTerminal(in: directory)
            default:
                guard let appURL = target.appURL else { return }
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    // MARK: Project scripts

    @ViewBuilder
    private var scriptRows: some View {
        ForEach(scripts) { script in
            PanelRow(icon: symbol("play"), title: script.name, help: script.command, action: { runScript(script) })
        }
        if addingScript {
            scriptForm
        } else {
            PanelRow(icon: symbol("plus"), title: tr("agents.panel.addScript"), help: tr("agents.panel.addScriptHelp"),
                     disabledReason: directory.isEmpty ? tr("ws.inspector.noRepo") : nil,
                     action: { addingScript = true })
        }
    }

    private var scriptForm: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TextField(tr("agents.panel.scriptName"), text: $scriptName)
                .textFieldStyle(.roundedBorder)
            TextField(tr("agents.panel.scriptCommand"), text: $scriptCommand)
                .textFieldStyle(.roundedBorder)
                .font(NookTheme.TextStyle.code)
                .onSubmit(saveScript)
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("agents.panel.scriptFile"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(2)
                Spacer(minLength: 4)
                SmallGhostButton(title: tr("button.cancel")) { resetScriptForm() }
                SmallPrimaryButton(title: tr("agents.panel.scriptSave"), action: saveScript)
                    .disabled(scriptCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(NookTheme.TextStyle.body)
        .padding(NookTheme.Spacing.md)
    }

    private func saveScript() {
        let name = scriptName, command = scriptCommand, folder = directory
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                let found = try await Task.detached(priority: .userInitiated) { () throws -> [ProjectScript] in
                    try ProjectScripts.add(name: name, command: command, folder: folder)
                    return ProjectScripts.load(folder: folder)
                }.value
                scripts = found
                error = nil
                resetScriptForm()
            } catch let failure {
                error = failure.localizedDescription
            }
        }
    }

    private func resetScriptForm() {
        addingScript = false
        scriptName = ""
        scriptCommand = ""
    }

    /// In a terminal of its own in the session's folder; a script that serves a page opens it in Nook's browser.
    private func runScript(_ script: ProjectScript) {
        done { app.openTerminal(in: directory, command: script.command, title: script.name) }
        guard script.autoOpenPreview, let url = script.previewURL else { return }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            BrowserStore.shared.go(url.absoluteString)
        }
    }

    // MARK: Branch

    /// "From origin/main": what the branch started from (or compares against), with the branches to switch to.
    private var branchRow: some View {
        let branch = model.status?.branch
        let base = run?.baseBranch ?? model.base
        let title = base.flatMap { $0 == branch ? nil : tr("agents.panel.from", $0) } ?? (branch ?? tr("agents.git.detached"))
        var trailing: String?
        if let status = model.status, status.upstream != nil, status.ahead + status.behind > 0 {
            trailing = "↑\(status.ahead) ↓\(status.behind)"
        }
        return PanelRow(icon: symbol("arrow.triangle.branch"), title: title,
                        detail: title == branch ? nil : branch, trailing: trailing.map { AnyView(Text($0).font(NookTheme.mono(11))) },
                        menu: AnyView(Group {
                            Section(tr("agents.panel.switchBranch")) {
                                ForEach(model.branches, id: \.self) { name in
                                    Button {
                                        model.checkout(name)
                                    } label: {
                                        if name == branch { Label(name, systemImage: "checkmark") } else { Text(name) }
                                    }
                                }
                            }
                            .disabled(agentWorking || model.working || model.branches.count < 2)
                            if let branch {
                                Divider()
                                Button(tr("agents.panel.copyBranch")) { Pasteboard.copy(branch) }
                            }
                            if agentWorking {
                                Divider()
                                Text(tr("agents.git.lockedWhileWorking"))
                            }
                        }))
    }

    // MARK: Commit, push, pull request

    @ViewBuilder
    private var commitRow: some View {
        if let runID {
            runCommitRow(runID)
        } else {
            // A session Nook only sees: pushing is all it does here; committing is left to the agent or you.
            PanelRow(icon: symbol("arrow.up.circle"),
                     title: model.status.map { $0.ahead > 0 ? tr("agents.git.pushAhead", $0.ahead) : tr("agents.git.push") } ?? tr("agents.git.push"),
                     disabledReason: model.canPush ? nil : tr("agents.panel.commitNookOnly"),
                     action: { model.push() })
        }
    }

    private func runCommitRow(_ runID: UUID) -> some View {
        let active = run?.status.isActive == true
        let resolved: (action: GitQuickAction?, reason: String?)
        switch quick.map(GitQuickResolver.resolve) {
        case .success(let found)?: resolved = (found, nil)
        case .failure(let why)?: resolved = (nil, tr(why.key))
        case nil: resolved = (nil, tr("agents.git.noChanges"))
        }
        let action = resolved.action
        let reason = active ? tr("ws.error.busy") : resolved.reason
        let files = workspace.git[runID]?.status?.files ?? model.files
        let behind = (quick?.behind ?? 0) > 0
        return PanelRow(icon: progress != nil ? AnyView(ProgressView().controlSize(.mini)) : symbol(action.map(Self.actionSymbol) ?? "checkmark.circle"),
                        title: progress ?? action.map { tr($0.labelKey) } ?? tr("ws.quick.commit"),
                        detail: progress == nil && action == nil ? reason : nil,
                        disabledReason: progress ?? (action == nil || active ? reason : nil),
                        action: { if let action { start(action) } },
                        menu: AnyView(Group {
                            Button(tr("ws.git.commit")) { done { app.viewModel.open(.commit(runID)) } }
                                .disabled(files.isEmpty || active)
                            Button(tr("ws.git.push")) { push(runID) }
                                .disabled(active || progress != nil || model.status?.detached == true)
                            Button(tr("ws.git.pullRequest")) { done { app.viewModel.open(.pullRequest(runID)) } }
                                .disabled(active)
                            Button(tr("ws.quick.pull")) { perform(.pull) }
                                .disabled(active || progress != nil || !behind)
                            if let link = workspace.openPullRequests[runID] {
                                Divider()
                                Button(tr("ws.quick.viewPR")) { done { BrowserStore.show(link) } }
                            }
                        }))
    }

    private static func actionSymbol(_ action: GitQuickAction) -> String {
        switch action {
        case .commit: return "checkmark.circle"
        case .commitPush, .push: return "arrow.up.circle"
        case .commitPushPR, .pushPR, .createPR: return "arrow.triangle.pull"
        case .pull: return "arrow.down.circle"
        }
    }

    private func start(_ action: GitQuickAction) {
        if quick?.isDefaultBranch == true && action.pushes { confirmDefault = action } else { perform(action) }
    }

    private func perform(_ action: GitQuickAction) {
        guard let runID else { return }
        confirmDefault = nil
        progress = tr(action.labelKey)
        Task {
            do {
                // A pull request it made stays put: "View PR" in the menu opens it in Nook's browser when you want it.
                let link = try await workspace.performQuickGit(runID, action, progress: { progress = $0 })
                ToastCenter.shared.gitQuick(action, result: .success(link))
            } catch let failure {
                ToastCenter.shared.gitQuick(action, result: .failure(failure))
            }
            progress = nil
            quick = await workspace.quickGitState(runID)
            await model.refresh()
        }
    }

    private func push(_ runID: UUID) {
        progress = tr("ws.quick.pushing")
        Task {
            do {
                try await workspace.push(runID)
                ToastCenter.shared.gitQuick(.push, result: .success(nil))
            } catch let failure {
                ToastCenter.shared.gitQuick(.push, result: .failure(failure))
            }
            progress = nil
            quick = await workspace.quickGitState(runID)
            await model.refresh()
        }
    }

    /// Pushing to the default branch asks first, right here in the panel.
    private func defaultBranchConfirmation(_ action: GitQuickAction) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("ws.quick.defaultMessage", quick?.branch ?? ""))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NookTheme.Spacing.sm) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("button.cancel")) { confirmDefault = nil }
                SmallPrimaryButton(title: tr("ws.quick.confirm")) { perform(action) }
            }
        }
        .padding(NookTheme.Spacing.md)
    }

    // MARK: Changes

    private var changesRow: some View {
        let files = runID.flatMap { workspace.git[$0]?.status?.files } ?? model.changes
        let added = files.compactMap(\.added).reduce(0, +)
        let removed = files.compactMap(\.removed).reduce(0, +)
        return PanelRow(icon: symbol("plus.forwardslash.minus"),
                        title: files.isEmpty ? tr("agents.panel.changes") : tr("agents.git.changes", files.count),
                        trailing: AnyView(HStack(spacing: 5) {
                            Text("+\(added)").foregroundStyle(NookTheme.mint)
                            Text("−\(removed)").foregroundStyle(NookTheme.coral)
                        }.font(NookTheme.mono(11.5))),
                        disabledReason: files.isEmpty ? tr("agents.git.noChanges") : nil,
                        action: { done(showChanges) })
    }

    // MARK: Helpers

    private func symbol(_ name: String) -> AnyView {
        AnyView(Image(systemName: name).font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.textSecondary))
    }

    /// Closes the panel, then does what was asked (a notch task or another app takes over from here).
    private func done(_ action: () -> Void) {
        close()
        action()
    }
}

/// One line of the session panel: an icon, a title (with an optional grey line under it) and something on the right.
/// With an action the line is a button; the arrow after the thin divider holds the alternatives. Without an action the
/// whole line opens those alternatives.
private struct PanelRow: View {
    let icon: AnyView
    let title: String
    var detail: String? = nil
    var trailing: AnyView? = nil
    var iconWidth: CGFloat = 20
    var help: String? = nil
    var disabledReason: String? = nil
    var action: (() -> Void)? = nil
    var menu: AnyView? = nil
    @State private var hovering = false

    private var enabled: Bool { disabledReason == nil }

    var body: some View {
        HStack(spacing: 0) {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.55)
                if let menu {
                    Rectangle().fill(NookTheme.line2).frame(width: 1, height: 18)
                    Menu { menu } label: { chevron.frame(width: 30, height: 34).contentShape(Rectangle()) }
                        .composerMenu()
                        .help(tr("a11y.more"))
                        .accessibilityLabel(tr("a11y.more"))
                }
            } else if let menu {
                Menu { menu } label: {
                    HStack(spacing: 0) {
                        content
                        chevron.frame(width: 30, height: 34)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
            } else {
                content.opacity(enabled ? 1 : 0.55)
            }
        }
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(hovering && enabled ? DropdownStyle.hover : .clear))
        .onHover { hovering = $0 }
        .help(disabledReason ?? help ?? "")
    }

    private var content: some View {
        HStack(spacing: 10) {
            icon.frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let trailing { trailing.foregroundStyle(NookTheme.textTertiary) }
        }
        .padding(.leading, 10)
        .padding(.trailing, NookTheme.Spacing.md)
        .frame(minHeight: 34)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(NookTheme.font(10, .semibold))
            .foregroundStyle(NookTheme.textSecondary)
    }
}
