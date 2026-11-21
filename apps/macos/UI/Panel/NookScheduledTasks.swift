import SwiftUI

// Work Nook does on its own (`ScheduledTaskTarget.nook`), in the Nook tab: the Scheduled tab of the list, the bar over
// a run's conversation, and the marker where a run asked its question.

/// What a scheduled task for Nook is doing, in one line: "Every day at 09:00 · next Tue 09:00", "Paused", "Running…".
@MainActor
enum NookTaskText {
    static func status(_ task: ScheduledTask, running: Bool) -> String {
        if running { return tr("nookTask.running") }
        if !task.enabled { return tr("nookTask.paused") }
        if task.isDone { return tr("automation.sched.done") }
        if let next = task.nextRun { return tr("nookTask.next", AgentFormat.upcoming(next)) }
        return ""
    }

    static func detail(_ task: ScheduledTask, running: Bool) -> String {
        let status = status(task, running: running)
        // A task that acts by itself says so, so the list shows at a glance which ones do not wait for you.
        let autonomy = ScheduledTaskStore.shared.autonomy(for: task.id)
        let acts = autonomy == .ask ? "" : autonomy.label
        return [ScheduledTaskText.summary(task.rule), acts, status].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The tint of the clock: Nook's own color while it will run, coral after a failed run, grey when paused or done.
    static func tint(_ task: ScheduledTask, running: Bool) -> Color {
        if running { return NookTheme.iris }
        if task.lastStatus == .failed { return NookTheme.coralSoft }
        return task.enabled && !task.isDone ? NookTheme.iris : NookTheme.textTertiary
    }

    /// "Run now" with the result as a toast, as Settings does it.
    static func runNow(_ task: ScheduledTask) {
        switch ScheduledTaskStore.shared.runNow(task.id) {
        case .started: ToastCenter.shared.success(tr("sched.started", task.title))
        case .busy: ToastCenter.shared.warning(tr("sched.busy", task.title))
        case .notAvailable: ToastCenter.shared.warning(tr("sched.disabledGlobal"))
        }
    }
}

/// Editing and removing a task for Nook from the Nook tab: the editor Settings uses (with Nook as the destination) and
/// the one confirmation for what cannot be undone.
private struct NookTaskSheets: ViewModifier {
    @EnvironmentObject private var app: AppModel
    @Binding var editing: NookTaskEdit?
    @Binding var deleting: ScheduledTask?

    func body(content: Content) -> some View {
        content
            .sheet(item: $editing) { edit in
                ScheduledTaskEditor(existing: edit.task, forNook: true) { editing = nil }
                    .environmentObject(app)
            }
            .confirmDelete($deleting, question: { tr("sched.delete.confirm", $0.title) }, detail: tr("nookTask.delete.detail"),
                           confirmTitle: tr("sched.delete")) { task in
                ScheduledTaskStore.shared.delete(task.id)
            }
    }
}

/// A task to edit, or nil for a new one.
struct NookTaskEdit: Identifiable {
    let id = UUID()
    var task: ScheduledTask?
}

extension View {
    func nookTaskSheets(editing: Binding<NookTaskEdit?>, deleting: Binding<ScheduledTask?>) -> some View {
        modifier(NookTaskSheets(editing: editing, deleting: deleting))
    }
}

// MARK: The list's tab

/// The Scheduled tab of the Nook list: every task Nook runs on its own, with when it runs next. Tasks that will run come
/// first, paused and finished ones after them under a label of their own, so a long list stays easy to read. A click
/// opens the conversation of its latest run; run now and pause sit on hover, the rest on right-click. The list's search
/// filters the tasks by name and by what they ask. With no task yet, the tab says what it is for and offers the first.
struct NookScheduledList: View {
    @ObservedObject var chat: NookChat
    let query: String
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ScheduledTaskStore.shared
    @State private var editing: NookTaskEdit?
    @State private var deleting: ScheduledTask?

