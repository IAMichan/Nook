import SwiftUI
import UniformTypeIdentifiers

/// The Agents list as an inbox: pinned sessions first, then what is active, a shelf for sessions that work and need
/// nothing, one for snoozed sessions and one for what you settled. Rows that need you stay loud, the rest recede; you pin,
/// settle and snooze from the row, and the last such action can be undone for five seconds (⌘Z).
/// The decisions are in `InboxLayout`, `UndoLog` and `AutoSettlePolicy`.
struct AgentInboxList: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = InboxStore.shared
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var visits = SessionVisits.shared
    @ObservedObject private var pullRequests = PullRequestSync.shared
    /// Publishes only while a Settle or Wake sweep runs, to light the rows it covers.
    @ObservedObject private var sweep = SessionSweep.rows
    /// The badges show the newest status of each request, also one a watch or the pull request page read.
    @ObservedObject private var pullRequestStatuses = PullRequestStatusStore.shared
    /// Sessions that are running or were, and earlier sessions (settled by nature).
    let items: [AgentListItem]
    let past: [AgentListItem]
    let current: String
    let now: Date
    /// In the sidebar: the list's own buttons, in one row with the search field.
    var headerActions: AnyView? = nil
    let select: (String) -> Void

    @Environment(\.inPanelSidebar) private var inSidebar
    @State private var settledLimit = InboxLayout.settledPage
    @State private var selection = ListSelection<String>()
    /// The rows as shown, kept for the click closures: the rows are not redrawn when only this order changes.
    @State private var shownOrder: [String] = []
    /// The row last clicked: opening it from the list does not scroll the list, opening one from elsewhere does.
    @State private var clickedID: String?
    /// The past sessions by id, made again only when the history changes (`pastSession`).
    @State private var pastIndex = PastSessionIndex()
    /// ⌘ held for a moment: the first nine rows show the ⌘-number that opens them.
    @StateObject private var commandHold = CommandHoldMonitor()
    /// The list has the keyboard (F6): ↑/↓ move `keyRow` without opening it, Return opens it, ←/→ fold and unfold.
    @FocusState private var listFocused: Bool
    @State private var keyRow: String?
    /// Waits for the pointer to rest on a row before reading its session (`prefetch`). Not observed: hovering redraws nothing.
    @State private var hoverPrefetch = InboxHoverPrefetch()
    /// The row being renamed from its menu, by its id.
    @State private var renaming: String?
    /// The session "Custom…" snoozes, while its sheet is open.
    @State private var customSnooze: AgentListItem?
    /// The row files are dragged over, lit while they are.
    @State private var dropTarget: String?
    /// The project folder being renamed from its menu, and the name being typed.
    @State private var renamingProject: String?
    @State private var projectName = ""
    /// The favorite (pinned) and archived projects shape the folders.
    @ObservedObject private var projectSettings = WorkspaceSettings.shared
    /// Clones started from "Add project": once one is done its folder becomes a project and the composer opens on it.
    @State private var pendingClones: Set<UUID> = []
    /// The height of each docked shelf's rows, so the shelf is as tall as they are (`dockedShelf`).
    @State private var shelfHeights: [InboxSection.Kind: CGFloat] = [:]
    private static let shelfMaxHeight: CGFloat = 280

    private static let wakeFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        return format
    }()

    // MARK: Rows

    private func attention(_ item: AgentListItem) -> AgentAttention {
        switch item.status {
        case .waiting: return .approval
        case .input: return .input
        case .failed: return .failed
        case .limited: return .limited
        case .working: return .working
        case .idle: return item.unseen ? .ready : .idle
        case .finished: return .finished
        }
    }

    private func row(_ item: AgentListItem) -> InboxRow {
        let isPast = item.id.hasPrefix("past:")
        // A busy session settles only when you settled it during this busy spell (a turn that hangs).
        let settledBusy = item.isBusy && finishedMarks.isMarkedWhileBusy(item.finishKey)
        // Only you settle a chat (or the auto-settle rules you switched on): one that went quiet stays until you handled it,
        // across a restart of Nook too.
        let settled = isPast || settledBusy || (!item.isBusy && finishedMarks.contains(item.finishKey))
        return InboxRow(
            id: item.id, title: item.title, project: InboxProject.key(folder: item.folder, path: item.path),
            attention: attention(item),
            pinned: store.state.pinned.contains(item.id), settled: settled,
            snoozedUntil: item.snoozedUntil, snoozedAt: item.snoozedAt, limitedAt: item.limitedAt,
            lastActivity: item.started ?? .distantPast,
            hasOpenRequest: item.status == .waiting || item.status == .input,
            isActive: item.isBusy || item.status == .working,
            unread: item.unseen,
            parentID: item.parentID,
            unsettledAt: finishedMarks.kept[item.finishKey]
        )
    }

    private func runID(_ item: AgentListItem?) -> UUID? {
        guard let item else { return nil }
        return runID(item)
    }

    private func runID(_ item: AgentListItem) -> UUID? {
        item.id.hasPrefix("run:") ? UUID(uuidString: String(item.id.dropFirst(4))) : nil
    }

    /// The pull requests of a row, for its badge and the card that badge opens on hover: the ones the branch sync found for
    /// the session's branch (a session Nook runs by id, any other by folder), and for a session Nook runs also the ones of
    /// the branches and worktrees it worked on before, so a pull request it opened stays in view after it moved on. Until
    /// the sync has found one, the pull request the chat itself shows: the same one as the tray above its composer.
    private func sessionPullRequests(_ item: AgentListItem) -> SessionPullRequests {
        if let id = runID(item) {
            let earlier = pullRequestStatuses.current(pullRequests.earlier[id] ?? [])
            if let links = pullRequests.links[id], !links.isEmpty {
                return SessionPullRequests(current: pullRequestStatuses.current(links), earlier: earlier)
            }
            // The watched one may be one of an earlier branch: it is listed there, not as this branch's.
            let known = knownPullRequest(run: id).flatMap(PullRequestLink.init(url:)).map { [$0] } ?? []
            return SessionPullRequests(current: pullRequestStatuses.current(known.filter { link in !earlier.contains { $0.id == link.id } }),
                                       earlier: earlier)
        }
        if let branch = item.branch,
           let links = pullRequests.folderLinks[PullRequestSync.folderKey(path: item.path, branch: branch)], !links.isEmpty {
            return SessionPullRequests(current: pullRequestStatuses.current(links))
        }
        let reply = item.id.hasPrefix("past:")
            ? pastSession(item.id)?.lastReply
            : app.hub.sessions.first { $0.id == item.id }?.lastReply
        let printed = reply.flatMap(MarkdownBlock.lastGitHubPullRequest(in:)).flatMap(PullRequestLink.init(url:)).map { [$0] } ?? []
        return SessionPullRequests(current: pullRequestStatuses.current(printed))
    }

    /// The past session of a row ("past:" and the session's id, "agent:session"), compared by its parts: making the id
    /// of every session in the history, for every row, on every redraw of the list was most of what drawing it cost.
    private func pastSession(_ rowID: String) -> PastSession? {
        let id = rowID.dropFirst(5)
        guard let colon = id.firstIndex(of: ":") else { return nil }
        return pastIndex.session(agent: id[..<colon], id: id[id.index(after: colon)...], in: app.history.sessions)
    }

    /// The watched pull request, the one Nook opened, else the last one the conversation links. Only a conversation
    /// already in memory is read: a row never loads one from disk.
    private func knownPullRequest(run id: UUID) -> URL? {
        let workspace = app.workspace
        if let watched = workspace.run(id)?.prWatch.flatMap({ URL(string: $0.url) }) { return watched }
        if let opened = workspace.openPullRequests[id] { return opened }
        guard let events = workspace.events[id], !events.isEmpty else { return nil }
        return RunPullRequestLinks.shared.url(id, events: events)
    }

    /// Folder and branch of every agent Nook did not start, for `PullRequestSync`: the ones running now and the earlier
    /// ones of the last three days (older ones keep the state they had).
    private var pullRequestFolders: [PullRequestSync.Folder] {
        let recent = past.filter { ($0.started ?? .distantPast) > now.addingTimeInterval(-3 * 24 * 3600) }
        return (items + recent).compactMap { item in
            guard runID(item) == nil, let branch = item.branch else { return nil }
            return PullRequestSync.Folder(path: item.path, branch: branch, busy: item.isBusy, quietSince: item.started)
        }
    }

    // MARK: Body

    var body: some View {
        let all = items + past
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = all.map(row)
        let visible = InboxSearch.filter(rows: rows, query: store.query)
        let sections = InboxLayout.sections(rows: visible, state: store.state, showWorking: store.showWorking, now: now,
                                            settledLimit: settledLimit, selectedID: current)
        let groups = store.groupByProject
            ? InboxLayout.projectGroups(sections, pinned: pinnedProjects, archived: archivedProjects) : []
        let projects = projectFolders
        // The rows as shown, top to bottom (a folded shelf only with the open session): what select all and a ⇧-click range go by.
        let shown = shownIDs(sections, groups: groups)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                searchField
                SelectionModeButton(active: selection.isActive) {
                    withAnimation(NookTheme.reveal) {
                        if selection.isActive { selection.clear() } else { selection.begin() }
                    }
                }
                // As in t3code: a project is added from the list itself: made new, a folder on disk, or cloned.
                if !app.demoMode {
                    AddProjectButton(added: addProject, cloning: { pendingClones.insert($0) })
                }
                headerActions
            }
            // The list and its docked shelves, with the undo notice floating over their foot: it covers the last rows for
            // a few seconds instead of pushing the whole list up and back down.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                // What you typed for a new session and did not start yet, one per project (`UnsentDraftRows`), drawn as
                // session rows at the top of the list so they read as part of it.
                if !app.demoMode, store.query.isEmpty {
                    UnsentDraftRows(composerOpen: current == "new") { select("new") }
                }
                if showsEmptyState(sections, groups: groups) {
                    // Nothing working and the settled shelf closed: a calm, centered invitation instead of a bare line. With no
                    // session at all it sets up an agent, otherwise it starts a new session.
                    WSEmptyState(symbol: "terminal", title: tr("agents.noneWorkingNow"), message: tr("agents.emptyListDetail"),
                                 action: sections.isEmpty
                                    ? (title: tr("onboarding.agents.setUp"), run: { app.startOnboarding(at: OnboardingView.agentsStep) })
                                    : (title: tr("agents.newSession"), run: { select("new") }))
                } else {
                    ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        // Lazy: the list holds every running and earlier session, and only the ones in view are built.
                        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            if store.groupByProject {
                                ForEach(sections.filter { $0.kind == .pinned }, id: \.kind) { section in
                                    sectionView(section, sections: sections, byID: byID, shown: shown, projects: projects)
                                }
                                ForEach(groups) { group in
                                    projectView(group, sections: sections, byID: byID, shown: shown, projects: projects)
                                }
                            } else {
                                ForEach(sections.filter { !Self.isDocked($0.kind) }, id: \.kind) { section in
                                    sectionView(section, sections: sections, byID: byID, shown: shown, projects: projects)
                                }
                            }
                            // Only the docked shelves left (or nothing): say so instead of an empty space. Sessions at work
                            // below are not "nothing": then the space stays empty, as in t3code.
                            if sections.allSatisfy({ Self.isDocked($0.kind) }), groups.isEmpty,
                               !sections.contains(where: { $0.kind == .working }) { emptyState }
                        }
                    }
                    // A session opened from elsewhere (the keyboard, a card, search) is brought into view in the list; a click
                    // on a row does not move the list.
                    .onChange(of: current) { _, id in
                        defer { clickedID = nil }
                        guard id != clickedID, shown.contains(id) else { return }
                        DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(id, anchor: .center) } }
                    }
                    // With the keyboard (F6): ↑/↓ move, Return opens, ←/→ fold and unfold the row's project or shelf.
                    .focusable(interactions: .activate)
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) { moveKeyRow(-1, shown: shown, proxy: proxy) }
                    .onKeyPress(.downArrow) { moveKeyRow(1, shown: shown, proxy: proxy) }
                    .onKeyPress(.return) { openKeyRow(shown: shown) }
                    .onKeyPress(.leftArrow) { foldKeyRow(true, groups: groups, sections: sections) }
                    .onKeyPress(.rightArrow) { foldKeyRow(false, groups: groups, sections: sections) }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                // As in t3code: what works, what you snoozed and what you settled sit at the foot of the list, above the
                // footer, each header above its rows. A session that finishes leaves Working and comes up on top.
                ForEach(sections.filter { Self.isDocked($0.kind) }, id: \.kind) { section in
                    dockedShelf(section, sections: sections, byID: byID, shown: shown, projects: projects)
                }
            }
            .overlay(alignment: .bottom) { undoNotice }
            .animation(NookTheme.reveal, value: store.canUndo)
            if selection.isActive {
                selectionBar(rows: rows, byID: byID, shown: shown)
            }
        }
        .onChange(of: shown) { _, current in
            shownOrder = current
            selection.keep(only: current)
        }
        .alert(tr("inbox.project.renameTitle"), isPresented: Binding(get: { renamingProject != nil },
                                                                      set: { if !$0 { renamingProject = nil } })) {
            TextField(tr("settings.projects.name"), text: $projectName)
            Button(tr("inbox.project.renameSave")) {
                if let path = renamingProject { app.workspace.settings.setProjectName(projectName, project: path) }
                renamingProject = nil
            }
            Button(tr("inbox.project.renameCancel"), role: .cancel) { renamingProject = nil }
        }
        // A clone started from "Add project" is done: its folder becomes a project and the composer opens on it.
        .onReceive(CloneCenter.shared.$finished) { finished in
            guard let finished, pendingClones.remove(finished.id) != nil else { return }
            addProject(finished.path)
        }
        .sheet(item: $customSnooze) { item in
            CustomSnoozeSheet(title: item.title, onSnooze: { end in
                customSnooze = nil
                withAnimation(NookTheme.reveal) { snooze(item, until: end) }
            }, onCancel: { customSnooze = nil })
        }
        // F6 lands in the list; ⌘1–⌘9 open its first nine rows, F2 renames the row the keyboard is on.
        .focusArea(.sidebar) { listFocused = true; return true }
        .keyCommands(jumpKeys(shown))
        .keyCommands(["session.rename": { renameKeyRow() }], context: ["listFocus": listFocused], enabled: listFocused,
                     priority: 1)
        .onChange(of: listFocused) { _, focused in
            if focused, keyRow.map({ !shown.contains($0) }) ?? true { keyRow = shown.contains(current) ? current : shown.first }
        }
        // Only while the list is on screen: holding ⌘ shows the ⌘-numbers.
        .onAppear { commandHold.start() }
        .onDisappear { commandHold.stop() }
        .onAppear {
            shownOrder = shown
            pullRequests.follow(workspace: app.workspace, folders: pullRequestFolders, now: now)
            store.undoSnooze = { ids in
                for id in ids { if let uuid = UUID(uuidString: String(id.dropFirst(4))) { app.workspace.unsnooze(uuid) } }
            }
            store.undoArchive = { ids in
                for id in ids { if let uuid = UUID(uuidString: String(id.dropFirst(4))) { app.workspace.setArchived(uuid, false) } }
            }
            // Only sessions Nook sees through hooks; the ones it runs itself ("run:…") end their own turns.
            store.settleBusy = { ids in
                for id in ids where !id.hasPrefix("run:") { app.hub.settleByUser(id) }
            }
            store.settled = { items in app.applySettleActions(items) }
        }
        .onChange(of: now) { _, current in
            autoSettle(rows: rows, byID: byID, now: current)
            pullRequests.follow(workspace: app.workspace, folders: pullRequestFolders, now: current)
        }
    }

    /// Nothing here yet and nothing being searched or read: the coding agents step of the first-run flow installs or
    /// signs in an agent and adds projects.
    private var showsSetUp: Bool { store.query.isEmpty && !app.history.loading && !app.demoMode }

    /// The whole panel is empty: no search, nothing loading, and at most a closed shelf of settled sessions below.
    private func showsEmptyState(_ sections: [InboxSection], groups: [InboxProjectGroup]) -> Bool {
        // A pinned project keeps its folder also with no sessions, so a list with one is not empty.
        showsSetUp && groups.isEmpty && sections.allSatisfy { $0.kind == .snoozed || $0.kind == .settled }
            && sections.allSatisfy { collapsed.contains($0.kind) }
    }

    @ViewBuilder
    private var emptyState: some View {
        ListEmptyNote(store.query.isEmpty ? (app.history.loading ? tr("agents.checking") : tr("agents.noneWorkingNow")) : tr("inbox.noResults"),
                      padding: NookTheme.Spacing.lg)
    }

    // MARK: Search

    private var searchField: some View {
        NookSearchField(prompt: tr("inbox.search.placeholder"), text: $store.query, style: inSidebar ? .ghost : .panel)
    }

    // MARK: Sections

    /// The shelves at the foot of the list, under the scrolling rows: Working, Snoozed and Settled, as in t3code.
    private static func isDocked(_ kind: InboxSection.Kind) -> Bool { kind == .working || kind == .snoozed || kind == .settled }

    /// The shelves you folded, kept across launches. Snoozed and Settled start folded.
    private var collapsed: Set<InboxSection.Kind> { store.collapsedShelves }

    /// What a section draws: a folded shelf still shows the session that is open on the right, and a folded thread only
    /// its first session (and the open one).
    private func rows(of section: InboxSection) -> [InboxEntry] {
        let foldable = section.kind != .pinned && section.kind != .active
        let shown = InboxLayout.shownRows(section, folded: foldable && collapsed.contains(section.kind), selectedID: current)
        return InboxLayout.foldThreads(shown, isOpen: threadOpen, selectedID: current)
    }

    /// Whether a session's sub-threads show under it; a search opens every thread, so a match is never folded away.
    private func threadOpen(_ entry: InboxEntry) -> Bool {
        !store.query.isEmpty || InboxLayout.threadOpen(entry, opened: store.openedThreads, folded: store.foldedThreads)
    }

    @ViewBuilder
    private func sectionView(_ section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem], shown: [String],
                             projects: [String: String]) -> some View {
        switch section.kind {
        case .pinned, .active:
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                ForEach(rows(of: section)) { entry in
                    entryRow(entry, in: section, sections: sections, byID: byID, shown: shown, projects: projects)
                }
            }
            .padding(.bottom, section.kind == .pinned ? NookTheme.Spacing.md : 0)
        case .working, .snoozed, .settled:
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                shelfHeader(section)
                ForEach(rows(of: section)) { entry in
                    entryRow(entry, in: section, sections: sections, byID: byID, shown: shown, projects: projects)
                }
            }
            .padding(.top, NookTheme.Spacing.md)
        }
    }

    /// The ids top to bottom; grouped by project, the Active rows sit in their project's dropdown, with the docked shelves
    /// (Working, Snoozed, Settled) under the projects.
    private func shownIDs(_ sections: [InboxSection], groups: [InboxProjectGroup]) -> [String] {
        guard store.groupByProject else { return sections.flatMap { rows(of: $0).map(\.id) } }
        func ids(_ kinds: Set<InboxSection.Kind>) -> [String] {
            sections.filter { kinds.contains($0.kind) }.flatMap { rows(of: $0).map(\.id) }
        }
        return ids([.pinned]) + groups.flatMap { rows(of: $0).map(\.entry.id) } + ids([.working, .snoozed, .settled])
    }

    // MARK: Projects

    /// A folded project still shows the session that is open on the right; a search opens every project.
    private func rows(of group: InboxProjectGroup) -> [(kind: InboxSection.Kind, entry: InboxEntry)] {
        guard store.query.isEmpty, store.collapsedProjects.contains(group.project) else {
            let kept = Set(InboxLayout.foldThreads(group.rows.map(\.entry), isOpen: threadOpen, selectedID: current).map(\.id))
            return group.rows.filter { kept.contains($0.entry.id) }
        }
        return group.rows.filter { $0.entry.id == current }
    }

    /// One project as a dropdown: its header folds it, its rows act as the section they come from.
    private func projectView(_ group: InboxProjectGroup, sections: [InboxSection], byID: [String: AgentListItem],
                             shown: [String], projects: [String: String]) -> some View {
        let home = Dictionary(sections.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        let active = home[.active] ?? InboxSection(kind: .active, rows: [])
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            projectHeader(group, folder: folder(of: group, byID: byID), byID: byID)
            // Full width, so a row's fill runs under the header's; each row indents its name to the project's name.
            ForEach(rows(of: group), id: \.entry.id) { pair in
                entryRow(pair.entry, in: home[pair.kind] ?? active, sections: sections, byID: byID, shown: shown, projects: projects)
            }
        }
        .padding(.top, NookTheme.Spacing.md)
    }

    /// The folder a new session for this project starts in: the main checkout behind a session on this Mac (an agent's
    /// worktree leads back to its repository; a Nook session names the folder it was started on). Only a folder that is
    /// still there, also when the first session's worktree was removed. Nil for a project of sessions on other machines
    /// or without a folder.
    private func folder(of group: InboxProjectGroup, byID: [String: AgentListItem]) -> String? {
        guard group.project != InboxProject.none else { return nil }
        let local = group.rows.compactMap { byID[$0.entry.id] }.filter { $0.machine == MachineName.local }
        let paths = local.flatMap { item -> [String] in
            let started = item.id.hasPrefix("run:")
                ? UUID(uuidString: String(item.id.dropFirst(4))).flatMap { app.workspace.run($0)?.projectPath } : nil
            return [started, item.path].compactMap { $0 }
        }
        let settings = app.workspace.settings
        let known = settings.favoriteProjects + settings.recentProjects + [settings.lastProject] + settings.projectOverrides.projects
        return WorktreeOrigin.newSessionFolder(project: group.project, paths: paths, known: known)
    }

    /// Takes a project out of the list: every session in it settles (one undo brings them back), and a pinned project is
    /// unpinned, else its folder would come straight back empty.
    private func removeProject(_ group: InboxProjectGroup, folder: String?, byID: [String: AgentListItem]) {
        let items = group.rows.compactMap { byID[$0.entry.id] }
        withAnimation(NookTheme.reveal) {
            if group.pinned {
                let settings = app.workspace.settings
                // Every favorite that makes this folder pinned, not only the one the header resolved to.
                let pins = settings.favoriteProjects.filter {
                    InboxProject.key(folder: ($0 as NSString).lastPathComponent, path: $0) == group.project
                }
                for path in pins where settings.isFavoriteProject(path) { settings.toggleFavoriteProject(path) }
                if let folder, settings.isFavoriteProject(folder) { settings.toggleFavoriteProject(folder) }
            }
            if !items.isEmpty { store.settle(items) }
        }
    }

    /// Opens the new-session composer on `folder`.
    private func newSession(in folder: String) {
        PromptLinkInbox.shared.requestProject(folder)
        select("new")
    }

    private func projectHeader(_ group: InboxProjectGroup, folder: String?, byID: [String: AgentListItem]) -> some View {
        let open = !store.collapsedProjects.contains(group.project) || !store.query.isEmpty
        let settings = app.workspace.settings
        let named = group.project == InboxProject.none ? tr("inbox.project.none")
            : folder.map(settings.projectDisplayName) ?? group.project
        let name = group.archived ? tr("sc.archive.archivedName", named) : named
        return ProjectHeaderRow(
            project: folder.map(AgentPathFormat.tilde) ?? group.project, name: name, open: open, dot: group.dot,
            count: group.rows.count, icon: folderIcon(group, folder: folder), pinned: group.pinned,
            toggle: {
                withAnimation(NookTheme.reveal) {
                    if store.collapsedProjects.contains(group.project) {
                        store.collapsedProjects.remove(group.project)
                    } else {
                        store.collapsedProjects.insert(group.project)
                    }
                }
            },
            newSession: folder.map { path -> () -> Void in { newSession(in: path) } },
            actions: folder.map { path in projectActions(group, path: path) },
            remove: group.rows.isEmpty ? nil : { removeProject(group, folder: folder, byID: byID) })
    }

    /// What a project's folder menu does with its folder on this Mac, as t3code's: pin, rename, settings, archive.
    private func projectActions(_ group: InboxProjectGroup, path: String) -> ProjectFolderActions {
        let settings = app.workspace.settings
        let archived = settings.isArchivedProject(path)
        return ProjectFolderActions(
            pinned: group.pinned,
            archived: archived,
            togglePin: { withAnimation(NookTheme.reveal) { settings.toggleFavoriteProject(path) } },
            copyPath: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            rename: {
                projectName = settings.projectDisplayName(path)
                renamingProject = path
            },
            settings: { app.openProjectSettings(path) },
            toggleArchive: {
                withAnimation(NookTheme.reveal) {
                    // An archived project is no longer pinned: it leaves the pickers and the top of the list.
                    if !archived, settings.isFavoriteProject(path) { settings.toggleFavoriteProject(path) }
                    settings.setArchived(!archived, project: path)
                }
            })
    }

    /// The pinned projects by the name their folder goes by in the list: your favorite projects, not archived.
    private var pinnedProjects: [String] {
        let settings = app.workspace.settings
        var seen: Set<String> = []
        return ProjectSettings.withoutArchived(settings.favoriteProjects, overrides: settings.projectOverrides)
            .map { InboxProject.key(folder: ($0 as NSString).lastPathComponent, path: $0) }
            .filter { $0 != InboxProject.none && seen.insert($0).inserted }
    }

    /// The archived projects by the name their folder goes by in the list. A name another project you use still goes
    /// by (a favorite or recent folder that is not archived) is left out: the folders are grouped by name, and archiving
    /// one "app" must not put another one's sessions at the bottom.
    private var archivedProjects: Set<String> {
        let settings = app.workspace.settings
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        let archived = settings.projectOverrides.projects.filter(settings.isArchivedProject)
        let inUse = Set((settings.favoriteProjects + settings.recentProjects)
            .filter { !settings.isArchivedProject($0) }.map(name))
        return Set(archived.map(name)).subtracting(inUse)
    }

    /// Adds a project ("Add project", as t3code's): pinned, so it is in the pickers and its folder shows when the list is
    /// grouped, and the new-session composer opens on it.
    private func addProject(_ path: String) {
        withAnimation(NookTheme.reveal) {
            app.workspace.settings.addProject(path)
            store.collapsedProjects.remove(InboxProject.key(folder: (path as NSString).lastPathComponent, path: path))
        }
        newSession(in: path)
    }

    /// The icon the group's project set for itself (Settings › Projects): by its folder, else by the project's name, else
    /// the badge its sessions show (`ProjectIcon.defaultIcon`), so a folder and its rows look alike.
    private func folderIcon(_ group: InboxProjectGroup, folder: String?) -> ProjectIcon? {
        guard !group.project.isEmpty else { return nil }
        let settings = app.workspace.settings
        if let icon = folder.flatMap(settings.projectIcon) { return icon }
        let path = settings.projectOverrides.projects.first { ($0 as NSString).lastPathComponent == group.project }
        if let icon = path.flatMap(settings.projectIcon) { return icon }
        let name = folder.map(settings.projectDisplayName) ?? group.project
        return .monogram(ProjectIcon.initials(name), ProjectIcon.defaultTint(group.project))
    }

    // MARK: A row's project

    /// The project folders on this Mac by the name their sessions are listed under (`InboxProject.key`): the projects you
    /// set something for, your favorites, the recent ones and the last one. Made once per redraw from settings only; a row
    /// never touches the disk to find its project.
    private var projectFolders: [String: String] {
        let settings = app.workspace.settings
        var folders: [String: String] = [:]
        let known = settings.projectOverrides.projects + settings.favoriteProjects + settings.recentProjects + [settings.lastProject]
        for path in known where !path.isEmpty {
            let key = InboxProject.key(folder: (path as NSString).lastPathComponent, path: path)
            if key != InboxProject.none, folders[key] == nil { folders[key] = path }
        }
        return folders
    }

    /// The project a row names, as t3code's: the name you gave it and its badge, for every session with a project. A session
    /// in a folder not known yet goes by its folder's name; one without a project gets none.
    private func rowProject(_ item: AgentListItem, projects: [String: String]) -> RowProject? {
        let key = InboxProject.key(folder: item.folder, path: item.path)
        guard key != InboxProject.none else { return nil }
        let settings = app.workspace.settings
        let path = projects[key] ?? (item.machine == MachineName.local && (item.path as NSString).lastPathComponent == key ? item.path : nil)
        let name = path.map(settings.projectDisplayName) ?? key
        let icon = path.flatMap(settings.projectIcon) ?? .monogram(ProjectIcon.initials(name), ProjectIcon.defaultTint(key))
        return RowProject(name: name, icon: icon, path: path)
    }

    /// The row's Project menu: what a project folder's menu does, from any of its sessions, so the list does not have to
    /// be grouped to start a session in a project, rename it, give it a color, pin it or open its settings.
    @ViewBuilder
    private func projectMenu(_ project: RowProject) -> some View {
        if let path = project.path {
            let settings = app.workspace.settings
            Menu(tr("inbox.project.menu", project.name)) {
                Button(tr("inbox.project.newSession", project.name)) { newSession(in: path) }
                Divider()
                Button(tr("inbox.project.rename")) {
                    projectName = settings.projectDisplayName(path)
                    renamingProject = path
                }
                Menu(tr("inbox.project.color")) {
                    ForEach(ProjectIcon.Tint.allCases) { tint in
                        Button {
                            let letters: String
                            if case .monogram(let current, _) = project.icon { letters = current } else {
                                letters = ProjectIcon.initials(project.name)
                            }
                            settings.setProjectIcon(.monogram(letters, tint), project: path)
                        } label: {
                            if project.icon.tint == tint {
                                Label(tr("inbox.project.tint." + tint.rawValue), icon: "checkmark")
                            } else {
                                Text(tr("inbox.project.tint." + tint.rawValue))
                            }
                        }
                    }
                }
                if !settings.isArchivedProject(path) {
                    Button(tr(settings.isFavoriteProject(path) ? "inbox.project.unpin" : "inbox.project.pin")) {
                        withAnimation(NookTheme.reveal) { settings.toggleFavoriteProject(path) }
                    }
                }
                Button(tr("inbox.project.reveal")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                Button(tr("inbox.project.settings")) { app.openProjectSettings(path) }
            }
        }
    }

    /// A shelf docked at the foot of the list: opening it lifts its header and lays its rows out below, scrolling on their
    /// own once they no longer fit.
    private func dockedShelf(_ section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem],
                              shown: [String], projects: [String: String]) -> some View {
        let open = !collapsed.contains(section.kind)
        let list = VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ForEach(rows(of: section)) { entry in
                entryRow(entry, in: section, sections: sections, byID: byID, shown: shown, projects: projects)
            }
            if open && section.hiddenCount > 0 {
                Button { settledLimit += InboxLayout.settledPage } label: {
                    Text(tr("inbox.moreSettled", min(section.hiddenCount, InboxLayout.settledPage)))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textTertiary)
                        .padding(.horizontal, NookTheme.Spacing.lg)
                        .padding(.vertical, NookTheme.Spacing.sm)
                }
                .buttonStyle(.nookPlain)
            }
        }
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            shelfHeader(section)
            if !rows(of: section).isEmpty {
                // As tall as its rows, up to 280, then it scrolls. Measured: a flexible scroll view would take all 280 and
                // leave a gap between the header and a single row.
                ScrollView(showsIndicators: false) {
                    list.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shelfHeights[section.kind] = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(shelfHeights[section.kind] ?? 0, Self.shelfMaxHeight))
            }
        }
    }

    private func shelfHeader(_ section: InboxSection) -> some View {
        let open = !collapsed.contains(section.kind)
        let count = section.rows.count + section.hiddenCount
        return NookShelfHeader(title: tr("inbox.section." + section.kind.rawValue), count: count, open: open) {
            withAnimation(NookTheme.reveal) {
                store.setShelf(section.kind, collapsed: open)
            }
        }
    }

    // MARK: A row

    /// A session's row, and under a session that started others the fold of its sub-threads.
    private func entryRow(_ entry: InboxEntry, in section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem],
                          shown: [String], projects: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            sessionRow(entry, in: section, sections: sections, byID: byID, shown: shown, projects: projects)
            if entry.subThreads > 0, byID[entry.id] != nil { threadToggle(entry) }
        }
    }

    /// The fold of a session's sub-threads, one step in where they sit: a chevron and how many there are. Folded, a dot
    /// says that one of them waits for you (amber) or works (iris), so nothing that needs you is folded out of sight.
    private func threadToggle(_ entry: InboxEntry) -> some View {
        let open = threadOpen(entry)
        let count = entry.subThreads == 1 ? tr("inbox.thread.one") : tr("inbox.thread.many", entry.subThreads)
        let signal: (color: Color, help: String)? = open ? nil
            : entry.subThreadNeedsYou ? (NookTheme.amber, tr("inbox.thread.needsYou"))
            : entry.subThreadActive ? (NookTheme.iris, tr("inbox.thread.working")) : nil
        return Button {
            withAnimation(NookTheme.reveal) { store.setThread(entry.id, open: !open) }
        } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(icon: "chevron.down")
                    .font(NookTheme.font(9, .semibold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .frame(width: NookTheme.Spacing.xl)
                Text(count)
                    .font(NookTheme.TextStyle.detail)
                    .lineLimit(1)
                if let signal {
                    Circle().fill(signal.color).frame(width: 6, height: 6)
                        .nookTip(signal.help)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(NookTheme.textTertiary)
            // Where the sub-threads' turn arrows stand, so the fold reads as the head of what sits under it.
            .padding(.leading, NookTheme.Spacing.md + CGFloat(min(entry.depth, 1)) * NookTheme.Spacing.xl)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .nookTip(open ? tr("inbox.thread.hide") : tr("inbox.thread.show"))
        .accessibilityLabel(open ? tr("inbox.thread.hide") : tr("inbox.thread.show"))
        .accessibilityValue(signal.map { count + ", " + $0.help } ?? count)
    }

    @ViewBuilder
    private func sessionRow(_ entry: InboxEntry, in section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem],
                            shown: [String], projects: [String: String]) -> some View {
        if let item = byID[entry.id] {
            let slim = section.kind == .snoozed || section.kind == .settled
            let isRun = runID(item) != nil
            let snoozeActive = section.kind == .snoozed
            // Under its project's header a row needs no badge; everywhere else it names its project.
            let grouped = store.groupByProject && section.kind == .active
            let project = rowProject(item, projects: projects)
            AgentListRow(
                item: item, now: now, selected: current == item.id,
                receded: entry.receded, pinned: entry.row.pinned, woke: entry.woke, slim: slim,
                grouped: grouped,
                wakeLabel: snoozeActive ? item.snoozedUntil.map { tr("inbox.snooze.until", Self.wakeFormat.string(from: $0)) } : nil,
                project: grouped ? nil : project,
                actions: AgentRowActions(
                    pinned: entry.row.pinned,
                    onPin: { withAnimation(NookTheme.reveal) { entry.row.pinned ? store.unpin(item.id) : pinAndUnsettle(item, entry) } },
                    settled: entry.row.settled,
                    onSettle: { withAnimation(NookTheme.reveal) { entry.row.settled ? store.unsettle([item]) : store.settle([item]) } },
                    onWake: isRun && snoozeActive ? { withAnimation(NookTheme.reveal) { wake(item) } } : nil,
                    limitResetsAt: SnoozePolicy.limitResetEnd(limitedAt: item.limitedAt, resetAt: item.limitResetAt, now: now),
                    onSnoozeUntil: isRun ? { end in withAnimation(NookTheme.reveal) { snooze(item, until: end) } } : nil,
                    onSnoozeCustom: isRun ? { customSnooze = item } : nil,
                    onSettleSweep: { ids in sweepSettle(ids, unsettle: entry.row.settled, byID: byID) },
                    onWakeSweep: isRun && snoozeActive ? { ids in sweepWake(ids, byID: byID) } : nil),
                pullRequests: sessionPullRequests(item),
                jumpHint: jumpNumber(item.id),
                keyFocused: listFocused && keyRow == item.id,
                sweepOrigin: sweep.origin == item.id,
                openPullRequest: { url in
                    select(item.id)
                    // Another forge, or GitHub not connected: its web page.
                    if !app.openPullRequestLink(url, beside: true) { BrowserStore.show(url) }
                },
                openChange: { file in
                    select(item.id)
                    app.viewModel.sessionDiffToOpen = TurnDiffSelection(turn: TurnDiffSelection.branch, file: file)
                }
            ) {
                click(item, entry, shown: shownOrder)
            }
            // Redrawn only when what the row shows changed: the list redraws on every tick and every store change.
            .equatable()
            .id(item.id)
            // A Settle or Wake sweep takes the rows of the section it started in; the rows it covers light up.
            .sweepRow(SessionSweep.rows, id: item.id, group: section.kind.rawValue)
            .overlay {
                if sweep.swept.contains(item.id) {
                    NookTheme.shape(NookTheme.Radius.card)
                        .fill(NookTheme.iris.opacity(0.14))
                        .allowsHitTesting(false)
                }
            }
            .nested(entry.depth)
            // Read the session's timeline or transcript once the pointer rests on it, so the click opens it without a hitch.
            .onHover { inside in
                if inside {
                    hoverPrefetch.enter(item.id, after: Self.restBeforePrefetch) { prefetch(item) }
                } else {
                    hoverPrefetch.exit(item.id)
                }
            }
            // Dragged onto an agent's composer, the row becomes that session's chip (`SessionLink`).
            .sessionLinkDrag(id: runID(item)?.uuidString, title: item.title)
            .selectable(active: selection.isActive, selected: selection.contains(item.id)) {
                withAnimation(NookTheme.reveal) { selection.toggle(item.id) }
            }
            .contextMenu { contextMenu(item, entry, in: section, project: project) }
            // Files dropped on a session Nook runs open it with them attached to its composer.
            .onDrop(of: [.fileURL], isTargeted: Binding(
                get: { dropTarget == item.id },
                set: { dropTarget = $0 ? item.id : (dropTarget == item.id ? nil : dropTarget) })) { providers in
                    dropFiles(providers, on: item)
            }
            .overlay {
                if dropTarget == item.id, runID(item) != nil {
                    NookTheme.shape(NookTheme.Radius.card)
                        .stroke(NookTheme.paper.opacity(0.5), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            // "Rename": a field over the row's title, Return keeps the name and Escape leaves it.
            .overlay {
                if renaming == item.id, let id = runID(item) {
                    InboxRenameField(name: item.title) { name in
                        if let name { app.workspace.rename(id, to: name) }
                        renaming = nil
                    }
                }
            }
        }
    }

    /// How long the pointer rests on a row before its session is read ahead of the click.
    private static let restBeforePrefetch: Duration = .milliseconds(120)

    /// Reads what opening this row shows, off the main thread: a session Nook runs its timeline, an earlier session the
    /// session that took it over (else its transcript), a running session its transcript.
    private func prefetch(_ item: AgentListItem) {
        if let id = runID(item) {
            app.workspace.prefetchTimeline(id)
            return
        }
        // The demo's sessions have no transcript on disk.
        guard !app.demoMode else { return }
        if item.id.hasPrefix("past:") {
            guard let session = pastSession(item.id) else { return }
            // One Nook took over opens as its session: that timeline is what it shows.
            if let taken = app.adoptedRun(for: session) {
                app.workspace.prefetchTimeline(taken)
            } else {
                TranscriptPrefetch.warm(path: session.path)
            }
            return
        }
        guard let session = app.agentSessions.first(where: { $0.id == item.id }) else { return }
        TranscriptPrefetch.warm(path: session.transcriptPath.isEmpty ? (transcriptPath(of: session) ?? "") : session.transcriptPath)
    }

    /// The transcript of a running session whose hooks did not report one: the earlier session that holds its
    /// conversation, once the history has read it (as `AgentsTab` finds it).
    private func transcriptPath(of session: AgentSession) -> String? {
        guard let kind = AgentKind(agentName: session.name), let conversation = app.conversationID(for: session) else { return nil }
        return app.history.sessions.first { $0.agent == kind && ($0.sessionID == conversation || $0.earlierIDs.contains(conversation)) }?.path
    }

    /// A click on a row: opens the session, or with ⌘, ⇧ or while selecting, picks it.
    private func click(_ item: AgentListItem, _ entry: InboxEntry, shown: [String]) {
        let keys = SelectionClick.modifiers()
        switch selection.click(command: keys.command, shift: keys.shift) {
        case .open:
            clickedID = item.id
            select(item.id)
            if entry.woke { store.dismissWoke(item.id) }
        case .toggle:
            withAnimation(NookTheme.reveal) { selection.toggle(item.id) }
        case .extend:
            withAnimation(NookTheme.reveal) { selection.extend(to: item.id, in: shown) }
        }
    }

    /// Opens the session and hands the dropped files to its composer. False for a session Nook does not run (it has no
    /// composer here), so the drop is refused.
    private func dropFiles(_ providers: [NSItemProvider], on item: AgentListItem) -> Bool {
        guard let id = runID(item) else { return false }
        let fileProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !fileProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in fileProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            clickedID = item.id
            select(item.id)
            app.viewModel.filesToAttach = SessionFileDrop(session: id, urls: urls.sorted { $0.path < $1.path })
        }
        return true
    }

    private func pinAndUnsettle(_ item: AgentListItem, _ entry: InboxEntry) {
        if entry.row.settled { store.unsettle([item], record: false) }
        store.pin(item.id)
    }

    // MARK: Actions

    private func snooze(_ item: AgentListItem, until end: Date) {
        guard let id = runID(item) else { return }
        app.workspace.snooze(id, until: end)
        store.note(.snoozed, ids: [item.id])
    }

    private func wake(_ item: AgentListItem) {
        guard let id = runID(item) else { return }
        app.workspace.unsnooze(id)
    }

    /// Settle (or Un-settle) dragged over rows: every row swept goes the way of the one it started on, with one undo.
    private func sweepSettle(_ ids: [String], unsettle: Bool, byID: [String: AgentListItem]) {
        let items = ids.compactMap { byID[$0] }
        guard !items.isEmpty else { return }
        withAnimation(NookTheme.reveal) { unsettle ? store.unsettle(items) : store.settle(items) }
    }

    /// Wake dragged over snoozed rows: they all wake.
    private func sweepWake(_ ids: [String], byID: [String: AgentListItem]) {
        withAnimation(NookTheme.reveal) { ids.compactMap { byID[$0] }.forEach(wake) }
    }

    @ViewBuilder
    private func contextMenu(_ item: AgentListItem, _ entry: InboxEntry, in section: InboxSection, project: RowProject?) -> some View {
        if runID(item) != nil {
            Button(tr("agents.run.rename")) { renaming = item.id }
        }
        Button(entry.row.pinned ? tr("inbox.unpin") : tr("inbox.pin")) {
            withAnimation(NookTheme.reveal) { entry.row.pinned ? store.unpin(item.id) : pinAndUnsettle(item, entry) }
        }
        // Pinned and Active sessions keep the order you give them: one step up or down. Grouped by project, Active rows
        // are ordered by activity inside their project, so there is no order of yours to change.
        if section.kind == .pinned || (section.kind == .active && !store.groupByProject) {
            let up = InboxLayout.moveTarget(item.id, up: true, in: section)
            let down = InboxLayout.moveTarget(item.id, up: false, in: section)
            Button(tr("inbox.moveUp")) {
                if let up { withAnimation(NookTheme.reveal) { store.reorder(item.id, toIndex: up, within: section) } }
            }
            .disabled(up == nil)
            Button(tr("inbox.moveDown")) {
                if let down { withAnimation(NookTheme.reveal) { store.reorder(item.id, toIndex: down, within: section) } }
            }
            .disabled(down == nil)
        }
        // With auto-settle on, one session can stay out of it (`AutoSettlePolicy.Settings.perThreadOptOut`).
        if store.autoSettle.enabled, !entry.row.settled {
            let optedOut = store.autoSettle.perThreadOptOut.contains(item.id)
            Button(tr(optedOut ? "inbox.autoSettle.allow" : "inbox.autoSettle.keep")) {
                if optedOut { store.autoSettle.perThreadOptOut.remove(item.id) } else { store.autoSettle.perThreadOptOut.insert(item.id) }
            }
        }
        // A busy session can be settled too: a turn that hangs should not stay in the list forever.
        if item.id.hasPrefix("past:") && entry.row.settled {
            // Earlier sessions are settled by nature; only a session that ran can be reopened.
            EmptyView()
        } else {
            Button(entry.row.settled ? tr("inbox.reopen") : tr("inbox.settle")) {
                withAnimation(NookTheme.reveal) { entry.row.settled ? store.unsettle([item]) : store.settle([item]) }
            }
        }
        if let id = runID(item), let run = app.workspace.run(id) {
            if let until = run.snoozedUntil, until > now {
                Button(tr("agents.snooze.cancel")) { withAnimation(NookTheme.reveal) { wake(item) } }
            } else if !item.isBusy {
                Menu(tr("agents.snooze.menu")) {
                    SnoozeMenuItems(
                        now: now,
                        limitResetsAt: SnoozePolicy.limitResetEnd(limitedAt: run.limitedAt, resetAt: run.limitResetAt, now: now),
                        onUntil: { end in withAnimation(NookTheme.reveal) { snooze(item, until: end) } },
                        onCustom: { customSnooze = item })
                }
            }
            Divider()
            Button(tr("agents.fork")) {
                if let forked = app.workspace.fork(id) { select("run:" + forked.uuidString) }
            }
            .disabled(!app.workspace.canTransfer(id))
            Button(tr("agents.restartAgent")) { app.workspace.restartAgent(id) }
                .disabled(!app.workspace.canRestartAgent(id))
        }
        Button(tr("inbox.markUnread")) { visits.markUnread(item.id) }
        if let project { projectMenu(project) }
        Divider()
        Menu(tr("inbox.copy")) {
            Button(tr("inbox.copy.path")) { Pasteboard.copy(item.path) }
            if let branch = item.branch { Button(tr("inbox.copy.branch")) { Pasteboard.copy(branch) } }
            Button(tr("inbox.copy.id")) { Pasteboard.copy(item.id) }
            if let id = runID(item), let link = SessionLink.build(id: id.uuidString, title: item.title) {
                // Pasted into an agent's composer it becomes this session's chip; elsewhere it opens the session.
                Button(tr("sessionLink.copy")) { Pasteboard.copy(link.absoluteString) }
            }
        }
        if let id = runID(item) {
            Button(tr("agents.run.archive")) {
                withAnimation(NookTheme.reveal) {
                    app.workspace.setArchived(id, true)
                    store.note(.archived, ids: [item.id])
                }
            }
            .disabled(item.isBusy)
        }
    }

    // MARK: Several at once

    private func selectionBar(rows: [InboxRow], byID: [String: AgentListItem], shown: [String]) -> some View {
        let ids = selection.ordered(shown)
        let picked = ids.compactMap { byID[$0] }
        let rowByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let allPinned = !picked.isEmpty && picked.allSatisfy { store.state.pinned.contains($0.id) }
        let settled = picked.filter { rowByID[$0.id]?.settled == true }
        let allSettled = !picked.isEmpty && settled.count == picked.count
        // Earlier sessions are settled by nature; only a session that ran can be reopened.
        let reopenable = settled.filter { !$0.id.hasPrefix("past:") }
        let settleable = picked.filter { rowByID[$0.id]?.settled != true }
        let archivable = picked.filter { !$0.isBusy && runID($0) != nil }
        var actions: [SelectionAction] = [
            picked.contains(where: \.unseen)
                ? SelectionAction(symbol: "envelope.open", label: tr("select.markRead")) { visits.visit(picked.map(\.id)) }
                : SelectionAction(symbol: "envelope.badge", label: tr("select.markUnread")) { for item in picked { visits.markUnread(item.id) } },
            allPinned
                ? SelectionAction(symbol: "pin.slash", label: tr("select.unpin")) { store.unpin(picked.map(\.id)) }
                : SelectionAction(symbol: "pin", label: tr("select.pin")) {
                    let settledPicks = picked.filter { rowByID[$0.id]?.settled == true && !$0.id.hasPrefix("past:") }
                    if !settledPicks.isEmpty { store.unsettle(settledPicks, record: false) }
                    store.pin(picked.map(\.id).filter { !store.state.pinned.contains($0) })
                },
        ]
        actions.append(allSettled
            ? SelectionAction(symbol: "arrow.uturn.backward", label: tr("select.reopen"), enabled: !reopenable.isEmpty) { store.unsettle(reopenable) }
            : SelectionAction(symbol: "checkmark", label: tr("select.settle"), enabled: !settleable.isEmpty) { store.settle(settleable) })
        actions.append(SelectionAction(symbol: "archivebox", label: tr("select.archive"), enabled: !archivable.isEmpty) {
            for item in archivable { if let id = runID(item) { app.workspace.setArchived(id, true) } }
            store.note(.archived, ids: archivable.map(\.id))
        })
        // Deleting is for work that is out of the way: settled or archived sessions Nook runs, never one that works. The
        // same path as a single delete, so each session's own worktree goes by the cleanup rules.
        let deletable = picked.filter { item in
            guard !item.isBusy, let id = runID(item), let run = app.workspace.run(id) else { return false }
            return run.archived || rowByID[item.id]?.settled == true
        }
        actions.append(SelectionAction(symbol: "trash", label: tr("automation.bulkDelete"), destructive: true,
                                       enabled: !deletable.isEmpty,
                                       confirm: tr("automation.bulkDelete.confirm", deletable.count)) {
            let ids = deletable.compactMap { runID($0) }
            withAnimation(NookTheme.reveal) {
                for id in ids { app.workspace.delete(id) }
                if deletable.contains(where: { $0.id == current }) { app.viewModel.selectedAgentID = "" }
                selection.clear()
            }
        })
        return SelectionBar(count: ids.count, allSelected: !shown.isEmpty && ids.count == shown.count,
                            actions: actions,
                            toggleAll: { selection.toggleAll(shown) },
                            done: { withAnimation(NookTheme.reveal) { selection.clear() } })
    }

    // MARK: Auto-settle

    private func autoSettle(rows: [InboxRow], byID: [String: AgentListItem], now: Date) {
        let workspace = app.workspace
        let ids = store.autoSettleCandidates(rows: rows, pullRequest: { id in
            runID(byID[id]).map { run in pullRequests.autoSettleState(run, since: workspace.lastWrittenAt(run)) } ?? .none
        }, now: now)
        let settle = ids.compactMap { byID[$0] }
        guard !settle.isEmpty else { return }
        store.settle(settle, now: now, record: false)
        // As a settle of yours: a few seconds to take it back (⌘Z); after that Reopen on the Settled shelf brings it back,
        // and it then stays until it has new activity.
        store.note(.autoSettled, ids: settle.map(\.finishKey), now: now)
    }

    // MARK: Undo

    /// Only ticks while there is something to undo: an idle inbox redrew this every second for nothing.
    @ViewBuilder
    private var undoNotice: some View {
        if store.canUndo {
            undoTimeline
        }
    }

    private var undoTimeline: some View {
        TimelineView(.nookTicks(every: 1)) { context in
            if let entry = store.undoLog.current(now: context.date) {
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr(entry.messageKey, entry.count))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // On a narrow panel the message gives way first; the button never wraps and shrinks to its icon.
                    Button { store.undo() } label: {
                        ViewThatFits(in: .horizontal) {
                            Text(tr("inbox.undo")).lineLimit(1).fixedSize()
                            Image(icon: "arrow.uturn.backward")
                        }
                    }
                        .buttonStyle(.nookPlain)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.iris)
                        .nookTip(tr("inbox.undo"))
                        .layoutPriority(1)
                        // ⌘Z, while no text field has the keyboard (there it undoes typing).
                        .keyCommand("session.undo") { store.undo() }
                }
                .padding(.horizontal, NookTheme.Spacing.lg)
                .frame(height: 32)
                // Lifted a step above the sidebar it floats over, as a toast is, so the rows under it don't read through.
                .cardBackground(NookTheme.smoke, stroke: NookTheme.line2, radius: NookTheme.Radius.card)
                .shadow(color: NookTheme.notch.opacity(0.45), radius: 14, y: 6)
                .transition(.opacity)
            }
        }
    }
}

