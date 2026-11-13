import SwiftUI
import AppKit

// What the agent is doing besides talking, above the composer: its own task list, the subagents it
// started, and the pull request the session watches.

/// "Tasks  Running the tests  3/7" with a bar per step; opens into the whole list.
/// The goal the agent works toward, with what the agent last reported about it.
struct GoalStrip: View {
    let goal: SessionGoal
    let canPause: Bool
    let control: (SessionGoalCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: "scope").font(NookTheme.font(11, .semibold))
                Text(tr("ws.goal.title")).foregroundStyle(NookTheme.textTertiary)
                Text(goal.objective)
                    .foregroundStyle(NookTheme.paper.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(goal.objective)
                Spacer(minLength: 6)
                Text(statusLine).foregroundStyle(NookTheme.textSecondary)
                if canPause, goal.status == .active {
                    NookIconButton(systemName: "pause", label: tr("ws.goal.pause"), size: 18) { control(.pause) }
                } else if canPause, goal.status == .paused {
                    NookIconButton(systemName: "play", label: tr("ws.goal.resume"), size: 18) { control(.resume) }
                }
                NookIconButton(systemName: "xmark", label: tr("ws.goal.clear"), size: 18) { control(.clear) }
            }
            if let check = goal.lastCheck, !check.isEmpty {
                Text(check).foregroundStyle(NookTheme.textTertiary).lineLimit(2)
            }
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
    }

    private var statusLine: String {
        let status = tr("ws.goal.status." + goal.status.rawValue)
        guard let checks = goal.checks, checks > 0 else { return status }
        return status + " · " + tr("ws.goal.checks", checks)
    }
}

/// `/clear` waits for your next message: that one starts a new conversation (`WorkspaceManager.armFreshConversation`).
/// "Keep this conversation" takes it back.
struct FreshConversationStrip: View {
    let keep: () -> Void

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(icon: "eraser").font(NookTheme.font(11, .semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("ws.fresh.title")).foregroundStyle(NookTheme.paper.opacity(0.85))
                Text(tr("ws.fresh.detail")).foregroundStyle(NookTheme.textTertiary)
            }
            Spacer(minLength: 6)
            Button(tr("ws.fresh.keep"), action: keep)
                .buttonStyle(.nookPlain)
                .foregroundStyle(NookTheme.iris)
                .help(tr("ws.fresh.keep.help"))
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
    }
}

/// The commands this agent runs wait for the Mac to have room again (`AgentGovernor`): what you need to know, and a way to
/// let them go on anyway. Shown only while they wait.
struct ResourceWaitStrip: View {
    let runID: UUID
    @ObservedObject private var status = AgentGovernorStatus.shared

    var body: some View {
        if status.throttles[runID] == .paused {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: "pause.circle").font(NookTheme.font(11, .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(tr("ws.governor.paused.title")).foregroundStyle(NookTheme.paper.opacity(0.85))
                    Text(tr("ws.governor.paused.detail")).foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 6)
                Button(tr("ws.governor.letGoOn")) { AgentGovernor.shared.letGoOn(runID) }
                    .buttonStyle(.nookPlain)
                    .foregroundStyle(NookTheme.iris)
                    .help(tr("ws.governor.letGoOn.help"))
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            // The same card as the subagent and background strips under it, so their icons share one column.
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, 7)
            .roundedBackground(NookTheme.composerTray, radius: NookTheme.Radius.card)
        }
    }
}

/// "Tasks  Phase 2: agent parity  1/5" above the composer, opening to the whole list. While the agent works the step it
/// is on shimmers, so the phase that runs stays in sight while you scroll or type.
struct TasksStrip: View {
    let steps: [RunTaskStep]
    /// The agent works on the list now.
    var working = false
    @State private var open = false

