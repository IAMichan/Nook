import SwiftUI
import AppKit

/// The heading over the box, with the project it starts in: its picker, a clone and a session on another machine.
extension NewSessionComposer {
    // MARK: Heading

    /// One line while it fits; in a narrow column the folder moves to a line of its own under the question, instead of
    /// the question being squeezed to a word per line beside a long folder name. Under it, a quiet way out of the project ("or start without a project"); once without one, the question drops
    /// the folder and the line under it ("No project") opens the projects to pick one again.
    var heading: some View {
        VStack(spacing: NookTheme.Spacing.sm) {
            Group {
                if startsWithoutProject {
                    Text(tr("compose.headingNoProject")).foregroundStyle(NookTheme.paper)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            headingLead
                            projectPicker
                        }
                        VStack(spacing: NookTheme.Spacing.xxs) {
                            headingLead
                            projectPicker
                        }
                    }
                }
            }
            .font(NookTheme.TextStyle.display)
            subheading
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, NookTheme.Spacing.lg)
        // On the heading, not the picker: "New project…" is also in the "No project" line's menu.
        .sheet(item: $newProjectPlan) { plan in
            PublishRepositorySheet(plan: plan) { _ in newProjectPlan = nil }
                .environmentObject(workspace)
        }
    }

    /// The session works in a folder of its own under ~/.nook/scratch, not in a project.
    private var startsWithoutProject: Bool {
        remoteMachine == nil && ScratchProjects.isScratch(config.projectPath)
    }

    /// "or start without a project" under a project; "No project", with the projects to go back to, without one.
    @ViewBuilder
    private var subheading: some View {
        if startsWithoutProject {
            ComposerDropdown(width: 320) {
                HoverUnderlinedLabel(title: tr("ws.new.noProject"), color: NookTheme.paper)
            } content: {
                projectMenuContent
            }
            .composerTip(tr("compose.noProject.help"))
        } else if remoteMachine == nil {
            Button(action: chooseNoProject) {
                HoverUnderlinedLabel(title: tr("compose.startWithoutProject"), color: NookTheme.textSecondary)
            }
            .buttonStyle(.nookPlain)
            .composerTip(tr("ws.new.noProjectDetail"))
        }
    }

    private var headingLead: some View {
        Text(tr("compose.heading"))
            .foregroundStyle(NookTheme.paper)
    }

    /// The folder (or machine) the session works in, then the question mark, kept together on one line.
    private var projectPicker: some View {
        HStack(spacing: 0) {
            ComposerDropdown(width: 320) {
                Text(projectLabel)
                    .foregroundStyle(NookTheme.paper)
                    .underline(true, pattern: .dot, color: NookTheme.textTertiary)
            } content: {
                projectMenuContent
            }
            .composerTip(project.map { AgentPathFormat.tilde($0.path) } ?? tr("ws.new.pickWorkspace"))
            Text("?").foregroundStyle(NookTheme.paper)
            if inspecting {
                ProgressView().controlSize(.small).padding(.leading, NookTheme.Spacing.md)
            }
        }
    }

    /// The projects to pick from, shared by the folder in the question and the "No project" line under it.
    @ViewBuilder
    private var projectMenuContent: some View {
        let menu = projectMenu
        if !menu.favorites.isEmpty {
            DropdownHeader(title: tr("ws.new.favorites"))
            ForEach(menu.favorites, id: \.self) { path in
                projectRow(path)
            }
        }
        if !menu.recent.isEmpty {
            DropdownHeader(title: tr("ws.new.recent"))
            ForEach(menu.recent, id: \.self) { path in
                projectRow(path)
            }
        }
        if !menu.favorites.isEmpty || !menu.recent.isEmpty {
            DropdownDivider()
        }
        DropdownRow(symbol: "folder.badge.plus", title: tr("ws.new.chooseFolder")) { chooseFolder() }
        // A folder of its own under ~/.nook/scratch, for a question or a try-out that belongs to no project.
        DropdownRow(symbol: "tray", title: tr("ws.new.noProject"), detail: tr("ws.new.noProjectDetail"),
                    chosen: remoteMachine == nil && ScratchProjects.isScratch(config.projectPath)) { chooseNoProject() }
        DropdownRow(symbol: "arrow.down.circle", title: tr("ws.new.clone")) { showClone = true }
        // A new folder with a repository in it, offered to publish on GitHub at once.
        DropdownRow(symbol: "plus.rectangle.on.folder", title: tr("sc.newProject"), detail: tr("sc.newProject.detail")) {
            chooseNewProject()
        }
        // Another machine over SSH (Settings › Agents › Workspace › Machines).
        let machines = RemoteMachines.load()
        if !machines.isEmpty {
            DropdownDivider()
            DropdownHeader(title: tr("ws.remote.header"))
            ForEach(machines) { machine in
                DropdownRow(symbol: "server.rack", title: machine.name, detail: machine.host,
                            chosen: remoteMachine?.id == machine.id) { pickMachine(machine) }
            }
        }
    }

    private func projectRow(_ path: String) -> some View {
        let chosen = project.map { WorkspacePathPolicy.normalize($0.path) == path } ?? false
        return DropdownRow(symbol: "folder", projectIcon: settings.projectIcon(path), title: (path as NSString).lastPathComponent,
                           detail: AgentPathFormat.tilde(path), chosen: chosen, favorite: favoriteBinding(path)) { pick(path) }
    }

    private func favoriteBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { settings.isFavoriteProject(path) },
                set: { if $0 != settings.isFavoriteProject(path) { settings.toggleFavoriteProject(path) } })
    }

    var cloneRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            TextField(tr("ws.new.clonePlaceholder"), text: $cloneURL)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.code)
                .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .frame(height: 30)
                .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
                .onSubmit(clone)
                // A page copied from the browser (`…/tree/main`) shows as the repository it clones.
                .onChange(of: cloneURL) { _, typed in
                    let repository = CloneLayout.repositoryURL(fromPage: typed)
                    if repository != typed.trimmingCharacters(in: .whitespacesAndNewlines) { cloneURL = repository }
                }
            SmallGhostButton(title: tr("ws.new.cloneAction"), action: clone)
                .disabled(!GitService.isCloneURL(cloneURL))
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { showClone = false }
        }
        .frame(maxWidth: 640)
    }

    /// "app", "buildbox:app", or the invitation to pick one.
    private var projectLabel: String {
        if let remoteMachine {
            let folder = remoteFolder.isEmpty ? "…" : (remoteFolder as NSString).lastPathComponent
            return remoteMachine.name + ":" + folder
        }
        if let project, ScratchProjects.isScratch(project.path) { return tr("ws.new.noProject") }
        return project?.name ?? tr("compose.pickProject")
    }

    /// The folder on the remote machine, typed: there is no folder panel for another machine.
    var remoteRow: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "server.rack").foregroundStyle(NookTheme.textTertiary)
            // A long machine name gives way, so the field keeps room to type a path.
            Text(tr("ws.remote.folder", remoteMachine?.name ?? "")).foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1).truncationMode(.middle)
            TextField("~/code/app", text: $remoteFolder)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.code)
                .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .frame(minWidth: 140)
                .frame(height: 30)
                .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { remoteMachine = nil }
        }
        .font(NookTheme.TextStyle.body)
        .frame(maxWidth: 640)
    }
}