// MARK: Keyboard

extension AgentInboxList {
    /// The ⌘-number of one of the first nine rows while ⌘ is held; nil otherwise.
    private func jumpNumber(_ id: String) -> Int? {
        guard commandHold.held, let index = shownOrder.prefix(SessionJump.count).firstIndex(of: id) else { return nil }
        return index + 1
    }

    /// ⌘1–⌘9: the first nine rows as shown. Past the end the key goes on (to the main window's tabs).
    private func jumpKeys(_ shown: [String]) -> [String: () -> Bool] {
        var out: [String: () -> Bool] = [:]
        for number in 1...SessionJump.count {
            out[SessionJump.command(number)] = {
                guard let id = SessionJump.target(number, in: shown) else { return false }
                select(id)
                return true
            }
        }
        return out
    }

    /// ↑/↓ with the keyboard in the list: the next row up or down, kept in view, without opening it.
    private func moveKeyRow(_ offset: Int, shown: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !shown.isEmpty else { return .ignored }
        let start = keyRow.flatMap { shown.firstIndex(of: $0) } ?? shown.firstIndex(of: current)
        let next = start.map { min(max($0 + offset, 0), shown.count - 1) } ?? (offset > 0 ? 0 : shown.count - 1)
        keyRow = shown[next]
        withAnimation(NookTheme.scroll) { proxy.scrollTo(shown[next]) }
        return .handled
    }