    var body: some View {
        let progress = RunTasks.progress(steps)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(icon: "checklist").font(NookTheme.font(11, .semibold))
                    Text(tr("ws.tasks.title")).foregroundStyle(NookTheme.textTertiary)
                    Group {
                        if TaskChecklist.isRunning(steps, active: working) {
                            ShimmerText(text: progress.current)
                        } else {
                            Text(progress.current).foregroundStyle(NookTheme.paper.opacity(0.85))
                        }
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(progress.done)/\(progress.total)")
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                    if steps.count > 1 && steps.count <= 10 { segments }
                    Image(icon: "chevron.up")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .accessibilityLabel(tr("ws.tasks.accessibility", progress.done, progress.total, progress.current))
            if open {
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
                .padding(.top, NookTheme.Spacing.xxs)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, 7)
        .roundedBackground(NookTheme.composerTray, radius: NookTheme.Radius.card)
    }

    private var segments: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                Capsule().fill(segmentColor(step.status)).frame(height: 3)
            }
        }
        .frame(width: 44)
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

    private func segmentColor(_ status: RunTaskStep.Status) -> Color {
        switch status {
        case .done: return NookTheme.mint
        case .active: return NookTheme.paper
        case .pending, .cancelled: return NookTheme.textTertiary.opacity(0.35)
        }
    }
}

/// "Subagents  Auditing the chats  1 of 3 done" with a row per subagent: whether it still runs, its kind, what it does
/// and how long it has been at it; a row opens to its task and its answer. It stays while any of them still works in the
/// background, also after the turn that started them. The arrow shows them all in the side panel (`openPanel`).
struct SubagentBar: View {
    let agents: [SubagentInfo]
    /// Stops one subagent at work in the background, for an agent that can (`ProviderCapabilities.stopsOneSubagent`).
    var stop: ((SubagentInfo) -> Void)? = nil
    /// Shows the subagents in the side panel's Subagents tab; false when the panel is busy with something else.
    var openPanel: (() -> Void)? = nil
    @State private var open = false
    @State private var shown: UUID?

    var body: some View {
        let done = agents.filter { !$0.isRunning }.count
        let running = agents.count - done
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.md) {
                Button {
                    withAnimation(NookTheme.reveal) { open.toggle() }
                } label: {
                    HStack(spacing: NookTheme.Spacing.md) {
                        if running > 0 {
                            ProgressView().controlSize(.mini).frame(width: 12)
                        } else {
                            Image(icon: "person.2").font(NookTheme.font(11, .semibold))
                        }
                        Text(tr("ws.subagents.title")).foregroundStyle(NookTheme.textTertiary)
                        Text(agents.first(where: \.isRunning)?.title ?? agents.last?.title ?? "")
                            .foregroundStyle(NookTheme.paper.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        // "2 of 4 done" alone: the spinner already says that some run, a "2 running" beside it said it twice.
                        Text(tr("ws.subagents.progress", done, agents.count))
                            .font(NookTheme.TextStyle.detail.monospacedDigit())
                            .foregroundStyle(NookTheme.textSecondary)
                        if agents.count > 1 && agents.count <= 10 { segments }
                        Image(icon: "chevron.up")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .accessibilityLabel(tr("ws.subagents.title") + ", " + tr("ws.subagents.progress", done, agents.count))
                if let openPanel {
                    ToolbarIconButton("sidebar.right", tr("ws.subagents.openPanel"), height: 20, width: 20) {
                        openPanel()
                    }
                }
            }
            if open {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    ForEach(agents) { agent in row(agent) }
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, 7)
        .roundedBackground(NookTheme.composerTray, radius: NookTheme.Radius.card)
    }

    /// Stop for one subagent still at work in the background, past its elapsed time.
    @ViewBuilder
    private func stopButton(_ agent: SubagentInfo) -> some View {
        if let stop, agent.isRunning, agent.taskID != nil {
            ToolbarIconButton("stop.fill", tr("ws.subagents.stop"), height: 18, width: 18) { stop(agent) }
        }
    }

    /// One short bar per subagent: lit while it runs, mint once done, coral when it failed.
    private var segments: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(agents) { agent in
                Capsule().fill(agent.isRunning ? NookTheme.iris : (agent.failed ? NookTheme.coralSoft : NookTheme.mint))
                    .frame(height: 3)
            }
        }
        .frame(width: 44)
    }

