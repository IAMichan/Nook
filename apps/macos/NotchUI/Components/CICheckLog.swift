import SwiftUI
import AppKit

/// One CI check read in Nook: its name and outcome, the steps of its GitHub Actions job and the end of its log, which
/// follows a job that still runs until GitHub has the log. The CI popover of a watched pull request and the checks on a
/// pull request page both show it, so a failing check never has to be read on GitHub.
struct CICheckLogView: View {
    let pullRequest: URL
    let check: PullRequestCheck
    /// The back button before the name, on a page that showed the check in place of something else.
    var onBack: (() -> Void)?
    @State private var log: CILog?
    @State private var failure: String?
    /// nil until the reader picks: a log with errors opens on them, one without opens whole.
    @State private var showFullLog: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header
            if CILogParser.jobID(from: check.url) == nil {
                message(tr("ws.ci.noLog"))
            } else if let failure {
                message(failure)
            } else if let log {
                steps(log.steps)
                logText(log)
            } else {
                PatientSpinner().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: check.id) { await follow() }
    }

    private var header: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let onBack { NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24, action: onBack) }
            CheckOutcomeGlyph(outcome: check.outcome)
            Text(check.name).font(NookTheme.TextStyle.strong).lineLimit(1)
            Spacer(minLength: 0)
            if let text = log?.text, !text.isEmpty {
                ToolbarIconButton("doc.on.doc", tr("ws.ci.copy")) { Pasteboard.copy(text) }
            }
            if let url = check.url {
                ToolbarIconButton("arrow.up.right.square", tr("ws.ci.open")) { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// The steps in a short list of their own, so a long job never pushes the log off the page; a step that did not run
    /// is quiet and the one that failed stands out.
    @ViewBuilder
    private func steps(_ steps: [CILog.Step]) -> some View {
        if !steps.isEmpty {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    ForEach(steps, id: \.number) { step in
                        HStack(spacing: NookTheme.Spacing.sm) {
                            CheckOutcomeGlyph(outcome: step.outcome).frame(width: 14)
                            Text(step.name)
                                .font(step.outcome == .failing ? NookTheme.TextStyle.label : NookTheme.TextStyle.detail)
                                .foregroundStyle(stepColor(step.outcome))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 112)
            .fixedSize(horizontal: false, vertical: steps.count <= 5)
        }
    }

    private func stepColor(_ outcome: PullRequestCheck.Outcome) -> Color {
        switch outcome {
        case .failing: return NookTheme.coralSoft
        case .skipped: return NookTheme.textTertiary
        default: return NookTheme.textSecondary
        }
    }

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
        } else {
            message(tr("ws.ci.running"))
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
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(NookTheme.Spacing.sm)
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

    /// Reads the job, and keeps reading it every few seconds while GitHub has no log yet (the job still runs).
    private func follow() async {
        log = nil
        failure = nil
        showFullLog = nil
        guard let jobID = CILogParser.jobID(from: check.url) else { return }
        while !Task.isCancelled {
            do {
                let fresh = try await GitHubCILogs.log(pullRequest: pullRequest, jobID: jobID)
                guard !Task.isCancelled else { return }
                log = fresh
                failure = nil
                if fresh.text != nil { return }
            } catch {
                guard !Task.isCancelled else { return }
                if log == nil { failure = error.localizedDescription }
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
