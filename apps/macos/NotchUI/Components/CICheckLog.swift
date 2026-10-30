import SwiftUI
import AppKit

/// One CI check read in Nook: its name, outcome and clock, the steps of its GitHub Actions job and the end of its log.
/// While the job runs it is followed live: the step that runs turns and counts up, the bar fills as steps finish, and the
/// log takes the steps' place as soon as GitHub has it (GitHub hands out a job's log only once the job is done). The CI
/// popover of a watched pull request and the checks on a pull request page both show it, so a check never has to be
/// read on GitHub. A check from another app (CodeRabbit, a deploy, a commit status) shows its report instead: what it
/// says about the commit, its remarks on lines of code, and what the app wrote on the pull request.
struct CICheckLogView: View {
    /// The pull request the check belongs to; nil for a job of a repository's own runs (the Actions page), which
    /// passes `repository` instead.
    let pullRequest: URL?
    var repository: String? = nil
    let check: PullRequestCheck
    /// The back button before the name, on a page that showed the check in place of something else.
    var onBack: (() -> Void)?
    @State private var log: CILog?
    @State private var report: CICheckReport?
    @State private var failure: String?
    /// nil until the reader picks: a log with errors opens on them, one without opens whole.
    @State private var showFullLog: Bool?
    /// The steps above a log, folded away by default so the log has the room.
    @State private var showSteps = false

    /// How often a running job is read again.
    private static let followInterval: UInt64 = 3_000_000_000
    /// How often the report of a check that still runs is read again: three requests a turn, so less often.
    private static let reportInterval: UInt64 = 10_000_000_000