    private func row(_ agent: SubagentInfo) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Button {
                    shown = shown == agent.id ? nil : agent.id
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
                stopButton(agent)
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

/// Whether a subagent or background command still runs (a small spinner), finished (a mint check) or failed (a coral
/// cross).
struct SubagentStatusMark: View {
    let running: Bool
    let failed: Bool
    var size: CGFloat = 10

    init(agent: SubagentInfo, size: CGFloat = 10) {
        running = agent.isRunning
        failed = agent.failed
        self.size = size
    }

    init(command: BackgroundCommandInfo, size: CGFloat = 10) {
        running = command.isRunning
        failed = command.failed
        self.size = size
    }

    var body: some View {
        Group {
            if running {
                ProgressView().controlSize(.mini)
            } else {
                Image(icon: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(NookTheme.font(size, .semibold))
                    .foregroundStyle(failed ? NookTheme.coralSoft : NookTheme.mint)
            }
        }
        .frame(width: 12)
    }
}

/// How long a running subagent or background command has been at it, counting up; nothing once it is done (its row only
/// keeps its outcome).
struct SubagentElapsed: View {
    let running: Bool
    let started: Date

    init(agent: SubagentInfo) {
        running = agent.isRunning
        started = agent.started
    }

    init(command: BackgroundCommandInfo) {
        running = command.isRunning
        started = command.started
    }

    var body: some View {
        if running, started > .distantPast {
            Text(timerInterval: started...Date.distantFuture, countsDown: false)
                .font(NookTheme.mono(10.5))
                .foregroundStyle(NookTheme.textTertiary)
                .monospacedDigit()
                .fixedSize()
        }
    }
}

/// The Subagents tab in a session's side (or bottom) panel: every subagent the agent started, apart from its plans and
/// files, each with what it was asked, how it went about it and what it answered.
struct SessionSubagentsPanel: View {
    let agents: [SubagentInfo]
    /// The commands it left running in the background, above the subagents while any of them runs.
    var commands: [BackgroundCommandInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if agents.isEmpty && commands.isEmpty {
                WSEmptyState(symbol: SessionTool.subagents.symbol, title: tr("ws.subagents.empty.title"),
                             message: tr("ws.subagents.empty.body"))
            } else {
                // Flat on the panel, like a pull request's page: no card around the list or around each entry.
                ScrollView {
                    // Commands still at work come first: they are what keeps the session going.
                    let commandsFirst = commands.contains(where: \.isRunning)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxl) {
                        if commandsFirst { BackgroundCommandList(commands: commands) }
                        if !agents.isEmpty { SubagentList(agents: agents) }
                        if !commandsFirst, !commands.isEmpty { BackgroundCommandList(commands: commands) }
                    }
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.bottom, NookTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Every subagent of a session, as the Subagents tab in the side panel shows them: a card each with its state, what
/// it was asked, its steps and what it answered, the running ones counting their time, parted by lines.
struct SubagentList: View {
    let agents: [SubagentInfo]

    var body: some View {
        let running = agents.filter(\.isRunning).count
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("ws.subagents.progress", agents.count - running, agents.count))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                if running > 0 {
                    Text(tr("ws.subagents.running", running))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.iris)
                }
            }
            // Those still at work first, then the rest, newest first.
            let ordered = agents.filter(\.isRunning) + agents.filter { !$0.isRunning }.reversed()
            ForEach(Array(ordered.enumerated()), id: \.element.id) { index, agent in
                if index > 0 { NookDivider() }
                SubagentCard(agent: agent)
            }
        }
    }
}

/// One subagent in `SubagentList`: its state, title, kind and time over what it went through, drawn as an agent's own
/// conversation (`SubagentTranscript`).
private struct SubagentCard: View {
    let agent: SubagentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                HStack(spacing: NookTheme.Spacing.md) {
                    SubagentStatusMark(agent: agent, size: 11)
                    Text(agent.title)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textStrong)
                        .lineLimit(2)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    SubagentElapsed(agent: agent)
                }
                SubagentMeta(agent: agent)
                    .padding(.leading, 20)
            }
            SubagentTranscript(agent: agent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NookTheme.Spacing.xs)
    }
}

