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

/// "Subagents 1 of 3 done" with a row per subagent: its kind, what it does, and whether it still runs; a row opens
/// to its task and its answer.
struct SubagentBar: View {
    let agents: [SubagentInfo]
    @State private var open = false
    @State private var shown: UUID?

    var body: some View {
        let done = agents.filter { !$0.isRunning }.count
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(systemName: "person.2").font(NookTheme.font(11, .semibold))
                    Text(tr("ws.subagents.title")).foregroundStyle(NookTheme.textTertiary)
                    Text(agents.first(where: \.isRunning)?.title ?? agents.last?.title ?? "")
                        .foregroundStyle(NookTheme.paper.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(tr("ws.subagents.progress", done, agents.count))
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
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

    private func row(_ agent: SubagentInfo) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Button {
                shown = shown == agent.id ? nil : agent.id
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    if agent.isRunning {
                        ProgressView().controlSize(.mini).frame(width: 12)
                    } else {
                        Image(systemName: agent.state == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .font(NookTheme.font(10, .semibold))
                            .foregroundStyle(agent.state == .failed ? NookTheme.coralSoft : NookTheme.mint)
                            .frame(width: 12)
                    }
                    Text(agent.kind)
                        .font(NookTheme.mono(10.5, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(agent.title).lineLimit(1)
                    Spacer(minLength: 0)
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
                    if let output = agent.output, !output.isEmpty {
                        Text(ToolSummary.oneLine(output, 600))
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

/// "Watching PR [#12 · Open] CI passed · 2 reviews" with a way to open it and to stop: a row of the tray above the composer,
/// in the same pills as the tray under a new session's box.
struct PullRequestWatchStrip: View {
    let watch: PullRequestWatch
    let stop: () -> Void
    @Environment(\.pullRequestLinksBeside) private var pullRequestLinksBeside
    @State private var showsCI = false

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            ComposerPill(symbol: "eye", dot: nil, text: tr("ws.prwatch.watching"), showsChevron: false)
            // The state in the same badge as on the pull request page; CI and reviews after it. A click opens it.
            Button(action: open) {
                PullRequestStateBadge(glyph: PullRequestBadge.Glyph(rawValue: watch.state) ?? .open, number: number)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("ws.prwatch.open"))
            if let ci {
                // A click shows the checks and their logs (GitHub), or the pipelines page (GitLab).
                Button(action: openCI) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text(ci)
                        Image(systemName: "text.alignleft").font(NookTheme.font(9.5, .semibold))
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(watch.checks == "failure" ? NookTheme.coral : NookTheme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("ws.prwatch.ciHelp"))
                .popover(isPresented: $showsCI, arrowEdge: .top) {
                    if let url = URL(string: watch.url) { CIChecksPopover(pullRequest: url).frame(width: 680, height: 440) }
                }
            }
            if !summary.isEmpty {
                Text(summary)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if URL(string: watch.url) != nil {
                trayButton("arrow.up.right.square", tr("ws.prwatch.open"), action: open)
            }
            trayButton("xmark", tr("ws.prwatch.stop"), action: stop)
        }
        .foregroundStyle(NookTheme.textSecondary)
    }

    private func trayButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol, label, height: 22, width: 22, action)
    }

    /// "…/pull/12" or "…/-/merge_requests/12".
    private var number: Int? { URL(string: watch.url).flatMap { Int($0.lastPathComponent) } }

    private var ci: String? {
        switch watch.checks {
        case "success": return tr("ws.prwatch.ciPassed")
        case "failure": return tr("ws.prwatch.ciFailed")
        case "pending": return tr("ws.prwatch.ciPending")
        default: return nil
        }
    }

    /// A GitHub pull request opens in Nook, as a link to it in the conversation does: in the session's side panel. A
    /// GitLab merge request (or no GitHub account) opens in your browser.
    private func open() {
        guard let url = URL(string: watch.url) else { return }
        if !AppModel.shared.openPullRequestLink(url, beside: pullRequestLinksBeside) { NSWorkspace.shared.open(url) }
    }

    private func openCI() {
        guard let url = URL(string: watch.url) else { return }
        if GitHubPullRequests.parse(url) != nil {
            showsCI.toggle()
        } else {
            // A GitLab merge request: its pipelines have their own page.
            NSWorkspace.shared.open(url.appendingPathComponent("pipelines"))
        }
    }

    private var summary: String {
        var parts: [String] = []
        if watch.reviewCount > 0 { parts.append(tr("ws.prwatch.reviews", watch.reviewCount)) }
        if watch.checkedAt == nil { parts.append(tr("ws.prwatch.loading")) }
        return parts.joined(separator: " · ")
    }
}

/// A thin column next to the conversation with a mark per message of yours: hover shows the
/// message, a click goes there.
struct TurnMinimap: View {
    let turns: [RunEvent]
    let jump: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(turns) { turn in
                Button { jump(turn.id) } label: {
                    Capsule().fill(NookTheme.textTertiary.opacity(0.6)).frame(width: 8, height: 3)
                        .frame(maxHeight: .infinity)
                        .frame(width: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ToolSummary.oneLine(turn.text, 120))
            }
        }
        .frame(width: 14)
        .frame(maxHeight: CGFloat(turns.count) * 18)
    }
}

