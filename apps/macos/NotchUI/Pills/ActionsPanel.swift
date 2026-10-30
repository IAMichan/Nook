import SwiftUI
import AppKit

/// A repository's GitHub Actions, next to the pull requests under the Agents list: every run of every workflow (CI,
/// Promote, Release…), newest first under a heading per day. On top the repository (the one you pushed to last until you
/// pick another, remembered), the state filter (all, running, failed) and a chip per workflow, so "did the promote go
/// through" is one click. A run opens beside the list when the page is wide enough, else in its place
/// (`WorkflowRunDetail`): its jobs, each job's steps and log, and re-run or cancel. While a run in sight still runs, the
/// list is read again every few seconds; otherwise every minute.
struct ActionsPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ActionsStore.shared
    @ObservedObject private var pullRequests = PullRequestStore.shared
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    @ObservedObject private var gitHubSignIn = GitHubSignIn.shared
    @State private var filter: WorkflowRunFilter = .all
    @State private var openRun: WorkflowRun?
    /// The field to type another repository in, in place of the picker.
    @State private var addingRepo = false
    @State private var repoText = ""
    @FocusState private var repoFieldFocused: Bool

    /// The side panel, as on the pull requests page: half the page at first, as wide as you drag it after.
    @AppStorage("nook.actions.panelWidth") private var panelWidth: Double = 0
    private static let splitWidth: CGFloat = 860
    private static let minimumPanel: Double = 360
    private static let minimumList: Double = 360

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
        }
        .onChange(of: store.repo) { _, _ in
            openRun = nil
            filter = .all
        }
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
                try? await Task.sleep(nanoseconds: store.hasActiveRuns ? 8_000_000_000 : 60_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.refresh() }
        }
        .onChange(of: gitHubSignIn.phase) { _, phase in
            if phase == .done { Task { await store.refreshRepositories() } }
        }
    }

    /// The repository, and the filters: the state on the same line, the workflows under it.
    private var toolbar: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if addingRepo {
                repoField
            } else {
                HStack(spacing: NookTheme.Spacing.sm) {
                    repoPicker
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if store.repo != nil {
                        ForEach(WorkflowRunFilter.allCases, id: \.self) { kind in
                            NookFilterChip(title: title(kind), count: kind == .all ? nil : count(kind), selected: filter == kind) {
                                filter = kind
                            }
                        }
                    }
                }
            }
            if store.repo != nil, !store.workflows.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        NookFilterChip(title: tr("actions.workflows.all"), selected: store.workflowID == nil) {
                            store.select(workflow: nil)
                        }
                        ForEach(store.workflows) { workflow in
                            NookFilterChip(title: workflow.name, selected: store.workflowID == workflow.id) {
                                store.select(workflow: workflow.id)
                            }
                            .help(workflow.path)
                        }
                    }
                }
            }
        }
    }

    private var candidates: [String] {
        let fromPullRequests = pullRequests.accounts.flatMap { $0.mine + $0.reviews + $0.watched }.map(\.repo)
        return WorkflowRunParser.candidates(selected: store.repo, pushed: store.added + store.pushed,
                                            pullRequests: fromPullRequests, watched: watching.entries)
    }

    private var repoPicker: some View {
        Menu {
            ForEach(candidates.prefix(30), id: \.self) { repo in
                Button {
                    store.select(repo)
                } label: {
                    if repo == store.repo { Label(repo, systemImage: "checkmark") } else { Text(repo) }
                }
            }
            if !candidates.isEmpty { Divider() }
            Button(tr("actions.repo.other")) {
                repoText = ""
                addingRepo = true
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "shippingbox")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                Text(store.repo ?? tr("actions.repo.pick"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(store.repo == nil ? NookTheme.textSecondary : NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // A long "owner/repository" leaves the filters beside it their room.
                    .frame(maxWidth: 200, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(NookTheme.font(9, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("actions.repo.help"))
    }

    /// "owner/repo" or a github.com link, typed in place of the picker.
    private var repoField: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            TextField(tr("actions.repo.placeholder"), text: $repoText)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.code)
                .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.field))
                .focused($repoFieldFocused)
                .onSubmit(addRepo)
                .onAppear { repoFieldFocused = true }
                .onExitCommand { addingRepo = false }
            SmallGhostButton(title: tr("actions.repo.open"), action: addRepo)
                .disabled(WorkflowRunParser.repository(from: repoText) == nil)
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 26) { addingRepo = false }
        }
    }

    private func addRepo() {
        if store.add(repoText) { addingRepo = false }
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
                            WorkflowRunRow(run: run, showWorkflow: store.workflowID == nil, selected: run.id == selected) {
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
                            Text(NookDates.ago(date)).fixedSize()
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
            .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
        .selectionMark(selected)
        .onHover { hovering = $0 }
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