/// "general-purpose · in the background · 08:45 · Subagent done": what kind of subagent it is, when it started and how it
/// ended, in quiet caption text.
struct SubagentMeta: View {
    let agent: SubagentInfo

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(agent.kind).font(NookTheme.mono(10.5, .medium))
            if agent.background { Text("·"); Text(tr("ws.subagent.background")) }
            if agent.started > .distantPast {
                Text("·")
                Text(agent.started, style: .time)
            }
            if !agent.isRunning {
                Text("·")
                Text(tr(agent.failed ? "ws.subagent.failed" : "ws.subagent.done"))
                    .foregroundStyle(agent.failed ? NookTheme.coralSoft : NookTheme.textTertiary)
            }
        }
        .font(NookTheme.TextStyle.caption)
        .foregroundStyle(NookTheme.textTertiary)
        .lineLimit(1)
    }
}

/// What a subagent went through, as an agent's own conversation reads: its task as the message it was sent, its work
/// folded under "How it worked · 12 steps" (open while it works) with the same lines, thoughts and groups as the agent's,
/// and its answer as a reply. The Subagents tab and the subagent's row in the timeline both show it.
struct SubagentTranscript: View {
    let agent: SubagentInfo
    /// Whether its work shows; nil follows the subagent: open while it works, folded once it is done.
    @State private var workOpen: Bool?
    /// The thoughts and groups of steps that are open, by `SubagentSteps.Block.id`.
    @State private var open: Set<Int> = []

    var body: some View {
        let showsWork = workOpen ?? agent.isRunning
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if !agent.prompt.isEmpty {
                TranscriptUserMessage(text: agent.prompt, date: agent.started > .distantPast ? agent.started : nil)
            }
            if !agent.steps.isEmpty {
                TranscriptFold(text: tr("ws.subagent.steps") + " · " + tr("ws.subagent.stepCount", agent.steps.count),
                               open: showsWork, ruled: agent.answer != nil || showsWork,
                               toggle: { withAnimation(NookTheme.reveal) { workOpen = !showsWork } }) {
                    ForEach(SubagentSteps.blocks(agent.steps)) { block in
                        blockView(block)
                    }
                }
            }
            if let answer = agent.answer {
                TranscriptReply(text: answer)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: SubagentSteps.Block) -> some View {
        let isOpen = open.contains(block.id)
        let toggle = { withAnimation(NookTheme.reveal) { if isOpen { open.remove(block.id) } else { open.insert(block.id) } } }
        if block.steps.count > 1 {
            TranscriptWorkGroup(tally: SubagentSteps.tally(block.steps), open: isOpen, toggle: toggle) {
                ForEach(Array(block.steps.enumerated()), id: \.offset) { _, step in
                    SubagentToolLine(step: step)
                }
            }
        } else if let step = block.steps.first {
            switch step.kind {
            case .thinking:
                TranscriptThought(text: step.text, open: isOpen, toggle: toggle)
            case .text:
                TranscriptReply(text: step.text, footer: false)
            case .tool:
                SubagentToolLine(step: step)
            }
        }
    }
}

/// One tool call of a subagent, as a step of the agent's own reads: what it did as a verb, then what it did that to.
private struct SubagentToolLine: View {
    let step: SubagentStep

    var body: some View {
        let tool = AgentToolStep(id: "", name: step.toolName, summary: step.toolDetail, state: .done)
        let text = TranscriptStepText.parts(tool)
        TranscriptWorkLine(symbol: TranscriptSymbols.symbol(tool.name), label: text.verb, detail: text.detail, mono: text.mono)
            .help(step.text)
    }
}

/// One pull request in the tray above the composer, as one quiet line: its state, what it is (title, then its branch
/// dimmed) and on the right small marks for CI, reviews and watching. Only what needs you gets words (failing CI); the
/// rest says itself on hover. A click anywhere on the row opens it, as the arrow on hover does; the eye watches it (CI,
/// reviews and comments wake the agent) or stops.
struct PullRequestWatchStrip: View {
    let url: URL
    /// nil while the session's pull request is not watched.
    let watch: PullRequestWatch?
    /// The branch the pull request is for, shown dimmed after its title when a session lists several (see `SessionBranches`).
    var branch: String? = nil
    var isCurrent = true
    /// The pull request's title, so each row says what it was.
    var title: String? = nil
    /// Nil for a session Nook does not run (or a request that landed): nothing to watch, so the row only shows and opens it.
    var toggle: (() -> Void)?
    @Environment(\.pullRequestLinksBeside) private var pullRequestLinksBeside
    @State private var showsCI = false
    @State private var hovering = false
    /// State and checks come from the status every place shares (the row badge, the pull request page), not from the
    /// watch's last look, so the tray never shows an older state than the rest of Nook.
    @ObservedObject private var statuses = PullRequestStatusStore.shared

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Button(action: open) {
                PullRequestLiveStateBadge(url: url, fallback: PullRequestBadge.Glyph(rawValue: watch?.state ?? "open") ?? .open)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(tr("ws.prwatch.open"))
            // In a list of branches the states share one column, so the titles after them line up.
            .frame(minWidth: branch == nil ? nil : Self.stateColumn, alignment: .leading)
            identity
            Spacer(minLength: NookTheme.Spacing.sm)
            if !summary.isEmpty {
                Text(summary)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            ciMark
            if let toggle { watchMark(toggle) }
            ToolbarIconButton("arrow.up.right", tr("ws.prwatch.open"), height: 22, width: 22, open)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, NookTheme.Spacing.xs)
        .frame(minHeight: 26)
        .hoverRowFill($hovering, radius: NookTheme.Radius.chip)
        // The whole row opens the pull request (in the session's side panel); the checks and the eye keep their own click.
        .contentShape(Rectangle())
        .nookClickable()
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: tr("ws.prwatch.open"), open)
        .opacity(isCurrent ? 1 : 0.72)
        .animation(NookTheme.hover, value: hovering)
    }

