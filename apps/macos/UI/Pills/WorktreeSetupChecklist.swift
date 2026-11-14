import SwiftUI

/// A new session's worktree being set up, step by step, at the end of its conversation until the agent answers:
/// fetch the base, check out the files, run the setup script, start the agent. Each step shows what it really took
/// (`WorktreeSetupProgress`), or "skipped"; Details says what each step did, Cancel stops the session.
struct WorktreeSetupChecklist: View {
    let progress: WorktreeSetupProgress
    /// The session still runs; when it is stopped or failed, a step that was running shows as stopped.
    let active: Bool
    let onCancel: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(headline)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(progress.failure != nil ? NookTheme.coral : NookTheme.textSecondary)
            NookDivider()
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                ForEach(WorktreeSetupProgress.Step.allCases, id: \.self) { step in
                    WorktreeSetupStepRow(title: tr(step.titleKey), state: progress.state(step), active: active)
                }
            }
            HStack(spacing: NookTheme.Spacing.lg) {
                Button {
                    withNookAnimation { showsDetails.toggle() }
                } label: {
                    Label(tr("ws.setup.details"), icon: showsDetails ? "chevron.down" : "chevron.right")
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .buttonStyle(.nookPlain)
                if active {
                    Button(action: onCancel) {
                        Label(tr("button.cancel"), icon: "xmark")
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    .buttonStyle(.nookPlain)
                    .help(tr("ws.setup.cancel.help"))
                }
            }
            .padding(.leading, NookTheme.Spacing.xxxl)
            if showsDetails {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    ForEach(progress.notes) { note in
                        Text(note.text)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let failure = progress.failure {
                        Text(failure.message)
                            .font(NookTheme.TextStyle.code)
                            .foregroundStyle(NookTheme.coral)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, NookTheme.Spacing.xxxl)
                .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        if progress.failure != nil { return tr("ws.setup.failed") }
        if !active { return tr("ws.setup.stopped") }
        return tr("ws.setup.title")
    }
}

/// One step: a check when done, a dash when skipped, a turning ring while it runs, an open circle before, a cross when
/// it failed; its time (or "skipped") at the end.
struct WorktreeSetupStepRow: View {
    let title: String
    let state: WorktreeSetupProgress.State
    let active: Bool

    var body: some View {
        HStack(spacing: NookTheme.Spacing.lg) {
            mark.frame(width: 16, height: 16)
            Text(title)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(isPending ? NookTheme.textTertiary : NookTheme.paper)
            Spacer(minLength: NookTheme.Spacing.md)
            trailing
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    @ViewBuilder
    private var mark: some View {
        switch state {
        case .done:
            Image(icon: "checkmark").font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.paper)
        case .skipped:
            Image(icon: "minus").font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.paper)
        case .running:
            if active {
                SpinningRing(color: NookTheme.paper)
            } else {
                Image(icon: "xmark").font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.textTertiary)
            }
        case .pending:
            Image(icon: "circle").font(NookTheme.font(13)).foregroundStyle(NookTheme.textTertiary)
        case .failed:
            Image(icon: "xmark.circle").font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.coral)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .done(let seconds):
            Text(WorktreeSetupProgress.duration(seconds))
        case .skipped:
            Text(tr("ws.setup.skipped"))
        case .running(let since):
            if active {
                // The time so far, once a second: only while a step runs, and only for a few seconds as a rule.
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    Text(elapsed >= 1 ? WorktreeSetupProgress.duration(elapsed.rounded(.down)) : "")
                }
            } else {
                Text(tr("ws.setup.stoppedStep"))
            }
        case .failed:
            Text(tr("ws.setup.failedStep")).foregroundStyle(NookTheme.coral)
        case .pending:
            EmptyView()
        }
    }
}
