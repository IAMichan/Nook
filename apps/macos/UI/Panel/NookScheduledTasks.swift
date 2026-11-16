import SwiftUI

// Work Nook does on its own (`ScheduledTaskTarget.nook`), in the Nook tab: the "Scheduled" section at the top of the
// list, the bar over a task's own conversation, and the marker where a run asked its question. Every run of a task
// answers in that one conversation, so the list holds one Nook per task, not one per run.

/// What a scheduled task for Nook is doing, in one line: "Every day at 09:00 · next Tue 09:00", "Paused", "Running…".
@MainActor
enum NookTaskText {
    static func status(_ task: ScheduledTask, running: Bool, enabledGlobally: Bool) -> String {
        if running { return tr("nookTask.running") }
        if !enabledGlobally { return tr("nookTask.off") }
        if !task.enabled { return tr("nookTask.paused") }
        if task.isDone { return tr("automation.sched.done") }
        if let next = task.nextRun { return tr("nookTask.next", AgentFormat.upcoming(next)) }
        return ""
    }

    static func detail(_ task: ScheduledTask, running: Bool, enabledGlobally: Bool) -> String {
        let status = status(task, running: running, enabledGlobally: enabledGlobally)
        return [ScheduledTaskText.summary(task.rule), status].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The tint of the clock: Nook's own color while it will run, amber when it waits on you (off or paused).
    static func tint(_ task: ScheduledTask, running: Bool, enabledGlobally: Bool) -> Color {
        if running { return NookTheme.iris }
        if task.lastStatus == .failed { return NookTheme.coralSoft }
        return task.enabled && enabledGlobally && !task.isDone ? NookTheme.iris : NookTheme.textTertiary
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

// MARK: The list's section

/// "Scheduled" at the top of the Nook list: every task Nook runs on its own, with when it runs next. A click opens the
/// task's conversation (its runs); run now and pause sit on hover, the rest on right-click. Nothing shows while there
/// are no such tasks: Nook proposes one from the chat ("elke ochtend om 9:00…").
struct NookScheduledSection: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var settings = WorkspaceSettings.shared
    @State private var editing: NookTaskEdit?
    @State private var deleting: ScheduledTask?

    private var tasks: [ScheduledTask] { store.tasks.filter { $0.target.isNook } }

    var body: some View {
        let tasks = tasks
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    NookSectionLabel(tr("nookTask.section"))
                    Spacer(minLength: 0)
                    ToolbarIconButton("plus", tr("nookTask.new"), height: 20, width: 20) { editing = NookTaskEdit(task: nil) }
                        .padding(.trailing, NookTheme.Spacing.md)
                }
                .padding(.bottom, NookTheme.Spacing.xxs)
                if !settings.scheduledTasksEnabled { offNotice }
                ForEach(tasks) { task in
                    NookTaskRow(task: task, running: store.isRunning(task.id), enabledGlobally: settings.scheduledTasksEnabled,
                                selected: chat.active?.scheduledTaskID == task.id,
                                open: { open(task) },
                                toggle: { store.setEnabled(task.id, !task.enabled) })
                        .contextMenu { menu(task) }
                }
            }
            .padding(.bottom, NookTheme.Spacing.md)
            .animation(NookTheme.reveal, value: tasks.map(\.id))
            .nookTaskSheets(editing: $editing, deleting: $deleting)
        }
    }

    /// Scheduled tasks are switched off in Settings: nothing runs, and one click switches them on.
    private var offNotice: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "pause.circle")
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.amber)
            Text(tr("nookTask.offNotice"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: NookTheme.Spacing.sm)
            SmallGhostButton(title: tr("nookTask.turnOn")) { settings.scheduledTasksEnabled = true }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
        .padding(.bottom, NookTheme.Spacing.xs)
    }

    /// The task's conversation; before its first run there is none, so its editor opens instead.
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
            .disabled(!settings.scheduledTasksEnabled || store.isRunning(task.id))
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
    let enabledGlobally: Bool
    let selected: Bool
    let open: () -> Void
    let toggle: () -> Void
    @State private var hovering = false

    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear) }
    private var active: Bool { task.enabled && enabledGlobally && !task.isDone }

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
        .accessibilityLabel("\(task.title), \(NookTaskText.detail(task, running: running, enabledGlobally: enabledGlobally))")
    }

    private var content: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Group {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(icon: task.enabled ? "clock" : "pause.circle")
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTaskText.tint(task, running: running, enabledGlobally: enabledGlobally))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(task.title.isEmpty ? tr("sched.untitled") : task.title)
                    .font(active ? NookTheme.TextStyle.strong : NookTheme.TextStyle.body)
                    .foregroundStyle(active ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                Text(NookTaskText.detail(task, running: running, enabledGlobally: enabledGlobally))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if task.lastStatus == .failed, !running {
                NookTag(tr("nookTask.failed"), tint: NookTheme.coralSoft)
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
        HStack(spacing: 2) {
            ToolbarIconButton("play", tr("sched.runNow"), height: 22, width: 22) { NookTaskText.runNow(task) }
                .disabled(running || !enabledGlobally)
            ToolbarIconButton(task.enabled ? "pause" : "play.circle", tr(task.enabled ? "nookTask.pause" : "nookTask.resume"),
                              height: 22, width: 22, toggle)
        }
    }
}

// MARK: The conversation's bar

/// Over the conversation of a scheduled task: that Nook does this on its own, when, and how the last run went, with
/// run now, pause and edit at hand. A task that was removed leaves the conversation as an ordinary one.
struct NookTaskBar: View {
    let taskID: UUID
    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var settings = WorkspaceSettings.shared
    @State private var editing: NookTaskEdit?
    @State private var deleting: ScheduledTask?

    var body: some View {
        if let task = store.task(taskID) {
            let running = store.isRunning(task.id)
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: task.enabled ? "clock" : "pause.circle")
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTaskText.tint(task, running: running, enabledGlobally: settings.scheduledTasksEnabled))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("nookTask.bar.title"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                    Text(NookTaskText.detail(task, running: running, enabledGlobally: settings.scheduledTasksEnabled))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                if !settings.scheduledTasksEnabled {
                    SmallGhostButton(title: tr("nookTask.turnOn")) { settings.scheduledTasksEnabled = true }
                } else {
                    ToolbarIconButton("play", tr("sched.runNow"), height: 24, width: 24) { NookTaskText.runNow(task) }
                        .disabled(running)
                    ToolbarIconButton(task.enabled ? "pause" : "play.circle", tr(task.enabled ? "nookTask.pause" : "nookTask.resume"),
                                      height: 24, width: 24) { store.setEnabled(task.id, !task.enabled) }
                }
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