    /// The width of the state column when a session lists several branches (`BranchTrayRow` uses it too).
    static let stateColumn: CGFloat = 176

    /// The title in the row's own voice, its branch after it in the quiet monospace of a name.
    @ViewBuilder
    private var identity: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(isCurrent ? NookTheme.textStrong : NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
            }
            if let branch {
                Text(branch)
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .help(tr(isCurrent ? "ws.branches.current" : "ws.branches.earlier", branch))
            }
        }
    }

    /// The checks as one mark; failing ones also say so. A click shows the checks and their logs (GitHub), or the
    /// pipelines page (GitLab).
    @ViewBuilder
    private var ciMark: some View {
        if let ci, let ciOutcome {
            Button(action: openCI) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    CheckOutcomeGlyph(outcome: ciOutcome, size: 11, running: ciOutcome == .pending)
                    // One line at any width: the title gives way first (`identity` truncates), never "CI failed".
                    if ciOutcome == .failing { Text(ci).lineLimit(1).fixedSize() }
                }
                .layoutPriority(1)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coral)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(ci + " · " + tr("ws.prwatch.ciHelp"))
            .accessibilityLabel(ci)
            .popover(isPresented: $showsCI, arrowEdge: .top) {
                CIChecksPopover(pullRequest: url).frame(width: 680, height: 440)
            }
        }
    }

    /// An open eye while the agent watches the request, a dim crossed one (brighter on hover) while it does not.
    private func watchMark(_ toggle: @escaping () -> Void) -> some View {
        let watching = watch != nil
        let label = tr(watching ? "ws.prwatch.watching" : "ws.prwatch.notWatching")
        return Button(action: toggle) {
            Image(icon: watching ? "eye.fill" : "eye.slash")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(watching ? NookTheme.mint : (hovering ? NookTheme.textSecondary : NookTheme.textTertiary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .help(label + " · " + tr(watching ? "ws.prwatch.stop" : "ws.prwatch.startHelp"))
        .accessibilityLabel(label)
    }

    /// The newest known checks; the watch's last look until a read has said.
    private var checks: String { statuses.status(url)?.checks ?? watch?.checks ?? "" }

    /// The checks as the shared CI icon shows them, the same one the pull request rows and page use.
    private var ciOutcome: PullRequestCheck.Outcome? {
        switch checks {
        case "success": return .passing
        case "failure": return .failing
        case "pending": return .pending
        default: return nil
        }
    }

    private var ci: String? {
        switch checks {
        case "success": return tr("ws.prwatch.ciPassed")
        case "failure": return tr("ws.prwatch.ciFailed")
        case "pending": return tr("ws.prwatch.ciPending")
        default: return nil
        }
    }

    /// A GitHub pull request opens in Nook, as a link to it in the conversation does: in the session's side panel. A
    /// GitLab merge request (or no GitHub account) opens as any web link there does: in the side panel's browser, or
    /// in your browser when the link setting, ⌘ or ⌃ says so.
    private func open() {
        let app = AppModel.shared
        if app.openPullRequestLink(url, beside: pullRequestLinksBeside) { return }
        if pullRequestLinksBeside, app.openLinkBeside(url) { return }
        NSWorkspace.shared.open(url)
    }

    private func openCI() {
        if GitHubPullRequests.parse(url) != nil {
            showsCI.toggle()
        } else {
            // A GitLab merge request: its pipelines have their own page.
            NSWorkspace.shared.open(url.appendingPathComponent("pipelines"))
        }
    }

    private var summary: String {
        guard let watch else { return "" }
        var parts: [String] = []
        if watch.reviewCount > 0 { parts.append(tr("ws.prwatch.reviews", watch.reviewCount)) }
        if watch.checkedAt == nil { parts.append(tr("ws.prwatch.loading")) }
        return parts.joined(separator: " · ")
    }
}

/// A branch of the session without a pull request, in the same columns as one with: "No PR" where the state would be,
/// its name where the title would be.
struct BranchTrayRow: View {
    let branch: String
    var isCurrent = true

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.xs) {
                NookSymbol("arrow.triangle.branch", size: 10).font(NookTheme.font(10, .semibold))
                Text(tr("ws.branches.noPullRequest"))
                    .font(NookTheme.TextStyle.detail)
            }
            .padding(.leading, 5)
            .frame(minWidth: PullRequestWatchStrip.stateColumn, alignment: .leading)
            Text(branch)
                .font(NookTheme.mono(10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: NookTheme.Spacing.sm)
        }
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.leading, NookTheme.Spacing.xs)
        .frame(minHeight: 26)
        .opacity(isCurrent ? 1 : 0.72)
        .help(tr(isCurrent ? "ws.branches.current" : "ws.branches.earlier", branch))
    }
}

