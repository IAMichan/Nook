import SwiftUI

// How a session shows its progress while the agent works: the live task list in the timeline, what the agent does
// right now in words (see AgentProgress), and the outcome of the tests, builds and linters it ran.

/// "Running the tests", "Reading index.html": the live line's words, and its icon.
enum AgentActivityText {
    /// `step`: the task the agent works on, for when nothing it does names itself (it thinks without saying about what).
    static func headline(_ activity: AgentActivity, step: String? = nil) -> String {
        switch activity {
        case .starting: return tr("ws.activity.starting")
        case .running(let command): return subject("ws.activity.running", command)
        case .verifying(let kind): return tr("ws.activity.verifying." + key(kind))
        case .reading(let file): return subject("ws.activity.reading", file)
        case .editing(let file): return subject("ws.activity.editing", file)
        case .searching(let pattern): return subject("ws.activity.searching", pattern)
        case .browsing(let query): return subject("ws.activity.browsing", query)
        case .delegating(let task): return subject("ws.activity.delegating", task)
        case .planning: return tr("ws.activity.planning")
        case .using(let tool): return subject("ws.activity.using", tool)
        case .thinking(let headline):
            if !headline.isEmpty { return headline }
            return step.flatMap { $0.isEmpty ? nil : $0 } ?? tr("ws.activity.thinking")
        case .writing: return tr("ws.activity.writing")
        case .reviewing: return tr("ws.activity.reviewing")
        case .recovering: return tr("ws.activity.recovering")
        }
    }

    static func symbol(_ activity: AgentActivity) -> String {
        switch activity {
        case .starting: return "sparkles"
        case .running: return "terminal"
        case .verifying: return "checkmark.seal"
        case .reading: return "eye"
        case .editing: return "square.and.pencil"
        case .searching: return "magnifyingglass"
        case .browsing: return "globe"
        case .delegating: return "person.2"
        case .planning: return "checklist"
        case .using: return "wrench"
        case .thinking: return "brain"
        case .writing: return "text.cursor"
        case .reviewing: return "doc.text.magnifyingglass"
        case .recovering: return "arrow.triangle.2.circlepath"
        }
    }

    static func key(_ kind: VerificationCheck.Kind) -> String {
        switch kind {
        case .tests: return "tests"
        case .typecheck: return "typecheck"
        case .lint: return "lint"
        case .build: return "build"
        }
    }

    /// "Reading index.html", or "Reading a file" when there is nothing to name.
    private static func subject(_ key: String, _ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? tr(key + ".any") : tr(key, value)
    }
}

/// "Tests passed", "Build failed": a small tinted label per check.
struct VerificationChips: View {
    let checks: [VerificationCheck]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(checks, id: \.kind) { check in
                HStack(spacing: 3) {
                    Image(systemName: Self.symbol(check.outcome)).font(NookTheme.font(8.5, .bold))
                    Text(Self.text(check)).lineLimit(1)
                }
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(Self.color(check.outcome))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Self.color(check.outcome).opacity(0.12)))
                .help(check.command)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize()
    }

    static func text(_ check: VerificationCheck) -> String {
        let outcome: String
        switch check.outcome {
        case .passed: outcome = "passed"
        case .failed: outcome = "failed"
        case .running: outcome = "running"
        }
        return tr("ws.check." + AgentActivityText.key(check.kind) + "." + outcome)
    }

    private static func symbol(_ outcome: VerificationCheck.Outcome) -> String {
        switch outcome {
        case .passed: return "checkmark"
        case .failed: return "xmark"
        case .running: return "circle.dotted"
        }
    }

    private static func color(_ outcome: VerificationCheck.Outcome) -> Color {
        switch outcome {
        case .passed: return NookTheme.mint
        case .failed: return NookTheme.coralSoft
        case .running: return NookTheme.textSecondary
        }
    }
}

/// The agent's task list in the timeline while it works, as Claude Code shows it: every step with a check when done,
/// a spinning ring on the one that runs and an open circle for what is still to do. It folds to its header.
struct TaskChecklistCard: View {
    let steps: [RunTaskStep]
    @State private var collapsed = false

    var body: some View {
        let progress = RunTasks.progress(steps)
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(NookTheme.reveal) { collapsed.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checklist").font(NookTheme.font(10.5, .semibold))
                    Text(tr("ws.tasks.title")).font(NookTheme.font(11.5, .semibold))
                    Text(tr("ws.checklist.progress", progress.done, progress.total))
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .foregroundStyle(NookTheme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr(collapsed ? "ws.checklist.expand" : "ws.checklist.collapse"))
            .accessibilityLabel(tr("ws.tasks.accessibility", progress.done, progress.total, progress.current))
            if !collapsed {
                TaskListRows(steps: steps).transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(NookTheme.field, stroke: NookTheme.line2, radius: 12, style: .continuous)
        .animation(NookTheme.reveal, value: steps)
    }
}

/// One step of a task list: a check when done, a spinning ring on the one that runs, an open circle for what is to do.
struct TaskStepRow: View {
    let step: RunTaskStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            mark.frame(width: 13, height: 13).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(step.text)
                .font(NookTheme.font(12.5, step.status == .active ? .medium : .regular))
                .foregroundStyle(step.status == .active ? NookTheme.paper : step.status == .done ? NookTheme.textTertiary : NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(tr("ws.checklist.step." + step.status.rawValue))
    }

    @ViewBuilder
    private var mark: some View {
        switch step.status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(NookTheme.font(11.5, .semibold))
                .foregroundStyle(NookTheme.mint)
        case .active:
            SpinningRing(color: NookTheme.paper)
        case .pending:
            Image(systemName: "circle.dashed")
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textTertiary)
        }
    }
}

/// A ring with a gap that turns: the step that runs now.
struct SpinningRing: View {
    let color: Color
    @State private var turning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.2), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(turning ? 360 : 0))
        }
        .padding(1)
        .onAppear {
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
        }
    }
}
