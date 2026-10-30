import SwiftUI

// The agent's work between the messages of a conversation, one set of views for every agent: a session Nook runs
// (`AgentRunPanel`, from its `RunEvent`s) and an agent's own transcript (`TranscriptConversation`, from its
// `AgentChatMessage`s) both draw their steps, thoughts, groups, folded turns and live line with these. Each side only
// translates its own data into them; change a line here and both follow.

// MARK: Lines

/// One line of the agent's work: an icon, what it did in muted text, and a chevron when it opens. The line that runs now
/// shimmers.
struct TranscriptWorkLine: View {
    let symbol: String
    let label: String
    /// What the work was done to (a command, a file, a pattern), after the label in quieter text; in monospace with `mono`.
    var detail: String? = nil
    var mono = false
    var failed = false
    var live = false
    /// The color of the icon and the words when the line carries a state (waiting on you); nil for the quiet grey.
    var tint: Color? = nil
    /// The tests, builds and linters it stands for, and how they went.
    var checks: [VerificationCheck] = []
    /// The lines its edits added and removed.
    var lines: EditLines? = nil
    /// Nil: the line does not open.
    var open: Bool? = nil
    /// Nil: the line has no file to show; true while its file is open in the side panel.
    var reveals: Bool? = nil
    /// A line that takes you somewhere else (a diff, the terminal): the symbol that says where, shown under the pointer.
    var link: String? = nil
    /// The chevron shows under the pointer only (and while open), as a tool call's does: a single step keeps its line
    /// bare at rest.
    var quietChevron = false
    var action: (() -> Void)? = nil
    @State private var hovering = false

    private var clickable: Bool { open != nil || reveals != nil || link != nil }

    /// The label, then its detail on the same line, so a long command or path truncates as one sentence.
    private var labelText: Text {
        let color = tint ?? (reveals == true ? NookTheme.paper : hovering && clickable ? NookTheme.textSecondary : NookTheme.textTertiary)
        let head = Text(label).foregroundStyle(color)
        guard let detail, !detail.isEmpty else { return head }
        return head + Text(" ") + Text(detail)
            .font(mono ? NookTheme.mono(12) : NookTheme.TextStyle.body)
            .foregroundStyle(color)
    }

    var body: some View {
        let content = HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: failed ? "exclamationmark.circle" : symbol)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(failed ? NookTheme.coral.opacity(0.6) : (tint ?? NookTheme.textTertiary))
                .frame(width: TranscriptStyle.workIcon)
            if live {
                ShimmerText(text: label)
                    .lineLimit(1)
            } else {
                labelText
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let open {
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(9, .bold))
                    .foregroundStyle(NookTheme.textTertiary.opacity(0.7))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(!quietChevron || open || hovering ? 1 : 0)
            }
            if failed {
                Image(systemName: "xmark").font(NookTheme.font(9, .bold)).foregroundStyle(NookTheme.coral.opacity(0.6))
            }
            if let reveals {
                Image(systemName: "sidebar.right")
                    .font(NookTheme.font(9.5, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(reveals || hovering ? 1 : 0)
            }
            if let link {
                Image(systemName: link)
                    .font(NookTheme.font(9.5, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            if let lines { EditLinesLabel(lines: lines, size: 11) }
            if !checks.isEmpty { VerificationChips(checks: checks) }
            Spacer(minLength: 0)
        }
        .font(NookTheme.TextStyle.body)
        .frame(minHeight: 24)
        .contentShape(Rectangle())

        if let action, clickable {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(open == true || reveals == true ? .isSelected : [])
        } else {
            content
        }
    }
}

/// The agent's reasoning on one line (its headline), the whole of it a click away, indented under the line.
struct TranscriptThought: View {
    let text: String
    let open: Bool
    /// Still being written: the line shimmers.
    var live = false
    let toggle: () -> Void

    var body: some View {
        let headline = TranscriptPresentation.headline(text)
        let more = headline != text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            TranscriptWorkLine(symbol: "brain", label: headline.isEmpty ? tr("agents.thought") : headline, live: live,
                               open: more ? open : nil) { if more { toggle() } }
            if more, open {
                Text(text)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, TranscriptStyle.workIndent)
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
        }
    }
}

/// Under a step's line: why it failed, on one line, then (while the step is open) its command line and what it gave
/// back, or the task list it set. Indented to the words of the line above.
struct TranscriptStepDetail: View {
    var error: String? = nil
    let open: Bool
    var command: String? = nil
    var output: String? = nil
    var failed = false
    var tasks: [RunTaskStep]? = nil

    var body: some View {
        if let error, !error.isEmpty {
            Text(error)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, TranscriptStyle.workIndent)
                .padding(.bottom, NookTheme.Spacing.xxs)
                .help(error)
        }
        if open, let tasks, !tasks.isEmpty {
            TaskListRows(steps: tasks)
                .padding(NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.field))
                .padding(.leading, TranscriptStyle.workIndent)
                .padding(.bottom, NookTheme.Spacing.xs)
        } else if open, command != nil || output != nil {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                if let command { CodeBlock(title: tr("ws.tool.input"), text: command) }
                if let output { CodeBlock(title: tr("ws.tool.output"), text: output, failed: failed) }
            }
            .padding(.leading, TranscriptStyle.workIndent)
            .padding(.bottom, NookTheme.Spacing.xs)
        }
    }
}

