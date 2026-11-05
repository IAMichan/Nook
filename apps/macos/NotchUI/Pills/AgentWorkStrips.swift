import SwiftUI
import AppKit

// What the agent is doing besides talking, above the composer: its own task list, the subagents it
// started, and the pull request the session watches.

/// "Tasks  Running the tests  3/7" with a bar per step; opens into the whole list.
struct TasksStrip: View {
    let steps: [RunTaskStep]
    @State private var open = false

    var body: some View {
        let progress = RunTasks.progress(steps)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(systemName: "checklist").font(NookTheme.font(11, .semibold))
                    Text(tr("ws.tasks.title")).foregroundStyle(NookTheme.textTertiary)
                    Text(progress.current)
                        .foregroundStyle(NookTheme.paper.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(progress.done)/\(progress.total)")
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                    if steps.count > 1 && steps.count <= 10 { segments }
                    Image(systemName: "chevron.up")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("ws.tasks.accessibility", progress.done, progress.total, progress.current))
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                            Image(systemName: symbol(step.status))
                                .font(NookTheme.font(10, .semibold))
                                .foregroundStyle(color(step.status))
                                .frame(width: 12)
                            Text(step.text)
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(step.status == .done ? NookTheme.textTertiary : NookTheme.textSecondary)
                                .strikethrough(step.status == .done, color: NookTheme.textTertiary)
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
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
        }
    }

    private func color(_ status: RunTaskStep.Status) -> Color {
        switch status {
        case .done: return NookTheme.mint
        case .active: return NookTheme.paper
        case .pending: return NookTheme.textTertiary
        }
    }

    private func segmentColor(_ status: RunTaskStep.Status) -> Color {
        switch status {
        case .done: return NookTheme.mint
        case .active: return NookTheme.paper
        case .pending: return NookTheme.textTertiary.opacity(0.35)
        }
    }
}

/// "Subagents  Auditing the chats  1 of 3 done" with a row per subagent: whether it still runs, its kind, what it does
/// and how long it has been at it; a row opens to its task and its answer. It stays while any of them still works in the
/// background, also after the turn that started them. The arrow shows them all in the side panel (`openPanel`).
struct SubagentBar: View {
    let agents: [SubagentInfo]
    /// Shows the subagents in the side panel's Subagents tab; false when the panel is busy with something else.
    var openPanel: (() -> Bool)? = nil
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
                            Image(systemName: "person.2").font(NookTheme.font(11, .semibold))
                        }
                        Text(tr("ws.subagents.title")).foregroundStyle(NookTheme.textTertiary)
                        Text(agents.first(where: \.isRunning)?.title ?? agents.last?.title ?? "")
                            .foregroundStyle(NookTheme.paper.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if running > 0 {
                            Text(tr("ws.subagents.running", running))
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.iris)
                        }
                        Text(tr("ws.subagents.progress", done, agents.count))
                            .font(NookTheme.mono(11, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                        if agents.count > 1 && agents.count <= 10 { segments }
                        Image(systemName: "chevron.up")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("ws.subagents.title") + ", " + tr("ws.subagents.progress", done, agents.count))
                if let openPanel {
                    ToolbarIconButton("sidebar.right", tr("ws.subagents.openPanel"), height: 20, width: 20) {
                        if !openPanel() { withAnimation(NookTheme.reveal) { open = true } }
                    }
                    .help(tr("ws.subagents.openPanel"))
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
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
            .buttonStyle(.plain)
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

/// Whether a subagent still runs (a small spinner), finished (a mint check) or failed (a coral cross).
struct SubagentStatusMark: View {
    let agent: SubagentInfo
    var size: CGFloat = 10

    var body: some View {
        Group {
            if agent.isRunning {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: agent.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(NookTheme.font(size, .semibold))
                    .foregroundStyle(agent.failed ? NookTheme.coralSoft : NookTheme.mint)
            }
        }
        .frame(width: 12)
    }
}

/// How long a running subagent has been at it, counting up; nothing once it is done (its row only keeps its outcome).
struct SubagentElapsed: View {
    let agent: SubagentInfo

    var body: some View {
        if agent.isRunning, agent.started > .distantPast {
            Text(timerInterval: agent.started...Date.distantFuture, countsDown: false)
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

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if agents.isEmpty {
                WSEmptyState(symbol: SessionTool.subagents.symbol, title: tr("ws.subagents.empty.title"),
                             message: tr("ws.subagents.empty.body"))
            } else {
                ToolSurface {
                    ScrollView {
                        SubagentList(agents: agents)
                            .padding(NookTheme.Spacing.lg)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Every subagent of a session, as the Subagents tab in the side panel shows them: a card each with its state, what
/// it was asked, its steps and what it answered, the running ones counting their time.
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
            ForEach(agents.filter(\.isRunning) + agents.filter { !$0.isRunning }.reversed()) { agent in
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
        .conversationCard(padding: NookTheme.Spacing.lg)
        .overlay {
            if agent.isRunning {
                RoundedRectangle(cornerRadius: NookTheme.Radius.conversationCard, style: .continuous)
                    .strokeBorder(NookTheme.iris.opacity(0.35), lineWidth: 1)
            }
        }
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
/// rest says itself on hover. The state badge opens it, as the arrow on hover does; the eye watches it (CI, reviews and
/// comments wake the agent) or stops.
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
            .buttonStyle(.plain)
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
            .fill(hovering ? NookTheme.rowHover : Color.clear))
        .opacity(isCurrent ? 1 : 0.72)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }

    /// The width of the state column when a session lists several branches (`BranchTrayRow` uses it too).
    static let stateColumn: CGFloat = 124

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
                    if ciOutcome == .failing { Text(ci) }
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coral)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
            Image(systemName: watching ? "eye.fill" : "eye.slash")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(watching ? NookTheme.mint : (hovering ? NookTheme.textSecondary : NookTheme.textTertiary))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