    /// Nook's tasks that match the search, the next to run first.
    private var tasks: [ScheduledTask] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.tasks
            .filter { $0.target.isNook }
            .filter { needle.isEmpty || $0.title.localizedCaseInsensitiveContains(needle)
                || $0.prompt.localizedCaseInsensitiveContains(needle) }
            .sorted { ($0.nextRun ?? .distantFuture, $0.title) < ($1.nextRun ?? .distantFuture, $1.title) }
    }

    var body: some View {
        let tasks = tasks
        let active = tasks.filter { $0.enabled && !$0.isDone }
        let resting = tasks.filter { !$0.enabled || $0.isDone }
        Group {
            if tasks.isEmpty && query.isEmpty {
                WSEmptyState(symbol: "clock", title: tr("nookTask.none"), message: tr("nookTask.none.detail"),
                             action: (tr("nookTask.add"), { editing = NookTaskEdit(task: nil) }))
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        NookSectionLabel(tr("nookTask.count", tasks.count))
                        Spacer(minLength: 0)
                        ToolbarIconButton("plus", tr("nookTask.new"), height: 20, width: 20) { editing = NookTaskEdit(task: nil) }
                            .padding(.trailing, NookTheme.Spacing.md)
                    }
                    .padding(.bottom, NookTheme.Spacing.xxs)
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            if tasks.isEmpty {
                                ListEmptyNote(tr("nooks.noMatches"), padding: NookTheme.Spacing.lg)
                            }
                            rows(active)
                            if !resting.isEmpty {
                                NookSectionLabel(tr("nookTask.section.resting"))
                                    .padding(.top, active.isEmpty ? 0 : NookTheme.Spacing.md)
                                    .padding(.bottom, NookTheme.Spacing.xxs)
                                rows(resting)
                            }
                        }
                        .animation(NookTheme.reveal, value: tasks.map(\.id))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .nookTaskSheets(editing: $editing, deleting: $deleting)
    }

    @ViewBuilder
    private func rows(_ tasks: [ScheduledTask]) -> some View {
        ForEach(tasks) { task in
            NookTaskRow(task: task, running: store.isRunning(task.id),
                        selected: chat.active?.scheduledTaskID == task.id,
                        runStatus: chat.conversation(forTask: task.id)?.status ?? .idle,
                        open: { open(task) },
                        toggle: { store.setEnabled(task.id, !task.enabled) })
                .contextMenu { menu(task) }
        }
    }

    /// The conversation of the task's latest run; before its first run there is none, so its editor opens instead.
    private func open(_ task: ScheduledTask) {
        if let conversation = chat.conversation(forTask: task.id) {
            app.openConversation(conversation.id)
        } else {
            editing = NookTaskEdit(task: task)
        }
    }

    @ViewBuilder
    private func menu(_ task: ScheduledTask) -> some View {
        if let conversation = chat.conversation(forTask: task.id) {
            Button(tr("nookTask.openRuns")) { app.openConversation(conversation.id) }
        }
        Button(tr("sched.runNow")) { NookTaskText.runNow(task) }
            .disabled(store.isRunning(task.id))
        Button(tr(task.enabled ? "nookTask.pause" : "nookTask.resume")) { store.setEnabled(task.id, !task.enabled) }
        Button(tr("sched.edit")) { editing = NookTaskEdit(task: task) }
        Divider()
        Button(tr("sched.delete"), role: .destructive) { deleting = task }
    }
}