/// A pull request the git button is still writing or opening, in the tray above the composer where it will appear: a
/// spinner in the state column and the step it is at, until the request itself takes its place.
struct PullRequestPendingRow: View {
    let step: String

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.xs) {
                ProgressView().controlSize(.mini)
                NookSymbol(PullRequestIcon.generic, size: 10).font(NookTheme.font(10, .semibold))
            }
            .padding(.leading, 5)
            Text(step)
                .font(NookTheme.TextStyle.detail)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NookTheme.Spacing.sm)
        }
        .foregroundStyle(NookTheme.textSecondary)
        .padding(.leading, NookTheme.Spacing.xs)
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }
}


/// "In the background  npm run dev  1 running" with a row per command the agent left running in the background (a dev
/// server, a watcher, a long build). The header counts what runs and what failed; a row names the command by what the
/// agent said it is for, those still at work first, then the failed ones. A row opens to the command itself and the end
/// of what it printed, in a box of its own so the output of one command never runs into the next row. It stays while any
/// of them runs, also after the turn that started them, so the session does not look done while it is not. The sidebar
/// button shows them in the side panel (`openPanel`).
///
/// Each command is also a call in the conversation (with a `BackgroundCommandLink` under it): `focus` set from there opens
/// its row here and lights it up, and a row's `reveal` goes back to its call.
struct BackgroundCommandBar: View {
    let commands: [BackgroundCommandInfo]
    var focus: Binding<UUID?> = .constant(nil)
    var reveal: ((UUID) -> Void)? = nil
    var openPanel: (() -> Void)? = nil
    /// The session's agent processes: with them each running command says whether it still works.
    var agentPIDs: (() -> [Int32])? = nil
    @State private var open = false
    @State private var shown: UUID?
    @State private var flashed: UUID?
    @State private var activity: [UUID: BackgroundCommandActivity] = [:]