// MARK: Groups and folds

/// Steps in a row behind one sentence ("Ran 3 commands, read 2 files ›"); open, the steps in a short scroll of their own,
/// which keeps a step that joins during a live turn in view at its end.
struct TranscriptWorkGroup<Steps: View>: View {
    let tally: ToolTally
    let open: Bool
    let toggle: () -> Void
    @ViewBuilder var steps: () -> Steps

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(tally), label: ToolTallyText.sentence(tally),
                               failed: tally.failed, checks: tally.checks, lines: tally.lines, open: open, action: toggle)
            if open {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) { steps() }
                }
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .frame(maxHeight: 288)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A finished turn's work, folded under "Worked for 1m 3s ›"; open, its rows under the line.
struct TranscriptFold<Rows: View>: View {
    let text: String
    let open: Bool
    var checks: [VerificationCheck] = []
    /// The hairline under the line; off when another rule follows right away.
    var ruled = true
    let toggle: () -> Void
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TranscriptFoldLine(text: text, open: open, checks: checks, ruled: ruled, action: toggle)
            if open {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) { rows() }
                    .padding(.bottom, NookTheme.Spacing.xs)
            }
        }
        .padding(.bottom, NookTheme.Spacing.xxs)
    }
}

/// A finished turn's work, folded: "Worked for 1m 3s ›" over a hairline.
struct TranscriptFoldLine: View {
    let text: String
    let open: Bool
    /// What the turn's tests and builds came to, in sight while its work is folded.
    var checks: [VerificationCheck] = []
    /// The hairline under the line; off when another rule follows right away.
    var ruled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(text)
                Image(systemName: "chevron.right")
                    .font(NookTheme.font(9, .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                if !checks.isEmpty { VerificationChips(checks: checks) }
                Spacer(minLength: 0)
            }
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(hovering ? NookTheme.paper.opacity(0.85) : NookTheme.textTertiary)
            .padding(.top, NookTheme.Spacing.xxs)
            .padding(.bottom, NookTheme.Spacing.md)
            .overlay(alignment: .bottom) { if ruled { NookDivider() } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

// MARK: The turn that runs

/// Right under your message while the agent works: "Working for 12s", ticking, over a hairline.
struct TranscriptWorkingLine: View {
    let since: Date?

    var body: some View {
        Group {
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(tr("agents.timeline.workingFor", AgentPathFormat.duration(max(0, context.date.timeIntervalSince(since)))))
                        .monospacedDigit()
                }
            } else {
                Text(tr("ws.timeline.working"))
            }
        }
        .font(NookTheme.TextStyle.body)
        .foregroundStyle(NookTheme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, NookTheme.Spacing.xxs)
        .padding(.bottom, NookTheme.Spacing.md)
        .overlay(alignment: .bottom) { NookDivider() }
    }
}

/// At the end of the turn that runs: the agent's task list, then what it does now in words ("Running the tests"),
/// shimmering. Waiting on you, the line says so in amber instead; with a command running, a click opens its terminal.
struct TranscriptLiveLine: View {
    let activity: AgentActivity
    /// The task list as the agent keeps it, shown above the line; nil when it has none (or it shows elsewhere).
    var tasks: [RunTaskStep]? = nil
    /// Waiting for your approval, or (`asking`) for your answer to a question.
    var waiting = false
    var asking = false
    /// Opens the terminal with the command that runs; nil when no command runs.
    var openConsole: (() -> Void)? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let tasks { TaskChecklistCard(steps: tasks) }
            if waiting {
                TranscriptWorkLine(symbol: asking ? "questionmark.bubble" : "hand.raised",
                                   label: tr(asking ? "ws.timeline.asking" : "ws.timeline.waiting"), tint: NookTheme.amber)
            } else if activity.asksYou {
                // Its app asks you in a prompt of its own ("Take over the screen?"): the line waits on you, in amber.
                TranscriptWorkLine(symbol: AgentActivityText.symbol(activity), label: AgentActivityText.headline(activity),
                                   tint: NookTheme.amber)
            } else {
                TranscriptWorkLine(symbol: AgentActivityText.symbol(activity),
                                   label: AgentActivityText.headline(activity, step: tasks.flatMap(TaskChecklist.activeStep)),
                                   live: true, link: openConsole == nil ? nil : "sidebar.left", action: openConsole)
                    .help(openConsole == nil ? (help ?? "") : tr("ws.console.open"))
            }
        }
    }
}

