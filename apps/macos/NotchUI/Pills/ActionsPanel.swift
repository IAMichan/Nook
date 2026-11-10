import SwiftUI
import AppKit

/// A repository's GitHub Actions, next to the pull requests under the Agents list: every run of every workflow (CI,
/// Promote, Release…), newest first under a heading per day. On top the repositories as tabs (`ActionsRepoBar`: the one
/// you pushed to last until you pick others, remembered, each tab marked when something runs or fails, and a "+" that
/// searches the rest), then the state filter (all, running, failed) and a chip per workflow with the mark of its newest
/// run, so "did the promote go through" is one click. A run opens beside the list when the page is wide enough, else in its place
/// (`WorkflowRunDetail`): its jobs, each job's steps and log, and re-run or cancel. While a run in sight still runs, the
/// list is read again every few seconds; otherwise every minute.
struct ActionsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ActionsStore.shared
    @ObservedObject private var pullRequests = PullRequestStore.shared
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    /// The state filter is kept while Nook runs, so a visit to another tab and back finds it as it was left.
    @State private var filter: WorkflowRunFilter = ActionsPanel.keptFilter
    @State private var openRun: WorkflowRun?

    /// The side panel, as on the pull requests page: half the page at first, as wide as you drag it after.
    @AppStorage("nook.actions.panelWidth") private var panelWidth: Double = 0
    private static let splitWidth: CGFloat = 860
    private static let minimumPanel: Double = 360
    private static let minimumList: Double = 360

    /// The state filter you left in the list (not kept across a restart).
    static var keptFilter: WorkflowRunFilter = .all

    var body: some View {
        GeometryReader { geometry in
            let total = Double(geometry.size.width)
            let split = geometry.size.width >= Self.splitWidth
            Group {
                if let run = openRun, let repo = store.repo, split {
                    HStack(alignment: .top, spacing: 0) {
                        list(selected: run.id)
                            .frame(maxWidth: .infinity)
                        WorkflowRunDetail(repo: repo, run: run, onClose: { openRun = nil })
                            .id(run.id)
                            .sidePanel(.trailing, width: panelWidthBinding(total), defaultWidth: (total / 2).rounded(),
                                       minimum: Self.minimumPanel, available: total,
                                       rest: max(Self.minimumList, total * 0.3) + PanelSplit.handle)
                    }
                } else if let run = openRun, let repo = store.repo {
                    WorkflowRunDetail(repo: repo, run: run, onClose: { openRun = nil })
                        .id(run.id)
                } else {
                    list(selected: nil)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // A run opens beside the list, and closes, at once.
            .sidePanelsOpenAtOnce(openRun?.id)
        }
        .onChange(of: store.repo) { _, _ in
            openRun = nil
            filter = .all
        }
        .onChange(of: filter) { _, value in ActionsPanel.keptFilter = value }
        // The open run follows the list: its row and its page say the same.
        .onChange(of: store.runs) { _, runs in
            if let open = openRun, let fresh = runs.first(where: { $0.id == open.id }), fresh != open { openRun = fresh }
        }
    }

    private func panelWidthBinding(_ total: Double) -> Binding<Double> {
        Binding(get: { panelWidth > 0 ? panelWidth : (total / 2).rounded() }, set: { panelWidth = $0 })
    }

    // MARK: List

    private func list(selected: Int?) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            PanelListHeader(tr("actions.title")) {
                // The list's own skeleton shows a first read; only a later one is a time here.
                if let read = store.lastRead {
                    PullRequestFreshness(date: read)
                }
                if let repo = store.repo, let url = URL(string: "https://github.com/\(repo)/actions") {
                    NookIconButton(systemName: "arrow.up.right.square", label: tr("actions.openOnGitHub"), size: 28) {
                        NSWorkspace.shared.open(url)
                    }
                }
                NookIconButton(systemName: "arrow.clockwise", label: tr("actions.refresh"), size: 28) {
                    Task { await store.refresh() }
                }
                .disabled(store.repo == nil)
            }

            if !store.available {
                WSEmptyState(symbol: "person.crop.circle.badge.plus", title: tr("agents.pulls.notConnected"),
                             message: tr("actions.notConnectedDetail"),
                             action: (title: tr("agents.pulls.connect"), run: { app.openSettings(section: .connections) }))
            } else {
                toolbar
                if store.repo == nil && !store.repositoriesLoaded {
                    // The repository you pushed to last is on its way.
                    WorkflowRunGhostList()
                } else if store.repo == nil {
                    WSEmptyState(symbol: "play.circle", title: tr("actions.pickRepo"), message: tr("actions.pickRepoDetail"))
                } else {
                    content(selected: selected)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Every few seconds while something runs, so a promote or a CI run is followed live; else every minute.
        .task(id: (store.repo ?? "") + "|" + String(store.workflowID ?? 0)) {
            await store.refreshRepositories()
            while !Task.isCancelled {
                await store.refresh()
                // The other tabs after the open one, so each says how it stands and opens at once.
                Task { await store.peekRecent() }
                try? await Task.sleep(nanoseconds: store.hasActiveRuns ? 8_000_000_000 : 60_000_000_000)
            }
        }
        // ⇧⌘[ and ⇧⌘] go to the repository tab on the left or right, as they go through the chats on Chats.
        .keyCommands(["session.previous": { store.selectNeighbor(-1); return true },
                      "session.next": { store.selectNeighbor(1); return true }],
                     enabled: store.recent.count > 1)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            if phase == .done { Task { await store.refreshRepositories() } }
        }
    }

    /// The repositories as tabs, and under them the filters: the state, then a chip per workflow.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ActionsRepoBar(store: store, candidates: candidates)
            if store.repo != nil {
                NookDivider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ForEach(WorkflowRunFilter.allCases, id: \.self) { kind in
                            NookFilterChip(title: title(kind), count: kind == .all ? nil : count(kind), selected: filter == kind) {
                                filter = kind
                            }
                        }
                        if !store.workflows.isEmpty {
                            NookDivider(vertical: true)
                                .frame(height: 16)
                                .padding(.horizontal, NookTheme.Spacing.xs)
                            NookFilterChip(title: tr("actions.workflows.all"), selected: store.workflowID == nil) {
                                store.select(workflow: nil)
                            }
                            let latest = WorkflowRunParser.latestPerWorkflow(store.runs)
                            ForEach(store.workflows) { workflow in
                                NookFilterChip(title: workflow.name, selected: store.workflowID == workflow.id,
                                               mark: latest[workflow.id].map { (outcome: $0.outcome, running: $0.running) }) {
                                    store.select(workflow: workflow.id)
                                }
                                .help(workflow.path)
                            }
                        }
                    }
                }
            }
        }
    }

    /// What the repository picker offers besides the tabs: those you pushed to, typed in, of your pull requests, watched.
    private var candidates: [String] {
        let fromPullRequests = pullRequests.accounts.flatMap { $0.mine + $0.reviews + $0.watched }.map(\.repo)
        return WorkflowRunParser.candidates(selected: nil, pushed: store.added + store.pushed,
                                            pullRequests: fromPullRequests, watched: watching.entries)
    }

    private func title(_ kind: WorkflowRunFilter) -> String {
        switch kind {
        case .all: return tr("actions.filter.all")
        case .active: return tr("actions.filter.active")
        case .failed: return tr("actions.filter.failed")
        }
    }

    private func count(_ kind: WorkflowRunFilter) -> Int { store.runs.filter(kind.matches).count }

    @ViewBuilder
    private func content(selected: Int?) -> some View {
        let shown = store.runs.filter(filter.matches)
        if let error = store.error, store.runs.isEmpty {
            WSEmptyState(symbol: "exclamationmark.triangle", title: tr("actions.error"), message: error,
                         action: (title: tr("actions.refresh"), run: { Task { await store.refresh() } }))
        } else if !store.loaded {
            WorkflowRunGhostList()
        } else if store.runs.isEmpty {
            WSEmptyState(symbol: "play.circle", title: tr("actions.none"), message: tr("actions.noneDetail"))
        } else if shown.isEmpty {
            WSEmptyState(symbol: "line.3.horizontal.decrease.circle", title: tr("actions.noMatch"), message: "",
                         action: (title: tr("agents.pulls.clearFilter"), run: { filter = .all }))
        } else {
            // The times on the rows move on with the clock, as on the Agents list.
            TimelineView(.nookTicks(every: 30)) { context in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    if let error = store.error {
                        Text(error)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.coralSoft)
                            .padding(.horizontal, NookTheme.Spacing.xs)
                            .padding(.bottom, NookTheme.Spacing.sm)
                    }
                    ForEach(Self.days(shown)) { group in
                        NookSectionLabel(Self.dayTitle(group.day))
                            .padding(.top, NookTheme.Spacing.md)
                            .padding(.bottom, NookTheme.Spacing.xs)
                        ForEach(group.runs) { run in
                            WorkflowRunRow(run: run, showWorkflow: store.workflowID == nil, selected: run.id == selected,
                                           now: context.date) {
                                openRun = run
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, NookTheme.Spacing.lg)
            }
            }
        }
    }

    private struct RunDay: Identifiable {
        let day: Date
        var runs: [WorkflowRun]
        var id: Date { day }
    }

    /// The runs under the day they started, in the order of the list.
    private static func days(_ runs: [WorkflowRun]) -> [RunDay] {
        var result: [RunDay] = []
        for run in runs {
            let day = WorkflowRunParser.day(of: run) ?? .distantPast
            if result.last?.day == day {
                result[result.count - 1].runs.append(run)
            } else {
                result.append(RunDay(day: day, runs: [run]))
            }
        }
        return result
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return tr("actions.day.today") }
        if calendar.isDateInYesterday(day) { return tr("actions.day.yesterday") }
        if day == .distantPast { return "" }
        return NookDates.formatter("EEEE d MMMM", locale: I18n.shared.language.rawValue).string(from: day)
    }
}