    var body: some View {
        let running = commands.filter(\.isRunning).count
        let failed = commands.filter(\.failed).count
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.md) {
                Button {
                    withAnimation(NookTheme.reveal) { open.toggle() }
                } label: {
                    HStack(spacing: NookTheme.Spacing.md) {
                        if running > 0 {
                            ProgressView().controlSize(.mini).frame(width: 12)
                        } else {
                            Image(icon: "terminal").font(NookTheme.font(11, .semibold))
                        }
                        Text(tr("ws.background.title")).foregroundStyle(NookTheme.textTertiary)
                        Text(commands.last(where: \.isRunning)?.title ?? commands.last?.title ?? "")
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.paper.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if let latest = commands.last(where: \.isRunning), let now = activity[latest.id] {
                            BackgroundCommandActivityLabel(activity: now, detailed: false)
                                .fixedSize()
                        }
                        Spacer(minLength: 6)
                        if failed > 0 {
                            Text(tr("ws.background.failedCount", failed))
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.coralSoft)
                                .fixedSize()
                        }
                        Text(tr("ws.subagents.progress", commands.count - running, commands.count))
                            .font(NookTheme.TextStyle.detail.monospacedDigit())
                            .foregroundStyle(NookTheme.textSecondary)
                            .fixedSize()
                        Image(icon: "chevron.up")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .accessibilityLabel(tr("ws.background.title") + ", " + tr("ws.subagents.running", running)
                                    + (failed > 0 ? ", " + tr("ws.background.failedCount", failed) : ""))
                if let openPanel {
                    ToolbarIconButton("sidebar.right", tr("ws.background.openPanel"), height: 20, width: 20) {
                        openPanel()
                    }
                }
            }
            if open {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    ForEach(BackgroundCommands.ordered(commands)) { command in row(command) }
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, 7)
        .roundedBackground(NookTheme.composerTray, radius: NookTheme.Radius.card)
        .task(id: commands.filter(\.isRunning).map(\.id.uuidString).joined(separator: ",")) { await watch() }
        .onChange(of: focus.wrappedValue) { _, id in
            guard let id else { return }
            focus.wrappedValue = nil
            withAnimation(NookTheme.reveal) {
                open = true
                shown = id
                flashed = id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if flashed == id { withAnimation(NookTheme.reveal) { flashed = nil } }
            }
        }
    }

    /// Every three seconds: whether each running command still works, from the processes below the agent's.
    private func watch() async {
        activity = [:]
        let running = commands.filter(\.isRunning)
        guard let agentPIDs, !running.isEmpty else { return }
        var probes: [UUID: BackgroundCommandProbe] = [:]
        while !Task.isCancelled {
            let roots = agentPIDs()
            let before = probes
            let (read, after) = await Task.detached(priority: .utility) { () -> ([UUID: BackgroundCommandActivity], [UUID: BackgroundCommandProbe]) in
                var probes = before
                var read: [UUID: BackgroundCommandActivity] = [:]
                let table = ProcessTable.read()
                let now = Date().timeIntervalSinceReferenceDate
                for command in running {
                    var probe = probes[command.id] ?? BackgroundCommandProbe()
                    read[command.id] = probe.read(command: command.command, output: command.output, roots: roots, table: table, at: now,
                                                  commandLine: BackgroundCommandActivityLabel.commandLine,
                                                  modified: BackgroundCommandActivityLabel.modified)
                    probes[command.id] = probe
                }
                return (read, probes)
            }.value
            guard !Task.isCancelled else { return }
            probes = after
            if read != activity { activity = read }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
                    SubagentElapsed(command: command)
                    Image(icon: "chevron.right")
                        .font(NookTheme.font(8, .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            .help(command.command)
            if expanded { detail(command) }
        }
        // Lit up for a moment when its call in the conversation sent you here.
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

/// Whether a running background command still works, so one that runs long does not look stuck: "● Working · 140 % CPU
/// · xcodebuild · last output at 21:30", "● Waiting · no CPU use", or "● Its process is gone". `detailed: false` keeps
/// only the state, for the bar's header.
struct BackgroundCommandActivityLabel: View {
    let activity: BackgroundCommandActivity
    var detailed = true

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(NookTheme.TextStyle.caption)
        .foregroundStyle(activity.state == .gone ? NookTheme.coralSoft : NookTheme.textTertiary)
        .help(tr("ws.background.activity.help"))
    }

    private var color: Color {
        switch activity.state {
        case .working: return NookTheme.mint
        case .waiting: return NookTheme.amber
        case .gone: return NookTheme.coralSoft
        }
    }

    private var text: String {
        var parts: [String]
        switch activity.state {
        case .working:
            parts = [activity.cpuLabel.map { tr("ws.background.activity.working", $0) } ?? tr("ws.background.activity.active")]
        case .waiting:
            parts = [tr("ws.background.activity.waiting")]
        case .gone:
            parts = [tr("ws.background.activity.gone")]
        }
        guard detailed else { return parts[0] }
        if activity.state != .gone, let process = activity.process { parts.append(process) }
        if let last = activity.lastOutput {
            parts.append(tr("ws.background.activity.lastOutput", last.formatted(date: .omitted, time: .shortened)))
        } else if activity.hasOutputFile {
            parts.append(tr("ws.background.activity.noOutput"))
        }
        return parts.joined(separator: " · ")
    }

    /// A process's command line, its arguments joined by spaces. Nil when it cannot be read.
    nonisolated static func commandLine(_ pid: Int32) -> String? {
        LocalAgentScanner.commandLine(pid)?.joined(separator: " ")
    }

    /// When the file at `path` last changed; nil while it is empty or missing.
    nonisolated static func modified(_ path: String) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else { return nil }
        return attributes[.modificationDate] as? Date
    }
}

/// The line under a background command's call in the conversation: "In the background · Running 1:23 ↓". It says the
/// command goes on in the bar above the composer, with the same state mark as its row there, and a click opens that row.
struct BackgroundCommandLink: View {
    let event: RunEvent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let command = BackgroundCommands.list([event]).first
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if let command { SubagentStatusMark(command: command, size: 9).frame(width: 10) }
                Text(tr("ws.background.title"))
                    .foregroundStyle(NookTheme.textTertiary)
                Text("·").foregroundStyle(NookTheme.textTertiary)
                Text(tr(command?.isRunning != false ? "ws.background.runningShort"
                        : (command?.failed == true ? "ws.background.failed" : "ws.background.done")))
                    .foregroundStyle(command?.failed == true ? NookTheme.coralSoft
                                     : (command?.isRunning != false ? NookTheme.iris : NookTheme.textTertiary))
                if let command { SubagentElapsed(command: command) }
                Image(icon: "arrow.down")
                    .font(NookTheme.font(8.5, .bold))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textTertiary)
            }
            .font(NookTheme.TextStyle.caption)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.xxs)
            .hoverRowFill($hovering, rest: NookTheme.composerTray)
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .padding(.leading, TranscriptStyle.workIndent)
        .help(tr("ws.background.showInBar"))
        .accessibilityLabel(tr("ws.background.showInBar"))
    }
}

