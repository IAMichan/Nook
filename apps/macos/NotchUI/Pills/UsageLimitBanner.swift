import SwiftUI

/// Above the composer of a session a usage limit stopped: when the limit resets, and
/// "Resume at reset", which sends "Continue where you left off." once it has.
struct UsageLimitBanner: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var app: AppModel
    let run: WorkspaceRun

    var body: some View {
        if run.limitedAt != nil, !run.status.isActive {
            let auto = run.autoResume == true
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: auto ? "clock.arrow.circlepath" : "hourglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NookTheme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("ws.limit.title")).font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.textSecondary)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(line(now: context.date, auto: auto))
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                if let suggestion = suggestion() {
                    SmallGhostButton(title: tr("ws.limit.switchTo", AccountLabel.name(suggestion.profile, app: app) + " · " + suggestion.profile.kind.name)) {
                        _ = workspace.switchProvider(run.id, to: suggestion.provider, profileID: suggestion.profile.id)
                    }
                    .help(suggestion.sameAgent ? tr("ws.limit.switchHelpSame") : tr("ws.limit.switchHelp"))
                }
                if run.limitResetAt != nil {
                    SmallGhostButton(title: auto ? tr("ws.limit.cancelResume") : tr("ws.limit.resume")) {
                        workspace.setAutoResume(run.id, !auto)
                    }
                    .help(tr("ws.limit.resumeHelp"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NookTheme.amber.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(NookTheme.amber.opacity(0.22), lineWidth: 1))
        }
    }

    /// Another account with room left (same agent first), when this one is nearly out (LimitAdvisor).
    private func suggestion() -> (provider: RunProvider, profile: AgentProfile, sameAgent: Bool)? {
        var states: [LimitState] = []
        var profiles: [String: AgentProfile] = [:]
        for provider in app.connectedProviders where workspace.executable(provider) != nil {
            for profile in app.connectedProfiles(for: provider) {
                let limits = app.quota.limits(for: profile)
                let fraction = limits.map(\.percent).max().map { $0 / 100 }
                states.append(LimitState(provider: provider, profileID: profile.id, usedFraction: limits.isEmpty ? nil : fraction,
                                         resetAt: limits.compactMap(\.resetsAt).min()))
                profiles[profile.id] = profile
            }
        }
        // This session's own account counts as full: it hit the limit.
        if let index = states.firstIndex(where: { $0.provider == run.provider && $0.profileID == run.profileID }) {
            states[index].usedFraction = max(states[index].usedFraction ?? 0, 1)
        }
        guard workspace.canTransfer(run.id),
              let pick = LimitAdvisor.suggest(states: states, current: (run.provider, run.profileID), now: Date()),
              let profile = profiles[pick.profileID] else { return nil }
        return (pick.provider, profile, pick.sameAgent)
    }

    private func line(now: Date, auto: Bool) -> String {
        guard let reset = run.limitResetAt else { return tr("ws.limit.unknown") }
        if reset <= now { return auto ? tr("ws.limit.resumingSoon") : tr("ws.limit.free") }
        let clock = reset.formatted(date: Calendar.current.isDateInToday(reset) ? .omitted : .abbreviated, time: .shortened)
        let wait = AgentPathFormat.duration(reset.timeIntervalSince(now))
        return auto ? tr("ws.limit.resumesAt", clock, wait) : tr("ws.limit.resetsAt", clock, wait)
    }
}