    /// Return: opens the row the keyboard is on.
    private func openKeyRow(shown: [String]) -> KeyPress.Result {
        guard let keyRow, shown.contains(keyRow) else { return .ignored }
        clickedID = keyRow
        select(keyRow)
        return .handled
    }

    /// ← folds the sub-threads, project (or shelf) of the row the keyboard is on, → unfolds them.
    private func foldKeyRow(_ fold: Bool, groups: [InboxProjectGroup], sections: [InboxSection]) -> KeyPress.Result {
        guard let keyRow else { return .ignored }
        // On a session with sub-threads the keys fold and open those first, as a folder in Finder's list.
        if let entry = sections.lazy.flatMap(\.rows).first(where: { $0.id == keyRow }), entry.subThreads > 0,
           threadOpen(entry) == fold, store.query.isEmpty {
            withAnimation(NookTheme.reveal) { store.setThread(entry.id, open: !fold) }
            return .handled
        }
        if store.groupByProject, let group = groups.first(where: { $0.rows.contains { $0.entry.id == keyRow } }) {
            withAnimation(NookTheme.reveal) {
                if fold { store.collapsedProjects.insert(group.project) } else { store.collapsedProjects.remove(group.project) }
            }
            return .handled
        }
        if let section = sections.first(where: { $0.rows.contains { $0.id == keyRow } }),
           section.kind != .pinned, section.kind != .active {
            withAnimation(NookTheme.reveal) {
                store.setShelf(section.kind, collapsed: fold)
            }
            return .handled
        }
        return .ignored
    }

