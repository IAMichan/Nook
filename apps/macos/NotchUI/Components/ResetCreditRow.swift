import SwiftUI

/// The reset credits an account has banked, and "Use a reset", which empties its windows at once (Codex offers these).
/// Asks first, since a credit is spent. After the reset the limits are read again, so the bars show the empty windows,
/// and a line says what happened. Shows nothing for an account without credits. The same row in the Limits tab,
/// Settings › Coding agents and the banner of a session a limit stopped.
struct ResetCreditRow: View {
    @EnvironmentObject private var app: AppModel
    let profile: AgentProfile
    @State private var asking = false
    @State private var outcome: CodexRateLimits.ResetOutcome?

    var body: some View {
        let credits = app.quota.resetCredits(for: profile)
        if let credits, credits.available > 0 || outcome != nil {
            let redeeming = app.quota.isRedeemingReset(for: profile)
            AdaptiveActionRow {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        Image(icon: "arrow.counterclockwise.circle")
                            .font(NookTheme.font(12, .semibold))
                            .foregroundStyle(NookTheme.textSecondary)
                        Text(tr("agents.reset.credits", credits.available))
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.paper)
                    }
                    if let line = detail(credits) {
                        Text(line)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(outcome == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } actions: {
                if redeeming {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 30, height: 30)
                        .help(tr("agents.reset.using"))
                } else if credits.available > 0 {
                    SmallGhostButton(title: tr("agents.reset.use")) { asking = true }
                        .help(tr("agents.reset.help"))
                }
            }
            .confirmationDialog(tr("agents.reset.question", profile.kind.name), isPresented: $asking, titleVisibility: .visible) {
                Button(tr("agents.reset.use")) { use() }
                Button(tr("button.cancel"), role: .cancel) {}
            } message: {
                Text(tr("agents.reset.detail", credits.available))
            }
        }
    }

    /// What the last reset did, or else when the next credit expires.
    private func detail(_ credits: CodexUsageSnapshot.ResetCredits) -> String? {
        switch outcome {
        case .reset: return tr("agents.reset.done")
        case .nothingToReset: return tr("agents.reset.nothing")
        case .noCredit: return tr("agents.reset.noCredit")
        case .alreadyRedeemed: return tr("agents.reset.already")
        case .failed: return tr("agents.reset.failed")
        case nil:
            guard let expiry = credits.nextExpiresAt, expiry > Date() else { return nil }
            return tr("agents.reset.expires", AgentFormat.duration(expiry.timeIntervalSinceNow))
        }
    }

    private func use() {
        outcome = nil
        Task { outcome = await app.quota.useResetCredit(for: profile) }
    }
}
