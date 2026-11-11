import SwiftUI

/// At the end of the timeline of a session a usage limit stopped, in the place and shape of the "You stopped this
/// turn" card: when the limit resets, "Resume at reset" (sends "Continue where you left off." once it has), another
/// account with room left, and Retry.
struct UsageLimitCard: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    @EnvironmentObject private var app: AppModel
    let run: WorkspaceRun

    /// Whether this session shows the limit card instead of the stopped/failed one.
    static func shows(_ run: WorkspaceRun) -> Bool { run.limitedAt != nil && !run.status.isActive }

    var body: some View {
        let auto = run.autoResume == true
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            AdaptiveActionRow(spacing: 10) {
                HStack(spacing: 10) {
                    Image(icon: auto ? "clock.arrow.circlepath" : "hourglass")
                        .foregroundStyle(NookTheme.amber)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(tr("ws.limit.title"))
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                        TimelineView(.nookTicks(every: 30)) { context in
                            Text(line(now: context.date, auto: auto))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } actions: {
                if let suggestion = suggestion() {
                    NookGhostButton(title: tr("ws.limit.switchTo", AccountLabel.name(suggestion.profile, app: app) + " · " + suggestion.profile.kind.name)) {
                        _ = workspace.switchProvider(run.id, to: suggestion.provider, profileID: suggestion.profile.id, resumeIfLimited: true)
                    }
                    .help(suggestion.sameAgent ? tr("ws.limit.switchHelpSame") : tr("ws.limit.switchHelp"))
                }
                // Also without a known reset: Nook then tries again now and then until the limit lets it through.
                NookGhostButton(title: auto ? tr("ws.limit.cancelResume") : tr("ws.limit.resume")) {
                    workspace.setAutoResume(run.id, !auto)
                }
                .help(tr("ws.limit.resumeHelp"))
                NookGhostButton(title: tr("ws.action.retry")) { workspace.retry(run.id) }
            }
            // A banked reset credit of this account frees it now, instead of waiting for the reset.
            if let profile = app.profiles.profile(id: run.profileID) {
                ResetCreditRow(profile: profile)
            }
        }
        .padding(10)
        .roundedBackground(NookTheme.surface, radius: NookTheme.Radius.card)
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
        guard let reset = run.limitResetAt else {
            guard auto, let due = workspace.limitResumeDue(run) else { return tr("ws.limit.unknown") }
            if due <= now { return tr("ws.limit.resumingSoon") }
            let clock = due.formatted(date: Calendar.current.isDateInToday(due) ? .omitted : .abbreviated, time: .shortened)
            return tr("ws.limit.retriesAt", clock, AgentPathFormat.duration(due.timeIntervalSince(now)))
        }
        if reset <= now { return auto ? tr("ws.limit.resumingSoon") : tr("ws.limit.free") }
        let clock = reset.formatted(date: Calendar.current.isDateInToday(reset) ? .omitted : .abbreviated, time: .shortened)
        let wait = AgentPathFormat.duration(reset.timeIntervalSince(now))
        return auto ? tr("ws.limit.resumesAt", clock, wait) : tr("ws.limit.resetsAt", clock, wait)
    }
}
