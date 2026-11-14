import SwiftUI

/// What the agent does besides talking, in one card above the composer: its task list, the subagents it started and the
/// commands it left running in the background. Three kinds of work used to be three cards of the same shape stacked on
/// top of each other; now they are tabs of one dock.
///
/// - One kind: a single line, as before ("Subagents  Auditing the chats  1 of 3 done"), opening to its list.
/// - More kinds: a row of tabs ("Tasks 1/5 · Subagents 2/4 · Background 6/8") with under it the one thing worth a look now
///   (`Lead`): what still runs first, then what failed. A tab opens its list in the same card; the chosen tab again
///   closes it.
///
/// Every coding agent gets it the same way: it only reads `RunTaskStep`, `SubagentInfo` and `BackgroundCommandInfo`.
///
/// Each background command is also a call in the conversation (with a `BackgroundCommandLink` under it): `focus` set from
/// there opens the Background tab at its row and lights it up, and a row's `reveal` goes back to its call.
struct AgentActivityDock: View {
    enum Kind: Hashable { case tasks, subagents, commands }

    var tasks: [RunTaskStep] = []
    /// The agent works now: the task step it is on shimmers.
    var working = false
    var subagents: [SubagentInfo] = []
    /// Stops one subagent at work in the background, for an agent that can (`ProviderCapabilities.stopsOneSubagent`).
    var stopSubagent: ((SubagentInfo) -> Void)? = nil
    var commands: [BackgroundCommandInfo] = []
    var focus: Binding<UUID?> = .constant(nil)
    var reveal: ((UUID) -> Void)? = nil
    /// Shows the subagents and background commands in the side panel; nil when the panel is busy with something else.
    var openPanel: (() -> Void)? = nil
    /// The session's agent processes: with them each running command says whether it still works.
    var agentPIDs: (() -> [Int32])? = nil
    /// Settles a running command whose processes have been gone a while (`BackgroundCommandProbe.ended`): its agent never
    /// said it ended, and without this its row would spin on.
    var settleGone: ((UUID) -> Void)? = nil

    @State private var open = false
    @State private var chosen: Kind?
    @State private var shownCommand: UUID?
    @State private var flashed: UUID?
    @State private var activity: [UUID: BackgroundCommandActivity] = [:]