/// One run in the list: its mark (turning while it runs), what it is about, and under it the workflow and number, the
/// branch, what started it and who; on the right how it went with its clock, and when.
struct WorkflowRunRow: View {
    let run: WorkflowRun
    /// The workflow is named on the row unless the list shows only that one.
    let showWorkflow: Bool
    var selected = false
    /// The clock the row's time is counted against (the list's tick), so the time moves on while the list is open.
    var now = Date()
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                CheckOutcomeGlyph(outcome: run.outcome, size: 14, running: run.running)
                    .frame(width: 16)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(run.title)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        CICheckStatusText(check: run.check)
                            .fixedSize()
                    }
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Text(WorkflowRunWords.context(run, showWorkflow: showWorkflow))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        if let date = run.created {
                            Text(NookDates.ago(date, now: now)).fixedSize()
                        }
                    }
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .roundedBackground(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear), radius: NookTheme.Radius.control)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(run.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if let url = run.url {
                Button(tr("actions.openOnGitHub")) { NSWorkspace.shared.open(url) }
                Button(tr("agents.pr.copyLink")) {
                    Pasteboard.copy(url.absoluteString)
                    ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                }
            }
            if !run.branch.isEmpty {
                Button(tr("agents.pr.copyBranch")) {
                    Pasteboard.copy(run.branch)
                    ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
                }
            }
        }
    }
}