    /// F2 in the list: opens the row the keyboard is on and its name field. Only sessions Nook runs have a name of
    /// Nook's to change; for the others the key goes on.
    private func renameKeyRow() -> Bool {
        guard listFocused, let keyRow, keyRow.hasPrefix("run:"),
              let id = UUID(uuidString: String(keyRow.dropFirst(4))) else { return false }
        if keyRow != current { select(keyRow) }
        SessionRenameRequest.shared.request(id)
        return true
    }
}

/// A project's header in the list grouped by project: folds the project, and when the project has a folder on this Mac
/// starts a new session in it. It keeps its own hover, so the pointer moving over the headers redraws only the header
/// it crosses, never the whole list.
private struct ProjectHeaderRow: View {
    /// The project's folder name, shown in full as the tip (the name may be cut off in the middle).
    let project: String
    let name: String
    /// Unfolded (or opened by a search): handed in as a value, so a fold anywhere redraws the header.
    let open: Bool
    /// What the sessions in it say, shown while it is folded.
    let dot: InboxProjectGroup.Dot?
    let count: Int
    let icon: ProjectIcon?
    let pinned: Bool
    let toggle: () -> Void
    /// Nil for a project without a folder on this Mac: no "+".
    let newSession: (() -> Void)?
    /// Nil for a project without a folder on this Mac: nothing to pin, rename or archive.
    let actions: ProjectFolderActions?
    /// Nil when nothing in it can be taken out of the list (a pinned project with no sessions).
    let remove: (() -> Void)?
    @State private var hovering = false

