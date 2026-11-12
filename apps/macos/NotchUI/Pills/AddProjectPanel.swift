import SwiftUI

/// "Add project" in the Agents list: the button opens a panel with four sources. A new project makes a folder
/// with an empty repository from a name; a local folder is picked on disk; a Git URL or a GitHub "owner/repo" is cloned in
/// the background by `CloneCenter` (its notice shows how far it is). What it adds becomes a pinned project, and the
/// new-session composer opens on it (`added`); a clone reports its id so the list can do that once it is done (`cloning`).
struct AddProjectButton: View {
    @EnvironmentObject private var app: AppModel
    let added: (String) -> Void
    let cloning: (UUID) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { PanelHeaderIcon(symbol: "folder.badge.plus", active: open) }
            .buttonStyle(.nookPlain)
            .help(tr("inbox.project.add"))
            .accessibilityLabel(tr("inbox.project.add"))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                AddProjectPanel(workspace: app.workspace, added: { path in open = false; added(path) },
                                cloning: { id in open = false; cloning(id) })
                    .padding(4)
                    .frame(width: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(DropdownStyle.panel)
                    .environment(\.closeDropdown, { open = false })
            }
    }
}

/// The panel's content: the sources, or the one field a source asks for.
private struct AddProjectPanel: View {
    let workspace: WorkspaceManager
    let added: (String) -> Void
    let cloning: (UUID) -> Void

    enum Step: Equatable { case sources, name, gitURL, github }
    @State private var step = Step.sources
    @State private var text = ""
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    /// Where a new project or a clone goes: beside the project you used last (or ~/Developer), as the composer's.
    private var parent: String {
        let settings = workspace.settings
        let last = settings.lastProject.isEmpty ? nil : settings.lastProject
        return WorkspaceManager.cloneParent(project: last, hostLayout: settings.cloneHostLayout && step != .name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch step {
            case .sources: sources
            case .name: field(title: tr("inbox.project.source.new"), prompt: tr("inbox.project.namePrompt"),
                              detail: name.isEmpty ? nil : AgentPathFormat.tilde(newPath), action: tr("sc.newProject.create"),
                              valid: !name.isEmpty, run: create)
            case .gitURL: field(title: tr("inbox.project.source.url"), prompt: tr("ws.new.clonePlaceholder"), detail: nil,
                                action: tr("ws.new.cloneAction"), valid: GitService.isCloneURL(cloneURL), run: clone)
            case .github: field(title: tr("inbox.project.source.github"), prompt: tr("inbox.project.githubPrompt"), detail: nil,
                                action: tr("ws.new.cloneAction"), valid: GitService.isCloneURL(cloneURL), run: clone)
            }
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 0) {
            DropdownHeader(title: tr("inbox.project.sources"))
            DropdownRow(symbol: "plus.rectangle.on.folder", title: tr("inbox.project.source.new"),
                        detail: tr("inbox.project.source.newDetail"), staysOpen: true) { go(.name) }
            DropdownRow(symbol: "folder.badge.plus", title: tr("inbox.project.source.folder"),
                        detail: tr("inbox.project.source.folderDetail")) { chooseFolder() }
            DropdownRow(symbol: "link", title: tr("inbox.project.source.url"),
                        detail: tr("inbox.project.source.urlDetail"), staysOpen: true) { go(.gitURL) }
            DropdownRow(symbol: "chevron.left.forwardslash.chevron.right", site: "github.com",
                        title: tr("inbox.project.source.github"), detail: tr("inbox.project.source.githubDetail"),
                        staysOpen: true) { go(.github) }
        }
    }

    private func field(title: String, prompt: String, detail: String?, action: String, valid: Bool,
                       run: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.xs) {
                ToolbarIconButton("chevron.left", tr("inbox.project.back")) { go(.sources) }
                Text(title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.textStrong)
                Spacer(minLength: 0)
            }
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.vertical, NookTheme.Spacing.sm)
                .roundedBackground(NookTheme.graphite, radius: NookTheme.Radius.chip)
                .focused($focused)
                .onSubmit { if valid && !busy { run() } }
                .onExitCommand { go(.sources) }
            if let detail {
                Text(detail)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let error {
                Text(error)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                SmallGhostButton(title: action, action: run)
                    .disabled(!valid || busy)
            }
        }
        .padding(NookTheme.Spacing.md)
        .onAppear { focused = true }
    }

    private func go(_ next: Step) {
        error = nil
        text = ""
        step = next
    }

    // MARK: Sources

    /// The typed name as a folder name: what a folder may not hold is left out.
    private var name: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private var newPath: String { URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(name).path }

    /// What the field holds as an address to clone: a GitHub "owner/repo" becomes its HTTPS address.
    private var cloneURL: String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard step == .github else { return CloneLayout.repositoryURL(fromPage: typed) }
        return AddProjectSource.githubURL(typed) ?? ""
    }

    private func create() {
        busy = true
        error = nil
        let path = newPath
        Task {
            do {
                let plan = try await workspace.createProject(at: path)
                busy = false
                added(plan.folder)
            } catch let failure {
                busy = false
                error = failure.localizedDescription
            }
        }
    }

    private func chooseFolder() {
        guard let path = ProjectFolderPanel.choose() else { return }
        added(path)
    }

    private func clone() {
        let url = cloneURL
        guard GitService.isCloneURL(url) else { return }
        if let id = CloneCenter.shared.start(url: url, parent: parent, workspace: workspace) { cloning(id) }
        go(.sources)
    }
}
