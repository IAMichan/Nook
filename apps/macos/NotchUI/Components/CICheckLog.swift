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

    @ViewBuilder
    private func steps(_ steps: [CILog.Step]) -> some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(steps, id: \.number) { step in
                    HStack(spacing: NookTheme.Spacing.sm) {
                        CheckOutcomeGlyph(outcome: step.outcome).frame(width: 14)
                        Text(step.name).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func logText(_ log: CILog) -> some View {
        if let text = log.text {
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        if log.omittedLines > 0 {
                            Text(tr("ws.ci.omitted", log.omittedLines))
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(.bottom, NookTheme.Spacing.xs)
                        }
                        Text(text)
                            .font(NookTheme.mono(10.5))
                            .foregroundStyle(NookTheme.textStrong)
                            .textSelection(.enabled)
                            .fixedSize()
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(NookTheme.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.well))
                // A failure is at the end of a log.
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        } else {
            message(tr("ws.ci.running"))
        }
    }

    /// Reads the job, and keeps reading it every few seconds while GitHub has no log yet (the job still runs).
    private func follow() async {
        log = nil
        failure = nil
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
