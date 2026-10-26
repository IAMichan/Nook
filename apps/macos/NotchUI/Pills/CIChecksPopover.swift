import SwiftUI

/// What "CI running" on a watched pull request opens: its checks on the left, the chosen one on the right in a
/// `CICheckLogView` (its steps and log).
struct CIChecksPopover: View {
    let pullRequest: URL
    @State private var checks: [PullRequestCheck]?
    @State private var unavailable = false
    @State private var chosen: String?
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
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let check = current {
            CICheckLogView(pullRequest: pullRequest, check: check)
                .padding(NookTheme.Spacing.md)
                .id(check.id)
        } else if checks?.isEmpty == false {
            message(tr("ws.ci.pick"))
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