// MARK: Words and symbols

/// How a step reads: what the agent did as a verb ("Ran", "Edited"), then what it did that to, instead of the bare
/// name of the tool. A tool Nook does not know keeps its own name.
enum TranscriptStepText {
    /// `detail` is the command, file, pattern or task; `mono` when it is code or a path rather than words.
    static func parts(_ step: AgentToolStep) -> (verb: String, detail: String, mono: Bool) {
        let summary = step.summary
        switch step.name {
        case "Task", "Agent": return (tr("agents.step.delegated"), summary, false)
        case "TodoWrite", "Plan", "update_plan": return (tr("agents.step.tasks"), "", false)
        case "ExitPlanMode": return (tr("agents.step.plan"), "", false)
        case "WebSearch", "web_search", "google_web_search": return (tr("agents.step.searchedWeb"), summary, false)
        case "WebFetch", "web_fetch": return (tr("agents.step.fetched"), summary, true)
        case "Skill": return (tr("agents.step.skill"), summary, true)
        default: break
        }
        let name = step.name.lowercased()
        switch ToolCategory.of(tool: step.name) {
        case .command:
            // A description says in words what the command does; without one the command line itself shows.
            let described = step.command.map { $0 != summary } ?? false
            return (tr("agents.step.ran"), summary, !described)
        case .edit:
            return (tr(["write", "write_file"].contains(name) ? "agents.step.wrote" : "agents.step.edited"), summary, true)
        case .read:
            return (tr(["ls", "list_directory"].contains(name) ? "agents.step.listed" : "agents.step.read"), summary, true)
        case .search:
            return (tr("agents.step.searched"), summary, true)
        case .other:
            // Nook's own workspace tools and other MCP tools by their label ("GitHub › Create issue"), not their raw name.
            if step.name.hasPrefix(BridgeTool.toolPrefix), let bridge = BridgeTool.named(step.name) {
                return (bridge.label, summary, false)
            }
            if let action = ScreenAction(tool: step.name) { return (tr("ws.screen." + action.rawValue + ".done"), summary, false) }
            if let mcp = McpToolName(step.name) { return (mcp.label, summary, false) }
            return (step.name, summary, false)
        }
    }
}

/// The icon of a step, after the kind of work it does.
enum TranscriptSymbols {
    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Task", "Agent": return "person.2"
        case "TodoWrite", "Plan", "update_plan", "ExitPlanMode": return "checklist"
        case "WebSearch", "WebFetch", "web_search", "web_fetch", "google_web_search": return "globe"
        case "Skill": return "sparkles"
        default:
            switch ToolCategory.of(tool: tool) {
            case .command: return "terminal"
            case .edit: return "square.and.pencil"
            case .read: return "eye"
            case .search: return "magnifyingglass"
            case .other:
                if let action = ScreenAction(tool: tool) { return AgentActivityText.symbol(action) }
                return tool.hasPrefix("mcp") ? "puzzlepiece.extension" : "wrench"
            }
        }
    }

    /// One kind of work keeps its own icon; mixed work gets a hammer.
    static func symbol(_ tally: ToolTally) -> String {
        let parts = tally.parts
        guard parts.count == 1, let category = parts.first?.category else { return "hammer" }
        switch category {
        case .command: return "terminal"
        case .edit: return "square.and.pencil"
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .other: return "wrench"
        }
    }
}