    private static let chevronWidth: CGFloat = 12
    private static let newSessionWidth: CGFloat = 24
    /// The row's inset and the gap between its parts.
    private static let gap = NookTheme.Spacing.md + NookTheme.Spacing.xxs

    var body: some View {
        foldButton
            .overlay(alignment: .trailing) {
                if let newSession {
                    // Shown while the pointer is on the folder, over the count (which steps aside), as in t3code.
                    ToolbarIconButton("square.and.pencil", tr("inbox.project.newSession", name),
                                      height: Self.newSessionWidth, width: Self.newSessionWidth) { newSession() }
                    // On the count's slot in `foldButton`, just before the chevron. Only under the pointer, as a row's own
                    // actions: a pencil on every project header made the list read as a toolbar.
                    .padding(.trailing, Self.chevronWidth + 2 * Self.gap)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .animation(NookTheme.hover, value: hovering)
                }
            }
            .contextMenu {
                if let newSession {
                    Button(tr("inbox.project.newSession", name), action: newSession)
                }
                if let actions {
                    Button(tr("inbox.project.copyPath"), action: actions.copyPath)
                    Button(tr("inbox.project.reveal"), action: actions.reveal)
                    Divider()
                    if !actions.archived {
                        Button(tr(actions.pinned ? "inbox.project.unpin" : "inbox.project.pin"), action: actions.togglePin)
                    }
                    Button(tr("inbox.project.rename"), action: actions.rename)
                    Button(tr("inbox.project.settings"), action: actions.settings)
                    Button(tr(actions.archived ? "inbox.project.unarchive" : "inbox.project.archive"), action: actions.toggleArchive)
                }
                if let remove {
                    Divider()
                    // The folder comes back by itself when a new session starts in it; its sessions stay under Settled.
                    Button(tr("inbox.project.remove"), role: .destructive, action: remove)
                }
            }
            .onHover { hovering = $0 }
    }

