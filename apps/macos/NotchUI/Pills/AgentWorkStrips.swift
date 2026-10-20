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
        let finished = progress.done >= progress.total
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(NookTheme.font(11, .semibold))
                    Text(tr("ws.tasks.title")).foregroundStyle(NookTheme.textTertiary)
                    Text(progress.current)
                        .foregroundStyle(NookTheme.paper.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text("\(progress.done)/\(progress.total)")
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(finished ? NookTheme.mint : NookTheme.textSecondary)
                    if steps.count > 1 && steps.count <= 10 { segments }
                    Image(systemName: "chevron.up")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("ws.tasks.accessibility", progress.done, progress.total, progress.current))
            if open {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: symbol(step.status))
                                .font(NookTheme.font(10, .semibold))
                                .foregroundStyle(color(step.status))
                                .frame(width: 12)
                            Text(step.text)
                                .font(NookTheme.font(12))
                                .foregroundStyle(step.status == .done ? NookTheme.textTertiary : NookTheme.textSecondary)
                                .strikethrough(step.status == .done, color: NookTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
    }

    private var segments: some View {
        HStack(spacing: 2) {
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
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(NookTheme.reveal) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "person.2").font(NookTheme.font(11, .semibold))
                    Text(tr("ws.subagents.title")).foregroundStyle(NookTheme.textTertiary)
                    Text(agents.first(where: \.isRunning)?.title ?? agents.last?.title ?? "")
                        .foregroundStyle(NookTheme.paper.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(tr("ws.subagents.progress", done, agents.count))
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(done == agents.count ? NookTheme.mint : NookTheme.textSecondary)
                    Image(systemName: "chevron.up")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agents) { agent in row(agent) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
    }

    private func row(_ agent: SubagentInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                shown = shown == agent.id ? nil : agent.id
            } label: {
                HStack(spacing: 8) {
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
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if shown == agent.id {
                VStack(alignment: .leading, spacing: 4) {
                    if !agent.prompt.isEmpty {
                        Text(ToolSummary.oneLine(agent.prompt, 400))
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                    if let output = agent.output, !output.isEmpty {
                        Text(ToolSummary.oneLine(output, 600))
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                }
                .font(NookTheme.font(11.5))
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

    var body: some View {
        HStack(spacing: 6) {
            ComposerPill(symbol: "eye", dot: nil, text: tr("ws.prwatch.watching"), showsChevron: false)
            // The state in the same badge as on the pull request page; CI and reviews after it.
            PullRequestStateBadge(glyph: PullRequestBadge.Glyph(rawValue: watch.state) ?? .open, number: number)
            if !summary.isEmpty {
                Text(summary)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if let url = URL(string: watch.url) {
                trayButton("arrow.up.right.square", tr("ws.prwatch.open")) { NSWorkspace.shared.open(url) }
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

    private var summary: String {
        var parts: [String] = []
        switch watch.checks {
        case "success": parts.append(tr("ws.prwatch.ciPassed"))
        case "failure": parts.append(tr("ws.prwatch.ciFailed"))
        case "pending": parts.append(tr("ws.prwatch.ciPending"))
        default: break
        }
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

/// "3 files changed" under a finished turn: opens the files, each with what this turn
/// did to it.
struct TurnChangesChip: View {
    let turn: TurnChanges.Turn
    let directory: String
    let diff: (String) async throws -> String
    @State private var open = false
    @State private var chosen: String?
    @State private var text: String?
    @State private var failure: String?

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.ellipsis").font(NookTheme.font(10.5, .semibold))
                Text(tr("ws.turnChanges.count", turn.files.count))
            }
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(NookTheme.paper.opacity(0.06)))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tr("ws.turnChanges.help"))
        .popover(isPresented: $open, arrowEdge: .bottom) { content.frame(width: 620, height: 420) }
    }

    private var content: some View {
        HStack(spacing: 0) {
            List(turn.files, id: \.self, selection: Binding<String?>(get: { chosen }, set: { pick($0) })) { path in
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).font(NookTheme.font(12, .medium)).lineLimit(1)
                    Text(relative(path)).font(NookTheme.font(10.5)).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.head)
                }
                .tag(path)
            }
            .frame(width: 200)
            Divider()
            Group {
                if let failure {
                    Text(failure).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.coralSoft).padding()
                } else if let text {
                    if text.isEmpty {
                        ListEmptyNote(tr("ws.turnChanges.none"), padding: NookTheme.Spacing.xl)
                    } else {
                        DiffText(text: text)
                    }
                } else if chosen != nil {
                    ProgressView().controlSize(.small)
                } else {
                    ListEmptyNote(tr("ws.turnChanges.pick"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if chosen == nil, let first = turn.files.first { pick(first) } }
    }

    private func pick(_ path: String?) {
        chosen = path
        text = nil
        failure = nil
        guard let path else { return }
        Task {
            do {
                let result = try await diff(path)
                if chosen == path { text = result }
            } catch {
                if chosen == path { failure = error.localizedDescription }
            }
        }
    }

    private func relative(_ path: String) -> String {
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
}
