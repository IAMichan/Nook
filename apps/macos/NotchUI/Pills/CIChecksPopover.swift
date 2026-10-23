import SwiftUI
import AppKit

/// What "CI running" on a watched pull request opens: its checks on the left, the steps and log of the chosen one on the
/// right. A job that still runs is read again every few seconds until GitHub has its log.
struct CIChecksPopover: View {
    let pullRequest: URL
    @State private var checks: [PullRequestCheck]?
    @State private var unavailable = false
    @State private var chosen: String?
    @State private var log: CILog?
    @State private var failure: String?
    /// The checks of each pull request as last read, so opening the popover again shows them without waiting.
    @MainActor private static var seen: [URL: [PullRequestCheck]] = [:]

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 220)
            Divider()
            detail.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await loadChecks() }
    }

    // MARK: Checks

    @ViewBuilder
    private var list: some View {
        if let checks {
            if checks.isEmpty {
                message(tr("ws.ci.none"))
            } else {
                List(checks, selection: Binding<String?>(get: { chosen }, set: { pick($0) })) { check in
                    HStack(spacing: NookTheme.Spacing.sm) {
                        CheckOutcomeGlyph(outcome: check.outcome).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name).font(NookTheme.TextStyle.label).lineLimit(1)
                            Text(check.detail).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
                        }
                    }
                    .tag(check.id)
                }
            }
        } else if unavailable {
            message(tr("ws.ci.unavailable"))
        } else {
            PatientSpinner()
        }
    }

    private var current: PullRequestCheck? { checks?.first { $0.id == chosen } }

    private func loadChecks() async {
        // The checks read last time show at once; the fresh read replaces them when GitHub answers.
        if checks == nil, let seen = Self.seen[pullRequest] {
            checks = seen
            if chosen == nil, let first = seen.first { pick(first.id) }
        }
        guard let found = await GitHubCILogs.checks(pullRequest: pullRequest) else {
            if checks == nil { unavailable = true }
            return
        }
        Self.seen[pullRequest] = found
        checks = found
        // Failing checks come first, then the running ones: the one you most likely want to read.
        if !found.contains(where: { $0.id == chosen }), let first = found.first { pick(first.id) }
    }

    private func pick(_ id: String?) {
        chosen = id
        log = nil
        failure = nil
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let check = current {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                header(check)
                if CILogParser.jobID(from: check.url) == nil {
                    message(tr("ws.ci.noLog"))
                } else if let failure {
                    message(failure)
                } else if let log {
                    steps(log.steps)
                    logText(log)
                } else {
                    PatientSpinner()
                }
            }
            .padding(NookTheme.Spacing.md)
            .task(id: check.id) { await follow(check) }
        } else if checks?.isEmpty == false {
            message(tr("ws.ci.pick"))
        }
    }

    private func header(_ check: PullRequestCheck) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
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
    private func follow(_ check: PullRequestCheck) async {
        guard let jobID = CILogParser.jobID(from: check.url) else { return }
        while !Task.isCancelled {
            do {
                let fresh = try await GitHubCILogs.log(pullRequest: pullRequest, jobID: jobID)
                guard chosen == check.id else { return }
                log = fresh
                failure = nil
                if fresh.text != nil { return }
            } catch {
                guard chosen == check.id else { return }
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
