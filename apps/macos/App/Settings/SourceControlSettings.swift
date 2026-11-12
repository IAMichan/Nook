import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Worktrees: how new worktrees and clones are made, for every project.
struct SourceControlGlobalRows: View {
    @ObservedObject private var ws = WorkspaceSettings.shared

    var body: some View {
        SettingToggle(tr("sc.fastWorktrees"), detail: tr("sc.fastWorktrees.detail"), isOn: $ws.fastWorktrees)
        Picker(tr("sc.submodules"), selection: $ws.worktreeSubmodules) {
            ForEach(SubmoduleMode.allCases) { Text(tr("sc.submodules." + $0.rawValue)).tag($0) }
        }
        .help(tr("sc.submodules.help"))
        SettingToggle(tr("sc.autoPull.global"), detail: tr("sc.autoPull.help"), isOn: $ws.autoPullDefaultBranch)
        SettingToggle(tr("sc.cloneLayout"), detail: tr("sc.cloneLayout.detail"), isOn: $ws.cloneHostLayout)
    }
}

/// Settings › Projects, below a project's defaults: which agents it offers, its icon, publishing it, and archiving it.
struct ProjectSourceControlRows: View {
    let path: String
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var ws = WorkspaceSettings.shared
    @State private var publishPlan: PublishPlan?
    @State private var publishing: PublishPlan?
    @State private var emoji = ""

    var body: some View {
        agents
        icon
        if let plan = publishPlan {
            LabeledContent {
                Button(tr("sc.publish.button")) { publishing = plan }.controlSize(.small)
            } label: {
                SettingText("sc.publish.row")
            }
            .help(tr("sc.publish.help"))
        }
        Toggle(tr("sc.archive.toggle"), isOn: Binding(get: { ws.isArchivedProject(path) },
                                                      set: { ws.setArchived($0, project: path) }))
            .help(tr("sc.archive.help"))
        Color.clear.frame(height: 0)
            .task(id: path) { publishPlan = await app.workspace.publishPlan(folder: path) }
            .sheet(item: $publishing) { plan in
                PublishRepositorySheet(plan: plan) { page in
                    publishing = nil
                    if page != nil { publishPlan = nil }
                }
                .environmentObject(app.workspace)
            }
    }

    /// One switch per coding agent; an agent switched off is not offered for this project's sessions.
    private var agents: some View {
        let off = ws.agentsOff(for: path)
        let all = RunProvider.allCases
        return LabeledContent {
            Menu(off.isEmpty ? tr("sc.agents.all") : tr("sc.agents.count", all.count - off.count, all.count)) {
                ForEach(all) { provider in
                    Toggle(provider.displayName, isOn: Binding(get: { !off.contains(provider.rawValue) },
                                                               set: { ws.setAgent(provider, on: $0, for: path) }))
                }
            }
            .fixedSize()
        } label: {
            SettingText("sc.agents")
        }
        .help(tr("sc.agents.help"))
    }

    private var icon: some View {
        let current = ws.projectIcon(path)
        return LabeledContent {
            HStack(spacing: NookTheme.Spacing.md) {
                ProjectIconView(icon: current, size: 22)
                    .foregroundStyle(NookTheme.textSecondary)
                Menu(tr("sc.icon.change")) {
                    Button(tr("sc.icon.monogram")) {
                        let name = (path as NSString).lastPathComponent
                        ws.setProjectIcon(.monogram(ProjectIcon.initials(name), .mint), project: path)
                    }
                    Menu(tr("sc.icon.tint")) {
                        ForEach(ProjectIcon.Tint.allCases) { tint in
                            Button(tr("sc.icon.tint." + tint.rawValue)) {
                                let letters = monogramLetters(current)
                                ws.setProjectIcon(.monogram(letters, tint), project: path)
                            }
                        }
                    }
                    Button(tr("sc.icon.image")) { chooseImage() }
                    if current != nil {
                        Divider()
                        Button(tr("sc.icon.reset")) { ws.setProjectIcon(nil, project: path) }
                    }
                }
                .fixedSize()
                TextField("", text: $emoji, prompt: Text(tr("sc.icon.emojiPrompt")))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .accessibilityLabel(tr("sc.icon.emoji"))
                    .frame(width: 70)
                    .onSubmit {
                        if let clean = ProjectIcon.cleanEmoji(emoji) {
                            ws.setProjectIcon(.emoji(clean), project: path)
                        } else if let clean = ProjectIcon.cleanMonogram(emoji) {
                            ws.setProjectIcon(.monogram(clean, monogramTint(current)), project: path)
                        }
                        emoji = ""
                    }
            }
        } label: {
            SettingText("sc.icon")
        }
        .help(tr("sc.icon.help"))
    }