/// One task for Nook in the list, built like a Nook row: the clock in Nook's color, the title, and what it does when.
/// Run now and pause appear on hover in the trailing slot, so nothing shifts.
private struct NookTaskRow: View {
    let task: ScheduledTask
    let running: Bool
    let selected: Bool
    /// Where its latest run's conversation stands: waiting for your approval or with an answer you have not read shows
    /// the same badge a Nook row has.
    var runStatus: Conversation.Status = .idle
    let open: () -> Void
    let toggle: () -> Void
    @State private var hovering = false

    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear) }
    private var active: Bool { task.enabled && !task.isDone }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: open) { content }
                .buttonStyle(.nookPlain)
            actions
                .rowActionsBackdrop(background)
                .padding(.trailing, NookTheme.Spacing.md)
                .revealOnHover(hovering)
        }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title), \(NookTaskText.detail(task, running: running))")
    }

    private var content: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Group {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(icon: task.enabled ? "clock" : "pause.circle")
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTaskText.tint(task, running: running))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(task.title.isEmpty ? tr("sched.untitled") : task.title)
                    .font(active ? NookTheme.TextStyle.strong : NookTheme.TextStyle.body)
                    .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                Text(NookTaskText.detail(task, running: running))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if task.lastStatus == .failed, !running {
                NookTag(tr("nookTask.failed"), tint: NookTheme.coralSoft)
                    .opacity(hovering ? 0 : 1)
            } else if !running, runStatus == .waiting || runStatus == .unread {
                AgentStatusBadge(state: runStatus == .waiting ? .approval : .ready)
                    .opacity(hovering ? 0 : 1)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(background, radius: NookTheme.Radius.card)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ToolbarIconButton("play", tr("sched.runNow"), height: 22, width: 22) { NookTaskText.runNow(task) }
                .disabled(running)
            ToolbarIconButton(task.enabled ? "pause" : "play.circle", tr(task.enabled ? "nookTask.pause" : "nookTask.resume"),
                              height: 22, width: 22, toggle)
        }
    }
}

// MARK: The conversation's bar

/// Over the conversation of a scheduled run: that Nook does this on its own, when it runs next, with run now, pause and
/// edit at hand. A task that was removed leaves the conversation as an ordinary one.
struct NookTaskBar: View {
    let taskID: UUID
    @ObservedObject private var store = ScheduledTaskStore.shared
    @State private var editing: NookTaskEdit?
    @State private var deleting: ScheduledTask?

    var body: some View {
        if let task = store.task(taskID) {
            let running = store.isRunning(task.id)
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: task.enabled ? "clock" : "pause.circle")
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTaskText.tint(task, running: running))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("nookTask.bar.title"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                    Text(NookTaskText.detail(task, running: running))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                ToolbarIconButton("play", tr("sched.runNow"), height: 24, width: 24) { NookTaskText.runNow(task) }
                    .disabled(running)
                ToolbarIconButton(task.enabled ? "pause" : "play.circle", tr(task.enabled ? "nookTask.pause" : "nookTask.resume"),
                                  height: 24, width: 24) { store.setEnabled(task.id, !task.enabled) }
                Menu {
                    Button(tr("sched.edit")) { editing = NookTaskEdit(task: task) }
                    Divider()
                    Button(tr("sched.delete"), role: .destructive) { deleting = task }
                } label: {
                    Image(icon: "ellipsis")
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .nookMenuButton()
                .accessibilityLabel(tr("nookTask.more"))
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.sm)
            .panelCard()
            .nookTaskSheets(editing: $editing, deleting: $deleting)
        }
    }
}

// MARK: A run in the conversation

/// Where a run asked its question: a quiet line with the time instead of a bubble you did not type, with the question
/// itself one click away.
struct ScheduledRunMarker: View {
    let text: String
    let date: Date
    @State private var expanded = false

    var body: some View {
        VStack(spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { expanded.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    NookDivider()
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Image(icon: "clock")
                        Text(tr("nookTask.run", NookDates.dayAndClock(date)))
                        DisclosureChevron(open: expanded, size: 7.5)
                    }
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize()
                    NookDivider()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .accessibilityLabel(tr("nookTask.run", NookDates.dayAndClock(date)))
            .accessibilityValue(expanded ? tr("compose.queue.expanded") : "")
            if expanded {
                Text(text)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NookTheme.Spacing.md)
                    .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
            }
        }
        .padding(.vertical, NookTheme.Spacing.xs)
    }
}

// MARK: A session's tasks

/// The scheduled tasks that run in this session (`ScheduledTaskTarget.existingSession`), in the tray above its composer
/// beside its pull requests: what it will do by itself, and when. A click opens the editor; run now, pause and remove sit
/// on hover and right-click. While agent tasks are off in Settings, an enabled one says it will not run and offers the
/// switch, so a task an agent planned for tomorrow never silently does nothing.
struct SessionScheduledTaskRow: View {
    let task: ScheduledTask
    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var settings = WorkspaceSettings.shared
    @State private var hovering = false
    @State private var editing: NookTaskEdit?
    @State private var deleting: ScheduledTask?