    private var foldButton: some View {
        Button(action: toggle) {
            // The folder's mark is 16 wide, so with this padding and gap a session's name (36 in) lines up with the project's.
            HStack(spacing: Self.gap) {
                if let icon {
                    ProjectIconView(icon: icon, size: 15)
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(width: NookTheme.Spacing.xl)
                } else {
                    Image(icon: open ? "folder" : "folder.fill")
                        .font(NookTheme.font(13, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(width: NookTheme.Spacing.xl)
                }
                Text(name)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.textStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if pinned {
                    Image(icon: "pin.fill")
                        .font(NookTheme.font(9, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .accessibilityLabel(tr("inbox.project.pinned"))
                }
                // Folded, the header still says what the sessions in it do: waiting for you, failed, done or working.
                if !open, let dot {
                    Circle().fill(Self.color(dot)).frame(width: 6, height: 6)
                        .accessibilityLabel(tr("inbox.project.dot." + Self.key(dot)))
                }
                Spacer(minLength: 0)
                // The count, and the slot the new-session button takes while the pointer is on the folder.
                ZStack(alignment: .trailing) {
                    if !open && count > 0 {
                        Text("\(count)")
                            .font(NookTheme.TextStyle.detail.monospacedDigit())
                            .foregroundStyle(NookTheme.textTertiary)
                            .opacity(hovering && newSession != nil ? 0 : 1)
                    }
                }
                .frame(minWidth: newSession == nil ? 0 : Self.newSessionWidth, alignment: .trailing)
                Image(icon: "chevron.down")
                    .font(NookTheme.font(10, .semibold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: Self.chevronWidth)
            }
            .padding(.horizontal, Self.gap)
            .frame(height: 32)
            // The fill lifts in the frame the pointer arrives, as session rows do.
            .background {
                NookTheme.shape(NookTheme.Radius.chip).fill(hovering ? NookTheme.rowHover : .clear)
                    .transaction { $0.animation = nil }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .nookTip(project.isEmpty ? name : project)
        .accessibilityLabel(name)
        .accessibilityValue(open ? tr("compose.queue.expanded") : "")
    }

    private static func color(_ dot: InboxProjectGroup.Dot) -> Color {
        switch dot {
        case .needsYou: return NookTheme.amber
        case .failed: return NookTheme.coral
        case .done: return NookTheme.mint
        case .working: return NookTheme.blue
        }
    }

    private static func key(_ dot: InboxProjectGroup.Dot) -> String {
        switch dot {
        case .needsYou: return "needsYou"
        case .failed: return "failed"
        case .done: return "done"
        case .working: return "working"
        }
    }
}

/// What a project folder's menu can do with the folder on this Mac.
struct ProjectFolderActions {
    var pinned: Bool
    var archived: Bool
    var togglePin: () -> Void
    var copyPath: () -> Void
    var reveal: () -> Void
    var rename: () -> Void
    var settings: () -> Void
    var toggleArchive: () -> Void
}

/// Reads a row's session ahead of the click once the pointer has rested on it a moment (`AgentInboxList.restBeforePrefetch`),
/// so sweeping the pointer across the list starts no read per row it crosses. One for the whole list: only one row is
/// under the pointer at a time, and entering the next row cancels the wait on the last.
@MainActor
final class InboxHoverPrefetch {
    private var pending: Task<Void, Never>?
    private var rowID: String?

    func enter(_ id: String, after delay: Duration, _ work: @escaping @MainActor () -> Void) {
        pending?.cancel()
        rowID = id
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.rowID == id else { return }
            self.pending = nil
            self.rowID = nil
            work()
        }
    }

    func exit(_ id: String) {
        guard rowID == id else { return }
        pending?.cancel()
        pending = nil
        rowID = nil
    }
}

/// The field that renames a session in the list, over its row: it starts with the name selected, Return keeps the new
/// name (`done` with it) and Escape or leaving the field keeps the old one (`done` with nil).
private struct InboxRenameField: View {
    let name: String
    let done: (String?) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(tr("ws.title.placeholder"), text: $draft)
            .textFieldStyle(.plain)
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .focused($focused)
            .focusOnAppear($focused)
            .padding(.horizontal, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
            .roundedStroke(NookTheme.fieldStroke, radius: NookTheme.Radius.control)
            .onAppear { draft = name }
            .onSubmit {
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                done(trimmed.isEmpty || trimmed == name ? nil : trimmed)
            }
            .onExitCommand { done(nil) }
            .onChange(of: focused) { _, now in if !now { done(nil) } }
    }
}

private extension View {
    /// A session started from the row above it sits one step in, behind a turn arrow, as in Claude's own session list.
    @ViewBuilder
    func nested(_ depth: Int) -> some View {
        if depth > 0 {
            HStack(spacing: 0) {
                Image(icon: "arrow.turn.down.right")
                    .font(NookTheme.font(9.5, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: NookTheme.Spacing.xl)
                self
            }
            .padding(.leading, NookTheme.Spacing.md + CGFloat(depth - 1) * NookTheme.Spacing.xl)
        } else {
            self
        }
    }
}

/// The history's sessions by agent and id, for the rows of the session list: each row looked its session up in the whole
/// history, on every redraw of the list. Made again when the history is another array than last time.
@MainActor
final class PastSessionIndex {
    /// The history it was made from; held so its storage stays the same while nothing changes it.
    private var source: [PastSession] = []
    private var byKey: [String: PastSession] = [:]

    func session(agent: Substring, id: Substring, in sessions: [PastSession]) -> PastSession? {
        let same = sessions.withUnsafeBufferPointer { new in
            source.withUnsafeBufferPointer { old in new.baseAddress == old.baseAddress && new.count == old.count }
        }
        if !same {
            source = sessions
            byKey = [:]
            for past in sessions where byKey["\(past.agent.rawValue):\(past.sessionID)"] == nil {
                byKey["\(past.agent.rawValue):\(past.sessionID)"] = past
            }
        }
        return byKey["\(agent):\(id)"]
    }
}
