import Carbon
import SwiftUI

/// "Add project" in the Agents list: the button asks the Agents tab for `AddProjectPalette`, the same kind of palette the
/// new-session button opens.
struct AddProjectButton: View {
    @ObservedObject var viewModel: NotchViewModel

    var body: some View {
        Button { viewModel.requestAddProject() } label: { PanelHeaderIcon(symbol: "folder.badge.plus", active: viewModel.addsProject) }
            .buttonStyle(.nookPlain)
            .help(tr("inbox.project.add"))
            .accessibilityLabel(tr("inbox.project.add"))
    }
}

/// The palette "Add project" opens over the Agents tab, with four sources. A new project makes a folder with an empty
/// repository from a name; a local folder is picked on disk; a Git URL or a GitHub "owner/repo" is cloned in the background
/// by `CloneCenter` (its notice shows how far it is). The field on top filters the sources, and takes the name or the
/// address once a source asks for one. What it adds becomes a pinned project and the new-session composer opens on it
/// (`added`); a clone reports its id so the tab can do that once it is done (`cloning`).
struct AddProjectPalette: View {
    let workspace: WorkspaceManager
    let added: (String) -> Void
    let cloning: (UUID) -> Void
    let close: () -> Void

    enum Step: Equatable { case sources, name, gitURL, github }

    private struct Source: Identifiable {
        let id: String
        let symbol: String
        var site: String? = nil
        let title: String
        let detail: String
        let run: () -> Void
    }

    @State private var step = Step.sources
    @State private var text = ""
    @State private var index = 0
    @State private var error: String?
    @State private var busy = false
    @FocusState private var focused: Bool

    // MARK: View

    var body: some View {
        let list = sources
        VStack(alignment: .leading, spacing: 0) {
            NookSearchField(prompt: prompt, text: $text, style: .large, focus: $focused,
                            onSubmit: submit, onEscape: escape, symbol: fieldSymbol)
                .padding(.horizontal, NookTheme.Spacing.xs)
            NookDivider()
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                if step == .sources {
                    NookSectionLabel(tr("inbox.project.sources"), inset: NookTheme.Spacing.md)
                        .padding(.top, NookTheme.Spacing.xxs)
                        .padding(.bottom, NookTheme.Spacing.xxs)
                    if list.isEmpty { ListEmptyNote(tr("palette.none"), padding: NookTheme.Spacing.xl) }
                    ForEach(Array(list.enumerated()), id: \.element.id) { offset, source in
                        PaletteRow(symbol: source.symbol, site: source.site, title: source.title, detail: source.detail,
                                   selected: offset == index, steps: source.id != "folder")
                            .onHover { if $0 { index = offset } }
                            .nookClickable()
                            .onTapGesture { index = offset; submit() }
                    }
                } else {
                    fieldStep
                }
            }
            .padding(NookTheme.Spacing.sm)
        }
        .paletteCard()
        .focusOnAppear($focused)
        .onChange(of: text) { _, _ in
            index = 0
            error = nil
        }
        .onWindowKeyDown { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            guard modifiers.isEmpty else { return false }
            switch Int(event.keyCode) {
            case kVK_DownArrow where step == .sources: index = min(index + 1, max(0, list.count - 1))
            case kVK_UpArrow where step == .sources: index = max(index - 1, 0)
            case kVK_Escape: escape()
            default: return false
            }
            return true
        }
    }

    /// A source's one field: the row that runs it (what it makes or clones, and where), and what went wrong.
    @ViewBuilder
    private var fieldStep: some View {
        NookSectionLabel(stepTitle, inset: NookTheme.Spacing.md)
            .padding(.top, NookTheme.Spacing.xxs)
            .padding(.bottom, NookTheme.Spacing.xxs)
        PaletteRow(symbol: step == .name ? "plus.rectangle.on.folder" : "arrow.down.circle",
                   title: step == .name ? tr("sc.newProject.create") : tr("ws.new.cloneAction"),
                   detail: actionDetail, selected: valid && !busy, keyHint: valid && !busy ? "↩" : nil)
            .opacity(valid && !busy ? 1 : 0.5)
            .nookClickable()
            .onTapGesture(perform: submit)
        if let error {
            Text(error)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coral)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.vertical, NookTheme.Spacing.xs)
        }
    }

    private var prompt: String {
        switch step {
        case .sources: return tr("inbox.project.add")
        case .name: return tr("inbox.project.namePrompt")
        case .gitURL: return tr("ws.new.clonePlaceholder")
        case .github: return tr("inbox.project.githubPrompt")
        }
    }

    private var fieldSymbol: String {
        switch step {
        case .sources: return "magnifyingglass"
        case .name: return "plus.rectangle.on.folder"
        case .gitURL, .github: return "link"
        }
    }

    private var stepTitle: String {
        switch step {
        case .sources: return tr("inbox.project.sources")
        case .name: return tr("inbox.project.source.new")
        case .gitURL: return tr("inbox.project.source.url")
        case .github: return tr("inbox.project.source.github")
        }
    }

    /// Where the new project goes, or the address that is cloned; empty until the field holds something that works.
    private var actionDetail: String {
        guard valid else { return "" }
        return step == .name ? AgentPathFormat.tilde(newPath) : cloneURL
    }

    private var valid: Bool {
        switch step {
        case .sources: return false
        case .name: return !name.isEmpty
        case .gitURL, .github: return GitService.isCloneURL(cloneURL)
        }
    }

    // MARK: Sources

    private var sources: [Source] {
        let all = [
            Source(id: "new", symbol: "plus.rectangle.on.folder", title: tr("inbox.project.source.new"),
                   detail: tr("inbox.project.source.newDetail")) { go(.name) },
            Source(id: "folder", symbol: "folder.badge.plus", title: tr("inbox.project.source.folder"),
                   detail: tr("inbox.project.source.folderDetail")) { chooseFolder() },
            Source(id: "url", symbol: "link", title: tr("inbox.project.source.url"),
                   detail: tr("inbox.project.source.urlDetail")) { go(.gitURL) },
            Source(id: "github", symbol: "chevron.left.forwardslash.chevron.right", site: "github.com",
                   title: tr("inbox.project.source.github"), detail: tr("inbox.project.source.githubDetail")) { go(.github) },
        ]
        let parsed = PaletteQuery(text)
        guard step == .sources, !parsed.isEmpty else { return all }
        return all.filter { parsed.match(title: $0.title, detail: $0.detail) != nil }
    }

    private func submit() {
        switch step {
        case .sources:
            let list = sources
            guard list.indices.contains(index) else { return }
            list[index].run()
        case .name:
            if valid && !busy { create() }
        case .gitURL, .github:
            if valid { clone() }
        }
    }

    /// Escape: back to the sources from a field, else closes.
    private func escape() {
        if step == .sources { close() } else { go(.sources) }
    }

    private func go(_ next: Step) {
        error = nil
        text = ""
        index = 0
        step = next
        focused = true
    }

    /// Where a new project or a clone goes: beside the project you used last (or ~/Developer), as the composer's.
    private var parent: String {
        let settings = workspace.settings
        let last = settings.lastProject.isEmpty ? nil : settings.lastProject
        return WorkspaceManager.cloneParent(project: last, hostLayout: settings.cloneHostLayout && step != .name)
    }

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
        if let id = CloneCenter.shared.start(url: url, parent: parent, workspace: workspace) { cloning(id) } else { close() }
    }
}
