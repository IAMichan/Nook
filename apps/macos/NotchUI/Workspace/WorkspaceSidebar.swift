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

/// Left sidebar: a search field with a filter menu and a new-session button on top, then one compact line per session,
/// grouped under collapsible projects (or dates), then the sessions Nook does not run.
struct WorkspaceSidebar: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @Binding var pane: WorkspacePane
    @Binding var showNewSession: Bool
    @State private var search = ""
    @AppStorage("ws.sidebar.filter") private var filter: SessionFilter = .all
    @AppStorage("ws.sidebar.grouping") private var grouping: SessionGrouping = .project
    @AppStorage("ws.sidebar.project") private var projectFilter = ""
    /// The ids of the groups folded shut, one per line.
    @AppStorage("ws.sidebar.collapsed") private var collapsedGroups = ""
    @State private var renaming: UUID?
    @State private var renameText = ""
    @State private var confirmDelete: WorkspaceRun?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if showsActiveSeparately {
                        let active = workspace.activeRuns.filter(matchesSearch)
                        if !active.isEmpty {
                            SidebarGroupHeader(title: tr("ws.sidebar.activeNow"), count: active.count,
                                               collapsed: isCollapsed("active"), toggle: { toggleGroup("active") })
                            if !isCollapsed("active") {
                                ForEach(active) { run in row(run) }
                            }
                        }
                    }
                    ForEach(groups, id: \.id) { group in
                        SidebarGroupHeader(title: group.title, symbol: grouping == .project ? "folder" : nil,
                                           count: group.runs.count, collapsed: isCollapsed(group.id),
                                           toggle: { toggleGroup(group.id) })
                            .help(grouping == .project ? AgentPathFormat.tilde(group.id) : "")
                        if !isCollapsed(group.id) {
                            ForEach(group.runs) { run in row(run) }
                        }
                    }
                    if filter != .archived { externalSections }
                    if groups.isEmpty && (!showsActiveSeparately || workspace.activeRuns.filter(matchesSearch).isEmpty) {
                        Text(search.isEmpty ? tr("ws.sidebar.emptyFilter") : tr("ws.sidebar.noMatches"))
                            .font(NookTheme.font(12))
                            .foregroundStyle(WS.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            // ↑ and ↓ walk through the sessions shown, as in a list.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand(perform: move)
            footer
        }
        .background(WS.sidebar)
        .confirmationDialog(tr("ws.delete.title"), isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            presenting: confirmDelete) { run in
            Button(tr("ws.delete.confirm"), role: .destructive) { workspace.delete(run.id) }
            Button(tr("button.cancel"), role: .cancel) {}
        } message: { run in
            Text(run.worktreePath != nil && workspace.worktreeExists(run) ? tr("ws.delete.messageWorktree") : tr("ws.delete.message"))
        }
    }

    private var showsActiveSeparately: Bool { filter != .running && filter != .archived }

    private func select(_ id: UUID) {
        workspace.selectedRunID = id
        app.selectedExternalSession = nil
        pane = .sessions
    }

    /// The sessions in the order they are shown, leaving out folded groups.
    private var visibleRunIDs: [UUID] {
        var ids: [UUID] = []
        if showsActiveSeparately && !isCollapsed("active") { ids += workspace.activeRuns.filter(matchesSearch).map(\.id) }
        for group in groups where !isCollapsed(group.id) { ids += group.runs.map(\.id) }
        return ids
    }

    private func move(_ direction: MoveCommandDirection) {
        let ids = visibleRunIDs
        guard !ids.isEmpty else { return }
        let current = workspace.selectedRunID.flatMap { ids.firstIndex(of: $0) }
        switch direction {
        case .up: select(ids[max(0, (current ?? ids.count) - 1)])
        case .down: select(ids[min(ids.count - 1, (current ?? -1) + 1)])
        default: break
        }
    }

    // MARK: Collapsing

    private var collapsed: Set<String> { Set(collapsedGroups.split(separator: "\n").map(String.init)) }

    private func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    private func toggleGroup(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(.easeOut(duration: 0.15)) { collapsedGroups = set.sorted().joined(separator: "\n") }
    }

    // MARK: Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WS.tertiary)
                    TextField("", text: $search, prompt: Text(tr("ws.sidebar.search")).foregroundStyle(WS.tertiary))
                        .textFieldStyle(.plain)
                        .font(NookTheme.font(13))
                        .foregroundStyle(WS.text)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(WS.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(tr("ws.sidebar.clearSearch"))
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(WS.hover))
                filterMenu
                SidebarIconButton(symbol: "square.and.pencil", help: tr("ws.newSession.help")) { showNewSession = true }
                    .accessibilityLabel(tr("ws.newSession"))
            }
            if filter != .all || !projectFilter.isEmpty {
                activeFilters
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Filter, project and grouping in one menu: the list itself stays calm.
    private var filterMenu: some View {
        Menu {
            Picker(tr("ws.filter.label"), selection: $filter) {
                ForEach(SessionFilter.allCases) { item in
                    Text(filterTitle(item)).tag(item)
                }
            }
            .pickerStyle(.inline)
            Picker(tr("ws.group.label"), selection: $grouping) {
                ForEach(SessionGrouping.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Section(tr("ws.sidebar.projectHelp")) {
                Button(tr("ws.sidebar.allProjects")) { projectFilter = "" }
                ForEach(projects, id: \.self) { path in
                    Button(URL(fileURLWithPath: path).lastPathComponent) { projectFilter = path }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(filter != .all || !projectFilter.isEmpty ? WS.text : WS.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("ws.sidebar.filterHelp"))
    }

    /// What the list is narrowed to, each removable with one click.
    private var activeFilters: some View {
        HStack(spacing: 4) {
            if filter != .all {
                FilterPill(title: filter.title) { filter = .all }
            }
            if !projectFilter.isEmpty {
                FilterPill(title: URL(fileURLWithPath: projectFilter).lastPathComponent, symbol: "folder") { projectFilter = "" }
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            SidebarIconButton(symbol: "gearshape", help: tr("menu.settings")) { app.openSettings() }
            Spacer(minLength: 0)
            let attention = workspace.attentionCount
            if attention > 0 {
                Button {
                    filter = .attention
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
                        Text(tr("ws.filter.attention") + " \(attention)")
                    }
                    .font(NookTheme.font(11.5, .medium))
                    .foregroundStyle(WS.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().fill(WS.hover))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .overlay(alignment: .top) { Rectangle().fill(WS.border).frame(height: 1) }
    }

    // MARK: Sessions Nook does not run

    /// Agent sessions started in a terminal or app (seen through hooks and the process list) and earlier ones from
    /// transcripts: the same list as in the notch, so every conversation can be found here too.
    @ViewBuilder
    private var externalSections: some View {
        let records = app.externalSessionRecords().filter(matchesExternalSearch)
        ForEach([AgentSessionRecord.Section.needsYou, .active, .earlier], id: \.rawValue) { section in
            let rows = records.filter { $0.section == section }
            let id = "external.\(section.rawValue)"
            if !rows.isEmpty {
                SidebarGroupHeader(title: externalTitle(section), count: rows.count,
                                   collapsed: isCollapsed(id), toggle: { toggleGroup(id) })
                if !isCollapsed(id) {
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
        let title = record.title.isEmpty ? URL(fileURLWithPath: record.cwd).lastPathComponent : record.title
        let color: Color = record.phase == .needsYou ? NookTheme.amber
            : (record.phase == .working ? NookTheme.iris : (record.phase == .failed ? NookTheme.coral : WS.tertiary))
        return SidebarRowShell(selected: app.selectedExternalSession == record.id) {
            workspace.selectedRunID = nil
            app.selectedExternalSession = record.id
            pane = .sessions
        } content: {
            StatusDot(color: color, pulsing: record.phase == .working)
            AgentLogo(agent: record.agent, size: 12)
                .opacity(0.75)
            Text(title)
                .font(NookTheme.font(13))
                .foregroundStyle(WS.text.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(NookDates.ago(record.updated))
                .font(NookTheme.font(11))
                .foregroundStyle(WS.tertiary)
                .monospacedDigit()
        }
        .help([record.agent, AgentPathFormat.tilde(record.cwd)].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    // MARK: Filtering and grouping

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
        /// The project's path, or the date bucket's name.
        var id: String
        var title: String
        var runs: [WorkspaceRun]
    }

    /// Filtered sessions grouped by section, excluding active sessions (pinned to top).
    private var groups: [SessionGroup] {
        let list = workspace.runs
            .filter { filter.matches($0) && matchesSearch($0) && !(showsActiveSeparately && $0.status.isActive) }
            .sorted { $0.updatedAt > $1.updatedAt }
        switch grouping {
        case .project:
            let grouped = Dictionary(grouping: list, by: \.projectPath)
            return grouped.keys
                .sorted { (grouped[$0]?.first?.updatedAt ?? .distantPast) > (grouped[$1]?.first?.updatedAt ?? .distantPast) }
                .map { SessionGroup(id: $0, title: URL(fileURLWithPath: $0).lastPathComponent, runs: grouped[$0] ?? []) }
        case .recency:
            let calendar = Calendar.current
            var buckets: [(String, String, [WorkspaceRun])] = [("today", tr("ws.group.today"), []), ("yesterday", tr("ws.group.yesterday"), []),
                                                               ("week", tr("ws.group.week"), []), ("older", tr("ws.group.older"), [])]
            let weekAgo = Date().addingTimeInterval(-7 * 86_400)
            for run in list {
                if calendar.isDateInToday(run.updatedAt) { buckets[0].2.append(run) }
                else if calendar.isDateInYesterday(run.updatedAt) { buckets[1].2.append(run) }
                else if run.updatedAt > weekAgo { buckets[2].2.append(run) }
                else { buckets[3].2.append(run) }
            }
            return buckets.filter { !$0.2.isEmpty }.map { SessionGroup(id: "date." + $0.0, title: $0.1, runs: $0.2) }
        }
    }

    @ViewBuilder
    private func row(_ run: WorkspaceRun) -> some View {
        SessionRow(run: run,
                   account: app.profile(for: run).map { AccountLabel.name($0, app: app) },
                   multipleAccounts: app.profiles.profiles(for: run.provider.kind).count > 1,
                   pendingApprovals: workspace.approvals[run.id]?.count ?? 0,
                   selected: workspace.selectedRunID == run.id,
                   renaming: renaming == run.id,
                   renameText: $renameText,
                   onSelect: { select(run.id) },
                   onRename: {
                       workspace.rename(run.id, to: renameText)
                       renaming = nil
                   })
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

/// A foldable group in the sidebar: chevron, optional symbol, name, and how many sessions it holds.
struct SidebarGroupHeader: View {
    let title: String
    var symbol: String?
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(WS.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 12)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(WS.tertiary)
                }
                Text(title)
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(WS.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(NookTheme.font(11))
                    .foregroundStyle(WS.tertiary)
                    .monospacedDigit()
                    .opacity(hovering || collapsed ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? WS.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(title), \(count)")
    }
}

/// The surface of one sidebar line: rounded, lit on hover, a little brighter when selected.
struct SidebarRowShell<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content() }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? WS.selected : (hovering ? WS.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small colored dot for a session's state; pulses while the agent works.
struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing && dim ? 0.35 : 1)
            .frame(width: 12)
            .onAppear { pulse(pulsing) }
            .onChange(of: pulsing) { _, on in pulse(on) }
    }

    private func pulse(_ on: Bool) {
        if on {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dim = false }
        }
    }
}

/// A plain icon button for the sidebar's header and footer.
struct SidebarIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? WS.text : WS.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? WS.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// An active filter under the search field; clicking it removes the filter.
private struct FilterPill: View {
    let title: String
    var symbol: String?
    let clear: () -> Void

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9.5)) }
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(WS.tertiary)
            }
            .font(NookTheme.font(11.5, .medium))
            .foregroundStyle(WS.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(WS.hover))
            .overlay(Capsule().stroke(WS.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(tr("ws.sidebar.clearFilter"))
    }
}

/// Single session line: state, title, and the last activity, or what waits for you. The details are in the tooltip.
struct SessionRow: View {
    let run: WorkspaceRun
    let account: String?
    let multipleAccounts: Bool
    let pendingApprovals: Int
    let selected: Bool
    let renaming: Bool
    @Binding var renameText: String
    let onSelect: () -> Void
    let onRename: () -> Void

    var body: some View {
        if renaming {
            // Not inside the row's button: that would take the clicks meant for the field.
            HStack(spacing: 8) {
                StatusDot(color: dotColor)
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .font(NookTheme.font(12.5))
                    .onSubmit(onRename)
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(WS.selected))
        } else {
            SidebarRowShell(selected: selected, action: onSelect) {
                StatusDot(color: dotColor, pulsing: run.status == .running || run.status == .preparing)
                Text(run.title)
                    .font(NookTheme.font(13, selected ? .medium : .regular))
                    .foregroundStyle(run.archived ? WS.secondary : (selected ? WS.text : WS.text.opacity(0.88)))
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailing
            }
            .help(details)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(run.title), \(run.status.label), \(run.projectName)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if pendingApprovals > 0 {
            Text("\(pendingApprovals)")
                .font(NookTheme.font(10, .bold))
                .foregroundStyle(NookTheme.ink)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(NookTheme.amber))
                .help(tr("ws.sidebar.pendingHelp"))
        } else {
            HStack(spacing: 5) {
                if run.hasUnreviewedChanges && !run.status.isActive {
                    Circle().fill(NookTheme.iris).frame(width: 5, height: 5)
                        .help(tr("ws.sidebar.unreviewedHelp"))
                }
                Text(NookDates.ago(run.updatedAt))
                    .font(NookTheme.font(11))
                    .foregroundStyle(WS.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// Calm by default: only what asks for attention gets a color.
    private var dotColor: Color {
        switch run.status {
        case .completed: return run.hasUnreviewedChanges ? NookTheme.mint : WS.tertiary.opacity(0.6)
        case .stopped: return WS.tertiary.opacity(0.6)
        default: return run.status.color
        }
    }

    /// "Running · nook › main · Claude Code · Work · opus-4".
    private var details: String {
        var parts = [run.status.label, run.projectName + (run.branch.map { " › " + $0 } ?? ""), run.provider.kind.shortName]
        if multipleAccounts, let account { parts.append(account) }
        let model = run.resolvedModel ?? (run.model.isEmpty ? nil : run.model)
        if let model { parts.append(model.replacingOccurrences(of: "claude-", with: "")) }
        return parts.joined(separator: " · ")
    }
}