    private var isJob: Bool { CILogParser.jobID(from: check.url) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            header
            if let failure {
                message(failure)
            } else if !isJob {
                if let report {
                    reportView(report)
                } else {
                    PatientSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let log {
                if log.text == nil {
                    timeline(log)
                    liveFooter
                } else {
                    foldedSteps(log)
                    logText(log)
                }
            } else {
                PatientSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: isJob ? check.id : check.id + check.outcome.rawValue) { await (isJob ? follow() : followReport()) }
    }

    // MARK: Header

    /// What the job says once it is read, else what the check said: a check read a while ago may still say "running".
    private var outcome: PullRequestCheck.Outcome {
        guard let log, log.finished != nil, check.outcome == .pending else { return check.outcome }
        return log.steps.contains { $0.outcome == .failing } ? .failing : .passing
    }

    private var running: Bool { outcome == .pending && (log?.runningStep != nil || check.running) }

    private var header: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if let onBack { NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24, action: onBack) }
                CheckOutcomeGlyph(outcome: outcome, size: 14, running: running)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
                    CICheckStatusText(check: check, outcome: outcome, running: running,
                                      started: log?.started ?? check.started, finished: log?.finished ?? check.finished,
                                      progress: log.flatMap(progress))
                }
                Spacer(minLength: 0)
                if let text = log?.text ?? report?.plainText, !text.isEmpty {
                    ToolbarIconButton("doc.on.doc", tr("ws.ci.copy")) { Pasteboard.copy(text) }
                }
                if let url = check.url {
                    ToolbarIconButton("arrow.up.right.square", tr("ws.ci.open")) { NSWorkspace.shared.open(url) }
                }
            }
            if running, let log, !log.steps.isEmpty {
                ProgressBar(fraction: Double(log.doneSteps) / Double(log.steps.count))
            }
        }
    }

    /// "Step 8 of 15" while the job runs.
    private func progress(_ log: CILog) -> String? {
        guard outcome == .pending, let step = log.runningStep,
              let index = log.steps.firstIndex(of: step) else { return nil }
        return tr("ws.ci.stepOf", index + 1, log.steps.count)
    }

    // MARK: Steps

    /// A running job's steps over the whole height, one per row with its clock: the one that runs is lit and counts up,
    /// the ones still to come are quiet, and the list keeps the running step in view.
    private func timeline(_ log: CILog) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        ForEach(log.steps, id: \.number) { step in
                            stepRow(step, now: context.date).id(step.number)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToRunning(log, proxy) }
            .onChange(of: log.runningStep?.number) { _, _ in withAnimation(NookTheme.scroll) { scrollToRunning(log, proxy) } }
        }
        .frame(maxHeight: .infinity)
    }

    private func scrollToRunning(_ log: CILog, _ proxy: ScrollViewProxy) {
        if let step = log.runningStep { proxy.scrollTo(step.number, anchor: .center) }
    }

    private func stepRow(_ step: CILog.Step, now: Date) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            CheckOutcomeGlyph(outcome: step.outcome, running: step.running).frame(width: 14)
            Text(step.name)
                .font(step.running || step.outcome == .failing ? NookTheme.TextStyle.label : NookTheme.TextStyle.detail)
                .foregroundStyle(stepColor(step))
                .lineLimit(1)
            Spacer(minLength: NookTheme.Spacing.sm)
            if let seconds = CILogParser.elapsed(started: step.started, finished: step.finished, now: now),
               step.outcome != .skipped {
                Text(CILogParser.clock(seconds))
                    .font(NookTheme.mono(10.5))
                    .monospacedDigit()
                    .foregroundStyle(step.running ? NookTheme.textStrong : NookTheme.textTertiary)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xs)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip).fill(step.running ? NookTheme.rowSelected : .clear))
    }

    private func stepColor(_ step: CILog.Step) -> Color {
        if step.running { return NookTheme.paper }
        switch step.outcome {
        case .failing: return NookTheme.coralSoft
        case .skipped, .pending: return NookTheme.textTertiary
        default: return NookTheme.textSecondary
        }
    }

    /// Above a log the steps fold into one line ("15 steps · failed at Build"), and open into a short list.
    @ViewBuilder
    private func foldedSteps(_ log: CILog) -> some View {
        if !log.steps.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Button {
                    withAnimation(NookTheme.reveal) { showSteps.toggle() }
                } label: {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Image(systemName: "chevron.right")
                            .font(NookTheme.font(9, .semibold))
                            .rotationEffect(.degrees(showSteps ? 90 : 0))
                        Text(tr("ws.ci.steps", log.steps.count))
                        if let failed = log.steps.first(where: { $0.outcome == .failing }) {
                            Text("·")
                            Text(tr("ws.ci.failedAt", failed.name)).foregroundStyle(NookTheme.coralSoft).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showSteps {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            ForEach(log.steps, id: \.number) { stepRow($0, now: log.finished ?? Date()) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                    .fixedSize(horizontal: false, vertical: log.steps.count <= 6)
                    .transition(.opacity)
                }
            }
        }
    }

    /// Under a running job's steps: that this is followed live, and where the log comes from.
    private var liveFooter: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "circle.fill")
                .font(NookTheme.font(6))
                .foregroundStyle(NookTheme.mint)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 1) {
                Text(tr("ws.ci.live")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textStrong)
                Text(tr("ws.ci.running")).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            if let url = check.url {
                SmallGhostButton(title: tr("ws.ci.watchOnGitHub")) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.well))
    }

    // MARK: Log

    @ViewBuilder
    private func logText(_ log: CILog) -> some View {
        if let text = log.text {
            let lines = CILogParser.lines(text)
            let problems = CILogParser.problems(lines)
            let problemCount = problems.filter { $0.kind == .error || $0.kind == .warning }.count
            // A failed job opens on what went wrong; a log without errors opens whole.
            let onlyProblems = problemCount > 0 && !(showFullLog ?? false)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                if problemCount > 0 {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        NookFilterChip(title: tr("ws.ci.problems"), count: problemCount, selected: onlyProblems) { showFullLog = false }
                        NookFilterChip(title: tr("ws.ci.fullLog"), selected: !onlyProblems) { showFullLog = true }
                        Spacer(minLength: 0)
                    }
                }
                logWell(onlyProblems ? problems : lines, omitted: onlyProblems ? 0 : log.omittedLines)
            }
        }
    }

    /// The lines in colour, wrapped to the width so nothing has to be scrolled sideways, as one text so a selection runs
    /// across lines. A failure is at the end of a log, so the full log opens there.
    private func logWell(_ lines: [CILog.Line], omitted: Int) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if omitted > 0 {
                        Text(tr("ws.ci.omitted", omitted))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                            .padding(.bottom, NookTheme.Spacing.xs)
                    }
                    Text(Self.attributed(lines))
                        .font(NookTheme.mono(10.5))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(NookTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.well))
            .onAppear { proxy.scrollTo("end", anchor: .bottomLeading) }
            .onChange(of: lines.count) { _, _ in proxy.scrollTo("end", anchor: .bottomLeading) }
        }
        .frame(maxHeight: .infinity)
        .layoutPriority(1)
    }

    private static func attributed(_ lines: [CILog.Line]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var piece = AttributedString(line.kind == .group ? "▸ " + line.text : line.text)
            switch line.kind {
            case .plain: piece.foregroundColor = NookTheme.textStrong
            case .group:
                piece.foregroundColor = NookTheme.textSecondary
                piece.font = NookTheme.mono(10.5, .semibold)
            case .command: piece.foregroundColor = NookTheme.textTertiary
            case .error: piece.foregroundColor = NookTheme.coralSoft
            case .warning: piece.foregroundColor = NookTheme.amber
            case .notice: piece.foregroundColor = NookTheme.blue
            }
            result += piece
            if index < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    /// Reads the job, and keeps reading it every few seconds while GitHub has no log yet (the job still runs), so the
    /// steps move along and the log shows the moment it exists.
    private func follow() async {
        log = nil
        failure = nil
        showFullLog = nil
        showSteps = false
        guard let jobID = CILogParser.jobID(from: check.url) else { return }
        while !Task.isCancelled {
            do {
                let fresh = try await readLog(jobID: jobID)
                guard !Task.isCancelled else { return }
                withAnimation(NookTheme.swap) { log = fresh }
                failure = nil
                if fresh.text != nil { return }
            } catch {
                guard !Task.isCancelled else { return }
                if log == nil { failure = error.localizedDescription }
            }
            try? await Task.sleep(nanoseconds: Self.followInterval)
        }
    }

    private func readLog(jobID: Int) async throws -> CILog {
        if let repository { return try await GitHubCILogs.log(repo: repository, jobID: jobID) }
        guard let pullRequest else { throw CloudHelp.notSetUp("GitHub") }
        return try await GitHubCILogs.log(pullRequest: pullRequest, jobID: jobID)
    }

    // MARK: Report

    /// A check from another app: its own report first, then what the app wrote on the pull request, in one column that
    /// scrolls. With neither, a line that says so (the check's page is behind the button in the header).
    @ViewBuilder
    private func reportView(_ report: CICheckReport) -> some View {
        if report.isEmpty {
            message(tr(check.outcome == .pending ? "ws.ci.report.waiting" : "ws.ci.report.none"))
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    if !report.title.isEmpty {
                        Text(report.title).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !report.summary.isEmpty { MarkdownView(text: report.summary, size: 12.5) }
                    if !report.annotations.isEmpty { annotations(report.annotations) }
                    if !report.text.isEmpty { MarkdownView(text: report.text, size: 12.5) }
                    if !report.notes.isEmpty { notes(report.notes) }
                }
                .textSelection(.enabled)
                .padding(NookTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.well))
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
        }
    }

    /// The remarks on lines of code, one per line: the mark in its level's color, file and line, then what it says.
    private func annotations(_ items: [CICheckReport.Annotation]) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            NookSectionLabel(tr("ws.ci.report.annotations", items.count), inset: 0)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Image(systemName: item.level == .error ? "xmark.octagon.fill"
                          : item.level == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(item.level == .error ? NookTheme.coralSoft : item.level == .warning ? NookTheme.amber : NookTheme.blue)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(item.path + (item.line.map { ":\($0)" } ?? ""))
                            .font(NookTheme.mono(10.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Text([item.title, item.message].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textStrong)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What the app wrote on the pull request, newest first, each under its author and when.
    private func notes(_ items: [CICheckReport.Note]) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            NookSectionLabel(tr("ws.ci.report.notes"), inset: 0)
            ForEach(Array(items.enumerated()), id: \.offset) { index, note in
                if index > 0 { NookDivider() }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        GitHubAvatar(login: note.author, size: 16)
                        Text(note.author).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textStrong).lineLimit(1)
                        if let date = note.date {
                            Text("· " + NookDates.ago(date)).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        if let url = note.url {
                            ToolbarIconButton("arrow.up.right.square", tr("ws.ci.open")) { NSWorkspace.shared.open(url) }
                        }
                    }
                    MarkdownView(text: note.body, size: 12.5)
                }
            }
        }
    }

    /// Reads the report, and again every few seconds while the check still runs, so its words follow along.
    /// Starts again when the check's outcome changes, keeping what it showed until the new read is in.
    private func followReport() async {
        failure = nil
        // Only a pull request's checks come from other apps; a repository's runs are all Actions jobs.
        guard let pullRequest else {
            failure = tr("ws.ci.report.none")
            return
        }
        while !Task.isCancelled {
            do {
                let fresh = try await GitHubCILogs.report(pullRequest: pullRequest, check: check)
                guard !Task.isCancelled else { return }
                if fresh != report { withAnimation(NookTheme.swap) { report = fresh } }
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                if report == nil { failure = error.localizedDescription }
            }
            guard check.outcome == .pending else { return }
            try? await Task.sleep(nanoseconds: Self.reportInterval)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .multilineTextAlignment(.center)
            .padding(NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The line under a check's name in words, with its clock: "Running · 3:12 · step 8 of 15", "Failed after 4:05",
/// "Queued". A running check counts up each second. A commit status from another app keeps its own sentence.
struct CICheckStatusText: View {
    let check: PullRequestCheck
    var outcome: PullRequestCheck.Outcome?
    var running: Bool?
    var started: Date?
    var finished: Date?
    var progress: String?

    var body: some View {
        let outcome = outcome ?? check.outcome
        let running = running ?? check.running
        let started = started ?? check.started
        let finished = finished ?? check.finished
        Group {
            if outcome == .pending && running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(line(outcome: outcome, running: true, started: started, finished: nil, now: context.date))
                }
            } else {
                Text(line(outcome: outcome, running: running, started: started, finished: finished, now: Date()))
            }
        }
        .font(NookTheme.TextStyle.caption)
        .monospacedDigit()
        .foregroundStyle(outcome == .failing ? NookTheme.coralSoft : NookTheme.textTertiary)
        .lineLimit(1)
    }

    private func line(outcome: PullRequestCheck.Outcome, running: Bool, started: Date?, finished: Date?, now: Date) -> String {
        guard check.isCheckRun else { return check.detail.replacingOccurrences(of: "_", with: " ") }
        let clock = CILogParser.elapsed(started: started, finished: finished, now: now).map(CILogParser.clock)
        switch outcome {
        case .pending:
            guard running else { return tr("ws.ci.state.queued") }
            return ([tr("ws.ci.state.running"), clock, progress].compactMap { $0 }).joined(separator: " · ")
        case .skipped:
            return tr("ws.ci.state.skipped")
        case .passing, .failing:
            // The word alone, and with how long it ran.
            let keys: (String, String)
            switch check.detail {
            case "cancelled": keys = ("ws.ci.state.cancelled", "ws.ci.state.cancelledAfter")
            case "timed_out": keys = ("ws.ci.state.timedOut", "ws.ci.state.timedOutAfter")
            default:
                keys = outcome == .passing ? ("ws.ci.state.passed", "ws.ci.state.passedAfter")
                                           : ("ws.ci.state.failed", "ws.ci.state.failedAfter")
            }
            guard let clock else { return tr(keys.0) }
            return tr(keys.1, clock)
        }
    }
}

/// The thin bar under a running job's name, filling as its steps finish.
private struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(NookTheme.smoke)
                Capsule().fill(NookTheme.paper).frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .animation(NookTheme.reveal, value: fraction)
    }
}
