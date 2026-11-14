import SwiftUI
import AppKit

/// One run of a workflow, opened from the Actions page: how it went with its clock, what it ran on (branch, commit,
/// what started it and who), and its jobs. A job opens in place with its steps and log (`CICheckLogView`, the same view
/// a check on a pull request opens in). Re-run (all jobs, or only the failed ones) and cancel ask first and are one
/// GitHub call each. While the run is not done, it is read again every few seconds. A finished run without jobs has
/// no log on GitHub, so it says why instead (`WorkflowRunNoJobs`): the newer run that replaced it, or the workflow file
/// that kept it from starting.
struct WorkflowRunDetail: View {
    @EnvironmentObject private var app: AppModel
    let repo: String
    let run: WorkflowRun
    let onClose: () -> Void
    @State private var fresh: WorkflowRun?
    @State private var jobs: [WorkflowJob] = []
    @State private var loaded = false
    @State private var failure: String?
    /// Why the finished run has no jobs; nil while it runs or when it has jobs.
    @State private var noJobs: WorkflowRunNoJobs?
    @State private var openJob: WorkflowJob?
    /// The action sent right now, for its spinner.
    @State private var sending: WorkflowRunAction?
    /// The action waiting for your yes.
    @State private var asking: WorkflowRunAction?
    /// Bumped after an action, so the run is followed again from its new start.
    @State private var generation = 0

    private var current: WorkflowRun { fresh ?? run }
    private static let followInterval: UInt64 = 5_000_000_000

    var body: some View {
        Group {
            if let job = openJob {
                CICheckLogView(pullRequest: nil, repository: repo, check: (jobs.first { $0.id == job.id } ?? job).check) {
                    openJob = nil
                }
                .id(job.id)
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    header
                    actionRow
                    jobList
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: generation) { await follow() }
        .confirmationDialog(asking.map(question) ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible) {
            if let action = asking {
                Button(title(action), role: action == .cancel ? .destructive : nil) { perform(action) }
                Button(tr("button.cancel"), role: .cancel) {}
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24, action: onClose)
                CheckOutcomeGlyph(outcome: current.outcome, size: 16, running: current.running)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(current.title)
                        .font(NookTheme.TextStyle.title)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    CICheckStatusText(check: current.check)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                if let url = current.url {
                    ToolbarIconButton("doc.on.doc", tr("agents.pr.copyLink")) {
                        Pasteboard.copy(url.absoluteString)
                        ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                    }
                    ToolbarIconButton("arrow.up.right.square", tr("actions.openOnGitHub")) { NSWorkspace.shared.open(url) }
                }
            }
            facts
                .padding(.leading, 24 + NookTheme.Spacing.sm)
        }
    }

