import SwiftUI

/// Filter options at the top of the sidebar list.
enum SessionFilter: String, CaseIterable, Identifiable {
    case all, running, attention, completed, archived
    var id: String { rawValue }
    var title: String { tr("ws.filter." + rawValue) }

    func matches(_ run: WorkspaceRun) -> Bool {
        switch self {
        case .all: return !run.archived
        case .running: return !run.archived && run.status.isActive
        case .attention: return !run.archived && (run.status == .waitingApproval || run.status == .failed || run.hasUnreviewedChanges)
        case .completed: return !run.archived && (run.status == .completed || run.status == .stopped)
        case .archived: return run.archived
        }
    }
}

enum SessionGrouping: String, CaseIterable, Identifiable {
    case project, recency
    var id: String { rawValue }
    var title: String { tr("ws.group." + rawValue) }
}

/// Left sidebar: search, filtering, and session list grouped by project or date.
struct WorkspaceSidebar: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @Binding var pane: WorkspacePane
    @Binding var showNewSession: Bool
    @State private var search = ""
    @AppStorage("ws.sidebar.filter") private var filter: SessionFilter = .all
    @AppStorage("ws.sidebar.grouping") private var grouping: SessionGrouping = .project
    @AppStorage("ws.sidebar.project") private var projectFilter = ""
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmDelete: WorkspaceRun?

    var body: some View {
        VStack(spacing: 0) {
            controls
            TextField(tr("ws.sidebar.search"), text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            List(selection: selectionBinding) {
                if !workspace.activeRuns.isEmpty && filter != .running && filter != .archived {
                    Section {
                        ForEach(workspace.activeRuns.filter(matchesSearch)) { run in
                            row(run)
                        }
                    } header: {
                        Text(tr("ws.sidebar.activeNow"))
                    }
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.runs) { run in
                            row(run)
                        }
                    }
                }
                if filter != .archived { externalSections }
                if groups.isEmpty && (workspace.activeRuns.isEmpty || filter == .archived) {
                    Text(search.isEmpty ? tr("ws.sidebar.emptyFilter") : tr("ws.sidebar.noMatches"))
                        .font(NookTheme.font(12))
                        .foregroundStyle(WS.tertiary)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
        }
        .confirmationDialog(tr("ws.delete.title"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { run in
            Button(tr("ws.delete.confirm"), role: .destructive) { workspace.delete(run.id) }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: { run in
            Text(run.worktreePath != nil && workspace.worktreeExists(run) ? tr("ws.delete.messageWorktree") : tr("ws.delete.message"))
        }
    }

    private var selectionBinding: Binding<UUID?> {
        Binding(get: { workspace.selectedRunID }, set: { id in
            workspace.selectedRunID = id
            if id != nil {
                app.selectedExternalSession = nil
                pane = .sessions
            }
        })
    }

    // MARK: Sessions Nook does not run

    /// Agent sessions started in a terminal or app (seen through hooks and the process list) and earlier ones from
    /// transcripts: the same list as in the notch, so every conversation can be found here too.
    @ViewBuilder
    private var externalSections: some View {
        let records = app.externalSessionRecords().filter(matchesExternalSearch)
        ForEach([AgentSessionRecord.Section.needsYou, .active, .earlier], id: \.rawValue) { section in
            let rows = records.filter { $0.section == section }
            if !rows.isEmpty {
                Section(externalTitle(section)) {
                    ForEach(rows) { record in
                        externalRow(record)
                    }
                }
            }
        }
    }

    private func externalTitle(_ section: AgentSessionRecord.Section) -> String {
        switch section {
        case .needsYou: return tr("ws.sidebar.external.needsYou")
        case .active: return tr("ws.sidebar.external.active")
        case .inNook: return tr("ws.sidebar.activeNow")
        case .earlier: return tr("ws.sidebar.external.earlier")
        }
    }

    private func matchesExternalSearch(_ record: AgentSessionRecord) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [record.title, record.cwd, record.agent].contains { $0.lowercased().contains(query) }
    }

    private func externalRow(_ record: AgentSessionRecord) -> some View {
        let selected = app.selectedExternalSession == record.id
        return Button {
            workspace.selectedRunID = nil
            app.selectedExternalSession = record.id
            pane = .sessions
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.title.isEmpty ? URL(fileURLWithPath: record.cwd).lastPathComponent : record.title)
                    .font(NookTheme.font(13, .medium))
                    .foregroundStyle(WS.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(record.phase == .needsYou ? NookTheme.amber : (record.phase == .working ? NookTheme.iris : WS.tertiary))
                        .frame(width: 5, height: 5)
                    Text(record.agent).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(NookDates.ago(record.updated)).foregroundStyle(WS.tertiary)
                }
                .font(NookTheme.font(11))
                .foregroundStyle(WS.secondary)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.25) : Color.clear)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showNewSession = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text(tr("ws.newSession")).font(NookTheme.font(13, .semibold))
                    Spacer()
                    Text("⌘N").font(NookTheme.font(11)).foregroundStyle(WS.tertiary)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(NookTheme.iris.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(NookTheme.iris.opacity(0.35), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("ws.newSession"))

            HStack(spacing: 6) {
                Menu {
                    Button(tr("ws.sidebar.allProjects")) { projectFilter = "" }
                    Divider()
                    ForEach(projects, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { projectFilter = path }
                    }
                } label: {
                    Label(projectFilter.isEmpty ? tr("ws.sidebar.allProjects") : URL(fileURLWithPath: projectFilter).lastPathComponent,
                          systemImage: "folder")
                        .font(NookTheme.font(12))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(tr("ws.sidebar.projectHelp"))
                Spacer()
                Menu {
                    Picker(tr("ws.group.label"), selection: $grouping) {
                        ForEach(SessionGrouping.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(tr("ws.group.label"))
            }

            Picker(tr("ws.filter.label"), selection: $filter) {
                ForEach(SessionFilter.allCases) { item in
                    Text(filterTitle(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func filterTitle(_ item: SessionFilter) -> String {
        let count = workspace.runs.filter { item.matches($0) }.count
        switch item {
        case .running, .attention: return count > 0 ? "\(item.title) \(count)" : item.title
        default: return item.title
        }
    }

    private var projects: [String] {
        Array(Set(workspace.runs.map(\.projectPath))).sorted { $0.lowercased() < $1.lowercased() }
    }

    private func matchesSearch(_ run: WorkspaceRun) -> Bool {
        if !projectFilter.isEmpty && run.projectPath != projectFilter { return false }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return [run.title, run.task, run.projectName, run.branch ?? "", run.provider.displayName, run.model]
            .contains { $0.lowercased().contains(query) }
    }

    private struct SessionGroup {
        var title: String
        var runs: [WorkspaceRun]
    }

    /// Filtered sessions grouped by section, excluding active sessions (pinned to top).
    private var groups: [SessionGroup] {
        let showActiveSeparately = filter != .running && filter != .archived
        let list = workspace.runs
            .filter { filter.matches($0) && matchesSearch($0) && !(showActiveSeparately && $0.status.isActive) }
            .sorted { $0.updatedAt > $1.updatedAt }
        switch grouping {
        case .project:
            let grouped = Dictionary(grouping: list, by: \.projectPath)
            return grouped.keys
                .sorted { (grouped[$0]?.first?.updatedAt ?? .distantPast) > (grouped[$1]?.first?.updatedAt ?? .distantPast) }
                .map { SessionGroup(title: URL(fileURLWithPath: $0).lastPathComponent, runs: grouped[$0] ?? []) }
        case .recency:
            let calendar = Calendar.current
            var buckets: [(String, [WorkspaceRun])] = [(tr("ws.group.today"), []), (tr("ws.group.yesterday"), []),
                                                       (tr("ws.group.week"), []), (tr("ws.group.older"), [])]
            let weekAgo = Date().addingTimeInterval(-7 * 86_400)
            for run in list {
                if calendar.isDateInToday(run.updatedAt) { buckets[0].1.append(run) }
                else if calendar.isDateInYesterday(run.updatedAt) { buckets[1].1.append(run) }
                else if run.updatedAt > weekAgo { buckets[2].1.append(run) }
                else { buckets[3].1.append(run) }
            }
            return buckets.filter { !$0.1.isEmpty }.map { SessionGroup(title: $0.0, runs: $0.1) }
        }
    }

    @ViewBuilder
    private func row(_ run: WorkspaceRun) -> some View {
        SessionRow(run: run,
                   account: app.profile(for: run).map { AccountLabel.name($0, app: app) },
                   multipleAccounts: app.profiles.profiles(for: run.provider.kind).count > 1,
                   pendingApprovals: workspace.approvals[run.id]?.count ?? 0,
                   renaming: renaming == run.id,
                   renameText: $renameText,
                   onRename: {
                       workspace.rename(run.id, to: renameText)
                       renaming = nil
                   })
            .tag(run.id)
            .contextMenu {
                Button(tr("ws.action.rename")) {
                    renameText = run.title
                    renaming = run.id
                }
                if run.canContinue && (run.status == .failed || run.status == .stopped) {
                    Button(tr("ws.action.retry")) { workspace.retry(run.id) }
                }
                if run.status.isActive {
                    Button(tr("ws.action.stop")) { workspace.stop(run.id) }
                }
                Divider()
                Button(tr("ws.action.openEditor")) { workspace.openInEditor(run.workingDirectory) }
                Button(tr("ws.action.openTerminal")) { workspace.openTerminal(run.workingDirectory) }
                Button(tr("ws.action.reveal")) { workspace.revealInFinder(run.workingDirectory) }
                Divider()
                if run.archived {
                    Button(tr("ws.action.unarchive")) { workspace.setArchived(run.id, false) }
                } else {
                    Button(tr("ws.action.archive")) { workspace.setArchived(run.id, true) }
                        .disabled(run.status.isActive)
                }
                Button(tr("ws.action.delete"), role: .destructive) { confirmDelete = run }
                    .disabled(run.status.isActive)
            }
    }
}

/// Single session list item: title, project, branch, agent, status, and last activity.
struct SessionRow: View {
    let run: WorkspaceRun
    let account: String?
    let multipleAccounts: Bool
    let pendingApprovals: Int
    let renaming: Bool
    @Binding var renameText: String
    let onRename: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusBadge(status: run.status, compact: true)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                if renaming {
                    TextField("", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(onRename)
                } else {
                    Text(run.title)
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(run.archived ? WS.secondary : WS.text)
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(run.projectName)
                    if let branch = run.branch {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 8.5))
                        Text(branch).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(NookTheme.font(11.5))
                .foregroundStyle(WS.tertiary)
                .lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(run.provider.color).frame(width: 5, height: 5)
                    Text(subtitle)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    if pendingApprovals > 0 {
                        Text("\(pendingApprovals)")
                            .font(NookTheme.font(10, .bold))
                            .foregroundStyle(NookTheme.ink)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(NookTheme.amber))
                            .help(tr("ws.sidebar.pendingHelp"))
                    } else if run.hasUnreviewedChanges && !run.status.isActive {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(NookTheme.iris)
                            .help(tr("ws.sidebar.unreviewedHelp"))
                    }
                    Text(NookDates.ago(run.updatedAt))
                        .foregroundStyle(WS.tertiary)
                }
                .font(NookTheme.font(11))
                .foregroundStyle(WS.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.title), \(run.status.label), \(run.projectName)")
    }

    private var subtitle: String {
        var parts = [run.provider.kind.shortName]
        if multipleAccounts, let account { parts.append(account) }
        let model = run.resolvedModel ?? (run.model.isEmpty ? nil : run.model)
        if let model { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
        return parts.joined(separator: " · ")
    }
}