    var body: some View {
        let kinds = Self.kinds(tasks: tasks, subagents: subagents, commands: commands)
        let lead = Self.lead(tasks: tasks, working: working, subagents: subagents, commands: commands)
        let current = chosen.flatMap { kinds.contains($0) ? $0 : nil } ?? lead ?? kinds.first ?? .tasks
        if kinds.count == 1 {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                singleHeader(current)
                if open { list(current) }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, 7)
            .modifier(DockCard(watchKey: watchKey, watch: watch, focus: focus, opened: opened))
        } else if !kinds.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                tabs(kinds, current: current)
                NookDivider()
                Group {
                    if open {
                        list(current).padding(.vertical, NookTheme.Spacing.sm)
                    } else {
                        leadLine(lead ?? current).padding(.vertical, NookTheme.Spacing.sm - 1)
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.lg)
            }
            .modifier(DockCard(watchKey: watchKey, watch: watch, focus: focus, opened: opened))
        }
    }

    // MARK: - What it shows

    /// The kinds of work there are, in the order of their tabs.
    static func kinds(tasks: [RunTaskStep], subagents: [SubagentInfo], commands: [BackgroundCommandInfo]) -> [Kind] {
        var kinds: [Kind] = []
        if !tasks.isEmpty { kinds.append(.tasks) }
        if !subagents.isEmpty { kinds.append(.subagents) }
        if !commands.isEmpty { kinds.append(.commands) }
        return kinds
    }

    /// The kind whose item is worth a look now: a command that runs (it keeps the session busy and may hang), a subagent
    /// at work, the task step the agent is on; then what failed; then a task list not yet done. Nil without any work.
    static func lead(tasks: [RunTaskStep], working: Bool, subagents: [SubagentInfo], commands: [BackgroundCommandInfo]) -> Kind? {
        if commands.contains(where: \.isRunning) { return .commands }
        if subagents.contains(where: \.isRunning) { return .subagents }
        if !tasks.isEmpty, TaskChecklist.isRunning(tasks, active: working) { return .tasks }
        if commands.contains(where: \.failed) { return .commands }
        if subagents.contains(where: \.failed) { return .subagents }
        if !tasks.isEmpty, !RunTasks.isFinished(tasks) { return .tasks }
        return kinds(tasks: tasks, subagents: subagents, commands: commands).last
    }

    /// The subagent a line names: the first still at work, else the last that failed, else the last.
    private var leadSubagent: SubagentInfo? {
        subagents.first(where: \.isRunning) ?? subagents.last(where: \.failed) ?? subagents.last
    }

    /// The command a line names: the newest still running, else the last that failed, else the last.
    private var leadCommand: BackgroundCommandInfo? {
        commands.last(where: \.isRunning) ?? commands.last(where: \.failed) ?? commands.last
    }

    /// The line names something that failed itself (in coral), so a count beside it says nothing more.
    private func leadFailed(_ kind: Kind) -> Bool {
        switch kind {
        case .tasks: return false
        case .subagents: return leadSubagent.map { $0.failed && !$0.isRunning } ?? false
        case .commands: return leadCommand.map { $0.failed && !$0.isRunning } ?? false
        }
    }

    private var failedCount: Int { commands.filter(\.failed).count + subagents.filter(\.failed).count }

    private func counts(_ kind: Kind) -> (done: Int, total: Int, failed: Int) {
        switch kind {
        case .tasks:
            let progress = RunTasks.progress(tasks)
            return (progress.done, progress.total, 0)
        case .subagents:
            return (subagents.count(where: { !$0.isRunning }), subagents.count, subagents.filter(\.failed).count)
        case .commands:
            return (commands.count(where: { !$0.isRunning }), commands.count, commands.filter(\.failed).count)
        }
    }

    private func running(_ kind: Kind) -> Bool {
        switch kind {
        case .tasks: return false  // the shimmering step says it; a spinner beside it said it twice
        case .subagents: return subagents.contains(where: \.isRunning)
        case .commands: return commands.contains(where: \.isRunning)
        }
    }

    private func title(_ kind: Kind, short: Bool) -> String {
        switch kind {
        case .tasks: return tr("ws.tasks.title")
        case .subagents: return tr("ws.subagents.title")
        case .commands: return tr(short ? "ws.background.tab" : "ws.background.title")
        }
    }

    private func symbol(_ kind: Kind) -> String {
        switch kind {
        case .tasks: return "checklist"
        case .subagents: return "person.2"
        case .commands: return "terminal"
        }
    }

    @ViewBuilder
    private func mark(_ kind: Kind) -> some View {
        if running(kind) {
            ProgressView().controlSize(.mini).frame(width: 12)
        } else {
            Image(icon: symbol(kind)).font(NookTheme.font(11, .semibold)).frame(width: 12)
        }
    }

    // MARK: - One kind

    private func singleHeader(_ kind: Kind) -> some View {
        let count = counts(kind)
        return HStack(spacing: NookTheme.Spacing.md) {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    mark(kind)
                    Text(title(kind, short: false)).foregroundStyle(NookTheme.textTertiary)
                    headline(kind, detailedActivity: false)
                    Spacer(minLength: 6)
                    if count.failed > 0 {
                        Text(tr("ws.background.failedCount", count.failed))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.coralSoft)
                            .fixedSize()
                    }
                    if kind == .tasks {
                        Text("\(count.done)/\(count.total)")
                            .font(NookTheme.mono(11, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                    } else {
                        // "2 of 4 done" alone: the spinner already says that some run.
                        Text(tr("ws.subagents.progress", count.done, count.total))
                            .font(NookTheme.TextStyle.detail.monospacedDigit())
                            .foregroundStyle(NookTheme.textSecondary)
                            .fixedSize()
                    }
                    segments(kind)
                    DisclosureChevron(open: open, size: 8.5, style: .upward)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .accessibilityLabel(accessibility(kind))
            panelButton(kind)
        }
    }

    /// One short bar per step or subagent: lit while it runs, mint once done, coral when it failed.
    @ViewBuilder
    private func segments(_ kind: Kind) -> some View {
        switch kind {
        case .tasks where tasks.count > 1 && tasks.count <= 10:
            segmentBar(tasks.map { step -> Color in
                switch step.status {
                case .done: return NookTheme.mint
                case .active: return NookTheme.paper
                case .pending, .cancelled: return NookTheme.textTertiary.opacity(0.35)
                }
            })
        case .subagents where subagents.count > 1 && subagents.count <= 10:
            segmentBar(subagents.map { $0.isRunning ? NookTheme.iris : ($0.failed ? NookTheme.coralSoft : NookTheme.mint) })
        default:
            EmptyView()
        }
    }

    private func segmentBar(_ colors: [Color]) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                Capsule().fill(color).frame(height: 3)
            }
        }
        .frame(width: 44)
    }

    // MARK: - More kinds

    private func tabs(_ kinds: [Kind], current: Kind) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(kinds, id: \.self) { kind in tab(kind, selected: open && kind == current) }
            Spacer(minLength: NookTheme.Spacing.sm)
            panelButton(current)
            ToolbarIconButton(open ? "chevron.down" : "chevron.up", tr(open ? "ws.dock.collapse" : "ws.dock.expand"),
                              height: 20, width: 20) {
                withAnimation(NookTheme.reveal) {
                    if !open { chosen = current }
                    open.toggle()
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private func tab(_ kind: Kind, selected: Bool) -> some View {
        let count = counts(kind)
        return Button {
            withAnimation(NookTheme.reveal) {
                if selected {
                    open = false
                } else {
                    chosen = kind
                    open = true
                }
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.sm) {
                mark(kind)
                Text(title(kind, short: true)).lineLimit(1)
                Text("\(count.done)/\(count.total)")
                    .font(NookTheme.mono(10.5, .medium))
                    .foregroundStyle(selected ? NookTheme.textSecondary : NookTheme.textTertiary)
                if count.failed > 0 {
                    // Something in this tab failed: a coral dot, so the count itself keeps saying how far it is.
                    Circle().fill(NookTheme.coral).frame(width: 5, height: 5)
                }
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.xs + 1)
            .hoverRowFill(selected: selected, radius: NookTheme.Radius.control)
            .roundedHitShape(NookTheme.Radius.control)
            .fixedSize()
        }
        .buttonStyle(.nookPlain)
        .accessibilityLabel(accessibility(kind))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The one thing worth a look now, under the tabs while they are closed; a click opens its tab.
    private func leadLine(_ kind: Kind) -> some View {
        Button {
            withAnimation(NookTheme.reveal) {
                chosen = kind
                open = true
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.md) {
                switch kind {
                case .tasks:
                    Image(icon: "checklist").font(NookTheme.font(11, .semibold)).frame(width: 12)
                case .subagents:
                    if let agent = leadSubagent {
                        SubagentStatusMark(agent: agent)
                        Text(agent.kind)
                            .font(NookTheme.mono(10.5, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize()
                    }
                case .commands:
                    if let command = leadCommand { SubagentStatusMark(command: command) }
                }
                headline(kind, detailedActivity: true)
                Spacer(minLength: 6)
                if failedCount > 0, !leadFailed(kind) {
                    // What failed while this one runs: counted, so it is not lost behind the running work.
                    Text(tr("ws.background.failedCount", failedCount))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize()
                }
                switch kind {
                case .tasks: EmptyView()
                case .subagents: if let agent = leadSubagent { SubagentElapsed(agent: agent) }
                case .commands: if let command = leadCommand { SubagentElapsed(command: command.reading(activity[command.id])) }
                }
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
    }

    /// What a kind's line names: the step the agent is on, the subagent at work, or the command that runs (with whether
    /// it still works).
    @ViewBuilder
    private func headline(_ kind: Kind, detailedActivity: Bool) -> some View {
        switch kind {
        case .tasks:
            let current = RunTasks.progress(tasks).current
            Group {
                if TaskChecklist.isRunning(tasks, active: working) {
                    ShimmerText(text: current)
                } else {
                    Text(current).foregroundStyle(NookTheme.paper.opacity(0.85))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        case .subagents:
            Text(leadSubagent?.title ?? "")
                .foregroundStyle(NookTheme.paper.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
        case .commands:
            Text(leadCommand?.title ?? "")
                .font(NookTheme.mono(11))
                .foregroundStyle(leadCommand?.failed == true && leadCommand?.isRunning == false
                                 ? NookTheme.coralSoft : NookTheme.paper.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            if let command = leadCommand, command.isRunning, let now = activity[command.id] {
                BackgroundCommandActivityLabel(activity: now, detailed: false).fixedSize()
            }
        }
    }

    @ViewBuilder
    private func panelButton(_ kind: Kind) -> some View {
        if let openPanel, !subagents.isEmpty || !commands.isEmpty {
            ToolbarIconButton("sidebar.right", tr(kind == .commands ? "ws.background.openPanel" : "ws.subagents.openPanel"),
                              height: 20, width: 20) { openPanel() }
        }
    }

    @ViewBuilder
    private func list(_ kind: Kind) -> some View {
        switch kind {
        case .tasks: TaskStepList(steps: tasks)
        case .subagents: SubagentRows(agents: subagents, stop: stopSubagent)
        case .commands:
            BackgroundCommandRows(commands: commands, activity: activity, shown: $shownCommand, flashed: flashed, reveal: reveal)
        }
    }

    private func accessibility(_ kind: Kind) -> String {
        let count = counts(kind)
        switch kind {
        case .tasks:
            return tr("ws.tasks.accessibility", count.done, count.total, RunTasks.progress(tasks).current)
        case .subagents:
            return tr("ws.subagents.title") + ", " + tr("ws.subagents.progress", count.done, count.total)
        case .commands:
            let running = commands.filter(\.isRunning).count
            return tr("ws.background.title") + ", " + tr("ws.subagents.running", running)
                + (count.failed > 0 ? ", " + tr("ws.background.failedCount", count.failed) : "")
        }
    }

    // MARK: - Background commands

    private var watchKey: String { commands.filter(\.isRunning).map(\.id.uuidString).joined(separator: ",") }

    /// Opens the Background tab at a command its call in the conversation asked for, and lights the row up for a moment.
    private func opened(_ id: UUID) {
        withAnimation(NookTheme.reveal) {
            chosen = .commands
            open = true
            shownCommand = id
            flashed = id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if flashed == id { withAnimation(NookTheme.reveal) { flashed = nil } }
        }
    }

    /// Every three seconds: whether each running command still works, from the processes below the agent's.
    private func watch() async {
        activity = [:]
        let running = commands.filter(\.isRunning)
        guard let agentPIDs, !running.isEmpty else { return }
        var probes: [UUID: BackgroundCommandProbe] = [:]
        var settled = Set<UUID>()
        while !Task.isCancelled {
            let roots = agentPIDs()
            let before = probes
            let (read, after, ended) = await Task.detached(priority: .utility) {
                () -> ([UUID: BackgroundCommandActivity], [UUID: BackgroundCommandProbe], [UUID]) in
                var probes = before
                var read: [UUID: BackgroundCommandActivity] = [:]
                var ended: [UUID] = []
                let table = ProcessTable.read()
                let now = Date().timeIntervalSinceReferenceDate
                for command in running {
                    var probe = probes[command.id] ?? BackgroundCommandProbe()
                    read[command.id] = probe.read(command: command.command, output: command.output, roots: roots, table: table, at: now,
                                                  commandLine: BackgroundCommandActivityLabel.commandLine,
                                                  modified: BackgroundCommandActivityLabel.modified,
                                                  tail: { BackgroundCommandActivity.tail($0) })
                    probes[command.id] = probe
                    if probe.ended(at: now) { ended.append(command.id) }
                }
                return (read, probes, ended)
            }.value
            guard !Task.isCancelled else { return }
            probes = after
            if read != activity { activity = read }
            for id in ended where settled.insert(id).inserted { settleGone?(id) }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }
}

/// The dock's card: the composer tray's fill and hairline, the watch over its running commands, and the focus a
/// command's call in the conversation sends.
private struct DockCard: ViewModifier {
    let watchKey: String
    let watch: () async -> Void
    let focus: Binding<UUID?>
    let opened: (UUID) -> Void

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .composerStripBackground()
            .task(id: watchKey) { await watch() }
            .onChange(of: focus.wrappedValue) { _, id in
                guard let id else { return }
                focus.wrappedValue = nil
                opened(id)
            }
    }
}

// MARK: - The lists

/// The agent's task list: done steps dimmed and struck through, the one it is on lit.
struct TaskStepList: View {
    let steps: [RunTaskStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                    Image(icon: symbol(step.status))
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(color(step.status))
                        .frame(width: 12)
                    Text(step.text)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(step.status.isSettled ? NookTheme.textTertiary : NookTheme.textSecondary)
                        .strikethrough(step.status.isSettled, color: NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, NookTheme.Spacing.xxs)
    }

    private func symbol(_ status: RunTaskStep.Status) -> String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .active: return "circle.dotted.circle"
        case .pending: return "circle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(_ status: RunTaskStep.Status) -> Color {
        switch status {
        case .done: return NookTheme.mint
        case .active: return NookTheme.paper
        case .pending, .cancelled: return NookTheme.textTertiary
        }
    }
}

/// A row per subagent: whether it still runs, its kind, what it does and how long it has been at it; a row opens to its
/// task and its answer.
struct SubagentRows: View {
    let agents: [SubagentInfo]
    var stop: ((SubagentInfo) -> Void)? = nil
    @State private var shown: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(agents) { agent in row(agent) }
        }
    }

    private func row(_ agent: SubagentInfo) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Button {
                    withAnimation(NookTheme.reveal) { shown = shown == agent.id ? nil : agent.id }
                } label: {
                    HStack(spacing: NookTheme.Spacing.md) {
                        SubagentStatusMark(agent: agent)
                        Text(agent.kind)
                            .font(NookTheme.mono(10.5, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                        Text(agent.title).lineLimit(1)
                        Spacer(minLength: 0)
                        SubagentElapsed(agent: agent)
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                if let stop, agent.isRunning, agent.taskID != nil {
                    ToolbarIconButton("stop.fill", tr("ws.subagents.stop"), height: 18, width: 18) { stop(agent) }
                }
            }
            if shown == agent.id {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    if !agent.prompt.isEmpty {
                        Text(ToolSummary.oneLine(agent.prompt, 400))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    if let answer = agent.answer {
                        Text(ToolSummary.oneLine(answer, 600))
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
                .font(NookTheme.TextStyle.detail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .padding(.leading, 20)
            }
        }
    }
}

/// A row per command the agent left running in the background (a dev server, a watcher, a long build), named by what the
/// agent said it is for: those still at work first, then the failed ones. A row opens to the command itself and the end
/// of what it printed, in a box of its own so the output of one command never runs into the next row.
struct BackgroundCommandRows: View {
    let commands: [BackgroundCommandInfo]
    let activity: [UUID: BackgroundCommandActivity]
    @Binding var shown: UUID?
    /// The row its call in the conversation just sent you to, lit up for a moment.
    var flashed: UUID?
    var reveal: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ForEach(BackgroundCommands.ordered(commands)) { command in row(command) }
        }
    }

    private func row(_ command: BackgroundCommandInfo) -> some View {
        let expanded = shown == command.id
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Button {
                withAnimation(NookTheme.reveal) { shown = expanded ? nil : command.id }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    SubagentStatusMark(command: command)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(command.title)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(command.isRunning ? NookTheme.paper.opacity(0.85)
                                             : (command.failed ? NookTheme.textSecondary : NookTheme.textTertiary))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if command.isRunning, let now = activity[command.id] {
                            BackgroundCommandActivityLabel(activity: now)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if command.printed != nil && !expanded {
                        Image(icon: "text.alignleft")
                            .font(NookTheme.font(9, .semibold))
                            .foregroundStyle(NookTheme.textTertiary)
                            .help(tr("ws.background.hasOutput"))
                    }
                    SubagentElapsed(command: command.reading(activity[command.id]))
                    DisclosureChevron(open: expanded, size: 8)
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(command.command)
            if expanded { detail(command) }
        }
        .background(NookTheme.shape(NookTheme.Radius.control)
            .fill(NookTheme.iris.opacity(flashed == command.id ? 0.16 : 0))
            .padding(.horizontal, -NookTheme.Spacing.sm))
    }

    /// The command and the end of what it printed, in an inset box under its row.
    private func detail(_ command: BackgroundCommandInfo) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                Text(command.command)
                    .font(NookTheme.mono(10.5, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(4)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let reveal {
                    ToolbarIconButton("arrow.up.to.line", tr("ws.background.showInConversation"), height: 18, width: 18) {
                        reveal(command.id)
                    }
                }
            }
            if let printed = command.printed {
                NookDivider()
                Text(BackgroundCommandList.tail(printed))
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(command.failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(tr(command.isRunning ? "ws.console.waiting" : "ws.console.noOutput"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NookTheme.Spacing.md)
        .roundedBackground(NookTheme.well, radius: NookTheme.Radius.control)
        .padding(.leading, 20)
        .padding(.bottom, NookTheme.Spacing.xs)
    }
}