    /// "CI #482 · main · 1a2b3c4 · Push · @ada", each part one you can copy from the menu on the line.
    private var facts: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            fact(symbol: "play.circle", text: current.name + " #\(current.number)"
                 + (current.attempt > 1 ? " (\(tr("actions.attempt", current.attempt)))" : ""))
            if !current.branch.isEmpty { fact(symbol: "arrow.triangle.branch", text: current.branch) }
            if !current.sha.isEmpty { fact(symbol: "number", text: current.shortSHA, mono: true) }
            fact(symbol: "bolt", text: WorkflowRunWords.event(current.event))
            if !current.actor.isEmpty {
                HStack(spacing: NookTheme.Spacing.xs) {
                    GitHubAvatar(login: current.actor, size: 14)
                    Text("@" + current.actor)
                }
            }
        }
        .font(NookTheme.TextStyle.caption)
        .foregroundStyle(NookTheme.textTertiary)
        .lineLimit(1)
        .contextMenu {
            if !current.branch.isEmpty {
                Button(tr("agents.pr.copyBranch")) { Pasteboard.copy(current.branch) }
            }
            if !current.sha.isEmpty {
                Button(tr("actions.copySHA")) { Pasteboard.copy(current.sha) }
            }
        }
    }

    private func fact(symbol: String, text: String, mono: Bool = false) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(icon: symbol)
            Text(text).font(mono ? NookTheme.mono(11) : NookTheme.TextStyle.caption)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionRow: some View {
        let actions = available
        if !actions.isEmpty {
            HStack(spacing: NookTheme.Spacing.sm) {
                ForEach(actions, id: \.self) { action in
                    if sending == action {
                        ProgressView().controlSize(.small).frame(width: 28)
                    } else {
                        SmallGhostButton(title: title(action)) { asking = action }
                            .disabled(sending != nil)
                    }
                }
                if current.waitsForApproval {
                    Text(tr("actions.waitsForApproval"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.amber)
                }
            }
        }
    }

    private var available: [WorkflowRunAction] {
        var result: [WorkflowRunAction] = []
        if current.canRerunFailed { result.append(.rerunFailed) }
        if current.canRerun { result.append(.rerun) }
        if current.canCancel { result.append(.cancel) }
        return result
    }

    private func title(_ action: WorkflowRunAction) -> String {
        switch action {
        case .rerun: return tr("actions.rerun")
        case .rerunFailed: return tr("actions.rerunFailed")
        case .cancel: return tr("actions.cancel")
        }
    }

    private func question(_ action: WorkflowRunAction) -> String {
        let target = current.name + " #\(current.number)"
        switch action {
        case .rerun: return tr("actions.confirm.rerun", target)
        case .rerunFailed: return tr("actions.confirm.rerunFailed", target)
        case .cancel: return tr("actions.confirm.cancel", target)
        }
    }

    /// Only after your yes: sends the action, writes it to the action log, and follows the run again from its new start.
    private func perform(_ action: WorkflowRunAction) {
        asking = nil
        sending = action
        let args = "\(repo) run \(current.id)"
        Task {
            do {
                let token = try await ActionsStore.shared.token(for: repo)
                try await GitHubActions.perform(action, repo: repo, runID: current.id, token: token)
                app.store.audit(tool: action.auditTool, args: args, result: "ok")
                ToastCenter.shared.success(tr(action == .cancel ? "actions.toast.cancelled" : "actions.toast.rerun"))
                // GitHub takes a moment before the run reads as queued again (or cancelled).
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                sending = nil
                noJobs = nil
                generation += 1
                await ActionsStore.shared.refresh()
            } catch {
                app.store.audit(tool: action.auditTool, args: args, result: "error: " + error.localizedDescription)
                sending = nil
                ToastCenter.shared.error(error, title: tr("toast.failed", title(action)))
            }
        }
    }

    // MARK: Jobs

    @ViewBuilder
    private var jobList: some View {
        if let failure, jobs.isEmpty {
            InlineErrorText(failure)
                .padding(.horizontal, NookTheme.Spacing.xs)
        } else if !loaded {
            // The jobs' shape while they are read: a heading and a few rows.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                PullRequestGhostBar(width: 40, height: 9).padding(.horizontal, NookTheme.Spacing.xs)
                ForEach([150, 110, 180] as [CGFloat], id: \.self) { width in
                    HStack(spacing: NookTheme.Spacing.md) {
                        Circle().fill(NookTheme.rowHover).frame(width: 13, height: 13)
                        PullRequestGhostBar(width: width, height: 10)
                        Spacer(minLength: NookTheme.Spacing.sm)
                        PullRequestGhostBar(width: 72, height: 8)
                    }
                    .padding(.horizontal, NookTheme.Spacing.md)
                    .padding(.vertical, NookTheme.Spacing.sm + 2)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("actions.loading"))
        } else if jobs.isEmpty, let noJobs {
            WorkflowRunNoJobsNote(run: current, reason: noJobs)
        } else if jobs.isEmpty {
            ListEmptyNote(tr(current.isCompleted ? "actions.jobs.none" : "actions.jobs.waiting"), padding: NookTheme.Spacing.xs)
        } else {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                NookSectionLabel(tr("actions.jobs"), inset: NookTheme.Spacing.xs)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(jobs) { job in
                            WorkflowJobRow(job: job) { openJob = job }
                        }
                    }
                    .padding(.bottom, NookTheme.Spacing.lg)
                }
            }
        }
    }

    /// Reads the run and its jobs, and again every few seconds until the run and every job are done.
    private func follow() async {
        while !Task.isCancelled {
            do {
                let token = try await ActionsStore.shared.token(for: repo)
                async let latest = GitHubActions.run(repo: repo, id: run.id, token: token)
                let list = try await GitHubActions.jobs(repo: repo, runID: run.id, token: token)
                let updated = try? await latest
                // Read once, when the run is done and turned out to have no jobs.
                var reason = noJobs
                if reason == nil, let updated {
                    reason = await GitHubActions.noJobs(repo: repo, run: updated, jobs: list, token: token)
                }
                guard !Task.isCancelled else { return }
                withAnimation(NookTheme.swap) {
                    jobs = list
                    if let updated { fresh = updated }
                    noJobs = list.isEmpty && current.isCompleted ? reason : nil
                }
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                if jobs.isEmpty { failure = error.localizedDescription }
            }
            loaded = true
            if current.isCompleted && jobs.allSatisfy({ $0.status == "completed" }) { return }
            try? await Task.sleep(nanoseconds: Self.followInterval)
        }
    }
}