    private func monogramLetters(_ icon: ProjectIcon?) -> String {
        if case .monogram(let letters, _)? = icon { return letters }
        return ProjectIcon.initials((path as NSString).lastPathComponent)
    }

    private func monogramTint(_ icon: ProjectIcon?) -> ProjectIcon.Tint {
        if case .monogram(_, let tint)? = icon { return tint }
        return .mint
    }

    /// An image file, copied into Nook's own folder so the icon stays when the original moves.
    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.directoryURL = URL(fileURLWithPath: path)
        guard panel.runModal() == .OK, let url = panel.url, let stored = ProjectIconStore.store(url) else { return }
        ws.setProjectIcon(.image(stored), project: path)
    }
}

/// The archived projects, each with a button to bring it back to the pickers.
struct ArchivedProjectsSection: View {
    @Binding var scope: String
    @ObservedObject private var ws = WorkspaceSettings.shared

    var body: some View {
        let archived = ws.projectOverrides.projects.filter(ws.isArchivedProject)
        if !archived.isEmpty {
            Section {
                ForEach(archived, id: \.self) { path in
                    LabeledContent {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Button(tr("sc.archive.edit")) { scope = path }.controlSize(.small)
                            Button(tr("sc.archive.restore")) { ws.setArchived(false, project: path) }.controlSize(.small)
                        }
                    } label: {
                        Label {
                            Text((path as NSString).lastPathComponent)
                        } icon: {
                            ProjectIconView(icon: ws.projectIcon(path), size: 15)
                        }
                        .help(AgentPathFormat.tilde(path))
                    }
                }
            } header: {
                SettingsSectionTitle(tr("sc.archive.title"), info: tr("sc.archive.help"))
            }
        }
    }
}

/// Copies of the images projects use as icons, in Nook's support folder.
enum ProjectIconStore {
    static var directory: URL { NookPaths.supportDirectory.appendingPathComponent("project-icons", isDirectory: true) }

    /// The copy's path; nil when the file cannot be read or is larger than 4 MB.
    static func store(_ source: URL) -> String? {
        guard let data = try? Data(contentsOf: source), data.count < 4 * 1024 * 1024, NSImage(data: data) != nil else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString + "." + (source.pathExtension.isEmpty ? "png" : source.pathExtension))
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        return target.path
    }
}

/// Settings › Projects: the name a project shows in Nook's lists, saved when you press Return or leave the field.
struct ProjectNameRow: View {
    let path: String
    @ObservedObject private var ws = WorkspaceSettings.shared
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent {
            TextField("", text: $name, prompt: Text((path as NSString).lastPathComponent))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel(tr("settings.projects.name"))
                .frame(width: 220)
                .focused($focused)
                .onSubmit(save)
                .onChange(of: focused) { _, now in if !now { save() } }
        } label: {
            SettingText("settings.projects.name")
        }
        .help(tr("settings.projects.name.help"))
        .task(id: path) { name = ws.projectDisplayName(path) }
    }

    private func save() { ws.setProjectName(name, project: path) }
}

/// Picks (or makes) the folder of a new project.
@MainActor
enum ProjectFolderPanel {
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = tr("inbox.project.addPrompt")
        panel.message = tr("inbox.project.addMessage")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