    /// The tasks that go to this session, the next to run first.
    static func tasks(for runID: UUID, in tasks: [ScheduledTask]) -> [ScheduledTask] {
        tasks.filter { $0.target.sessionID == runID }
            .sorted { ($0.nextRun ?? .distantFuture, $0.title) < ($1.nextRun ?? .distantFuture, $1.title) }
    }

    private var running: Bool { store.isRunning(task.id) }
    /// Enabled and still to run, but held back because agent tasks are off.
    private var heldBack: Bool { task.enabled && !task.isDone && !store.mayRun(task) }

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Group {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(icon: task.enabled ? "clock" : "pause.circle")
                        .font(NookTheme.font(11, .medium))
                        .foregroundStyle(heldBack ? NookTheme.amber : NookTaskText.tint(task, running: running))
                }
            }
            .frame(width: 14)
            .padding(.leading, 5)
            Text(task.title.isEmpty ? tr("sched.untitled") : task.title)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(task.enabled && !task.isDone ? NookTheme.textStrong : NookTheme.textSecondary)
                .truncationMode(.tail)
                .nookTipWhenCut(task.title)
            Spacer(minLength: NookTheme.Spacing.sm)
            trailing
        }
        .padding(.leading, NookTheme.Spacing.xs)
        .frame(minHeight: 26)
        .hoverRowFill($hovering, radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
        .nookClickable()
        .onTapGesture { editing = NookTaskEdit(task: task) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(task.title), \(status)")
        .accessibilityHint(tr("sessionTask.help"))
        .accessibilityAction(named: tr("sched.edit")) { editing = NookTaskEdit(task: task) }
        .contextMenu { menu }
        .animation(NookTheme.hover, value: hovering)
        .nookTaskSheets(editing: $editing, deleting: $deleting)
    }

    /// What it does when, or why it will not; on hover the actions take that place.
    @ViewBuilder
    private var trailing: some View {
        if hovering {
            HStack(spacing: NookTheme.Spacing.xxs) {
                ToolbarIconButton("play", tr("sched.runNow"), height: 22, width: 22) { NookTaskText.runNow(task) }
                    .disabled(running || !store.mayRun(task))
                ToolbarIconButton(task.enabled ? "pause" : "play.circle", tr(task.enabled ? "nookTask.pause" : "nookTask.resume"),
                                  height: 22, width: 22) { store.setEnabled(task.id, !task.enabled) }
                ToolbarIconButton("trash", tr("sched.delete"), height: 22, width: 22) { deleting = task }
            }
        } else if heldBack {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("sessionTask.off"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.amber)
                    .lineLimit(1)
                    .fixedSize()
                Button(tr("sessionTask.turnOn")) { settings.scheduledTasksEnabled = true }
                    .buttonStyle(.nookPlain)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.iris)
                    .fixedSize()
            }
        } else if task.lastStatus == .failed, !running {
            NookTag(tr("nookTask.failed"), tint: NookTheme.coralSoft)
        } else {
            Text(status)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// "Every day at 09:00 · next Sun 17:00"; for a once-task only its moment, as the rule already says it.
    private var status: String {
        let state = NookTaskText.status(task, running: running)
        if task.rule.isOnce, task.enabled, !task.isDone, !running { return ScheduledTaskText.summary(task.rule) }
        return [ScheduledTaskText.summary(task.rule), state].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var menu: some View {
        Button(tr("sched.runNow")) { NookTaskText.runNow(task) }
            .disabled(running || !store.mayRun(task))
        Button(tr(task.enabled ? "nookTask.pause" : "nookTask.resume")) { store.setEnabled(task.id, !task.enabled) }
        Button(tr("sched.edit")) { editing = NookTaskEdit(task: task) }
        Divider()
        Button(tr("sched.delete"), role: .destructive) { deleting = task }
    }
}