/// Why a finished run has no jobs, in place of its job list: a sentence and the pages that say more (the run that
/// replaced it, or its workflow file, and the run on GitHub).
private struct WorkflowRunNoJobsNote: View {
    let run: WorkflowRun
    let reason: WorkflowRunNoJobs

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: NookTheme.Spacing.sm) {
                if let link {
                    SmallGhostButton(title: link.title) { NSWorkspace.shared.open(link.url) }
                }
                if let url = run.url {
                    SmallGhostButton(title: tr("actions.noJobs.openRun")) { NSWorkspace.shared.open(url) }
                }
            }
        }
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private var text: String {
        let noLog = tr("actions.noJobs.noLog")
        switch reason {
        case .replaced(_, let number, _):
            let key = run.branch.isEmpty ? "actions.noJobs.replaced" : "actions.noJobs.replacedOnBranch"
            let sentence = run.branch.isEmpty ? tr(key, run.name, number) : tr(key, run.name, run.branch, number)
            return sentence + " " + noLog
        case .cancelled: return tr("actions.noJobs.cancelled") + " " + noLog
        case .workflowError(let path, _): return tr("actions.noJobs.workflowError", path.isEmpty ? tr("actions.noJobs.workflowFile") : path)
        case .skipped: return tr("actions.noJobs.skipped")
        case .approval: return tr("actions.noJobs.approval")
        case .empty: return tr("actions.jobs.none") + " " + noLog
        }
    }

    private var link: (title: String, url: URL)? {
        switch reason {
        case .replaced(_, let number, let url?): return (tr("actions.noJobs.openReplacement", number), url)
        case .workflowError(_, let file?): return (tr("actions.noJobs.openWorkflowFile"), file)
        default: return nil
        }
    }
}

/// One job of a run: its mark, its name, and how it went with its clock. Opens its steps and log.
private struct WorkflowJobRow: View {
    let job: WorkflowJob
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        let check = job.check
        Button(action: onOpen) {
            HStack(spacing: NookTheme.Spacing.md) {
                CheckOutcomeGlyph(outcome: check.outcome, size: 13, running: check.running)
                    .frame(width: 16)
                Text(job.name)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(check.outcome == .skipped ? NookTheme.textTertiary : NookTheme.textStrong)
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.sm)
                CICheckStatusText(check: check)
                    .fixedSize()
                Image(icon: "chevron.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .hoverRowFill($hovering, rest: NookTheme.rowRest)
        .help(tr("actions.job.open"))
    }
}