/// The commands the agent left running in the background, as the Subagents tab in the side panel shows them: a card each
/// with its state, what it is for, the command and the end of what it printed, the running ones counting their time.
struct BackgroundCommandList: View {
    let commands: [BackgroundCommandInfo]

    /// The last lines a command printed: what says how it is doing.
    static func tail(_ output: String) -> String {
        let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        return lines.suffix(12).joined(separator: "\n")
    }

    var body: some View {
        let running = commands.filter(\.isRunning).count
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(tr("ws.background.title"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                if running > 0 {
                    Text(tr("ws.subagents.running", running))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.iris)
                }
            }
            // Those still at work first, then the failed ones, then the rest, newest first.
            ForEach(Array(BackgroundCommands.ordered(commands).enumerated()), id: \.element.id) { index, command in
                if index > 0 { NookDivider() }
                row(command)
            }
        }
    }

    /// One command, flat in the list: its state mark says whether it still runs.
    private func row(_ command: BackgroundCommandInfo) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.md) {
                SubagentStatusMark(command: command, size: 11)
                Text(command.title)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textStrong)
                    .lineLimit(2)
                Spacer(minLength: NookTheme.Spacing.sm)
                SubagentElapsed(command: command)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if command.started > .distantPast { Text(command.started, style: .time) }
                Text("·")
                Text(tr(command.isRunning ? "ws.background.running" : (command.failed ? "ws.background.failed" : "ws.background.done")))
                    .foregroundStyle(command.failed ? NookTheme.coralSoft : (command.isRunning ? NookTheme.iris : NookTheme.textTertiary))
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.leading, 20)
            if command.title != command.command {
                Text(command.command)
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            }
            if let printed = command.printed {
                Text(Self.tail(printed))
                    .font(NookTheme.mono(10.5))
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NookTheme.Spacing.xs)
    }
}