/// The list's shape while its first runs are on their way: a day's heading and rows shaped like `WorkflowRunRow`
/// (mark, title and status, then the line under it with the time), so the page does not jump when they come in.
struct WorkflowRunGhostList: View {
    /// Title widths, so the rows do not look like one stamp repeated.
    private static let titles: [CGFloat] = [220, 170, 250, 140, 200, 180]

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            PullRequestGhostBar(width: 64, height: 9)
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.top, NookTheme.Spacing.md)
                .padding(.bottom, NookTheme.Spacing.sm)
            ForEach(Array(Self.titles.enumerated()), id: \.offset) { _, width in
                WorkflowRunGhostRow(title: width)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("actions.loading"))
    }
}

/// One placeholder row: the run's mark, its title with the status at the end, and the line under it with the time.
struct WorkflowRunGhostRow: View {
    var title: CGFloat = 200

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Circle().fill(NookTheme.rowHover).frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    PullRequestGhostBar(width: title, height: 10)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    PullRequestGhostBar(width: 72, height: 8)
                }
                HStack(spacing: NookTheme.Spacing.sm) {
                    PullRequestGhostBar(width: title * 0.7, height: 7)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    PullRequestGhostBar(width: 48, height: 7)
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm + 1)
    }
}

/// How a run is put in words, the same on its row and its page.
enum WorkflowRunWords {
    /// What started a run: "Push", "Pull request", "Manual", "Scheduled", "Release"; another event in GitHub's words.
    static func event(_ event: String) -> String {
        switch event {
        case "push": return tr("actions.event.push")
        case "pull_request", "pull_request_target": return tr("actions.event.pullRequest")
        case "workflow_dispatch": return tr("actions.event.manual")
        case "schedule": return tr("actions.event.schedule")
        case "release": return tr("actions.event.release")
        case "workflow_run", "workflow_call": return tr("actions.event.workflow")
        default: return event.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "CI #482 · main · Push · @ada".
    static func context(_ run: WorkflowRun, showWorkflow: Bool) -> String {
        let number = "#\(run.number)" + (run.attempt > 1 ? " (\(tr("actions.attempt", run.attempt)))" : "")
        return [showWorkflow ? run.name + " " + number : number, run.branch, event(run.event),
                run.actor.isEmpty ? "" : "@" + run.actor]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
