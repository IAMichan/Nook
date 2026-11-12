import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// The card that offers a way on when a turn failed or the session cannot continue.
extension AgentRunPanel {
    func recovery(_ run: WorkspaceRun, events: [RunEvent], blocks: [TimelineBlock], proxy: ScrollViewProxy) -> some View {
        let failed = run.status == .failed
        // A stopped turn goes on where it was when the agent kept its conversation; otherwise only a retry helps.
        let canGoOn = !failed && run.providerSessionID != nil
        // One main action per card: a sign-in or an update to do first takes it from Retry.
        // An agent you added that signs in only in a terminal (`AcpAuthMethod.terminal`) says so when its session opens.
        let terminalSignIn = failed && workspace.acpTerminalSignIns[run.profileID] != nil
        let fixFirst = failed && ((AgentSignInFailure.needsSignIn(run.statusDetail) && AgentSignInFailure.canSignInAgain(run.provider))
            || terminalSignIn || (!run.isRemote && AgentUpdates.updatable(run.provider) && AgentVersionRejection.parse(run.statusDetail) != nil))
        let problem = failed ? run.statusDetail.flatMap { $0 == "interrupted" || $0.isEmpty ? nil : $0 } : nil
        let detail = run.statusDetail == "interrupted" ? tr("ws.recovery.interrupted")
            : failed ? tr("ws.recovery.failedDetail")
            : canGoOn ? tr("ws.recovery.stoppedDetail") : tr("ws.recovery.noResume")
        return AdaptiveActionRow(spacing: 10) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                BannerMark(symbol: failed ? "exclamationmark.triangle" : "pause.circle",
                           tint: failed ? NookTheme.coral : NookTheme.textSecondary)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(failed ? tr("ws.recovery.failed") : tr("ws.recovery.stoppedTitle"))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // What went wrong in the agent's own words, apart from the sentence above.
                    if let problem {
                        Text(problem)
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                            .padding(.horizontal, NookTheme.Spacing.sm)
                            .padding(.vertical, NookTheme.Spacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .roundedBackground(NookTheme.well, radius: NookTheme.Radius.chip)
                            .padding(.top, NookTheme.Spacing.xs)
                    }
                }
            }
        } actions: {
            if let failure = FailureJump.firstFailure(in: events) {
                NookGhostButton(title: tr("timeline.goToFailure")) {
                    scroll.userScrolled()
                    revealTurn(of: failure)
                    for key in TimelineContainers.keys(blocks)[failure] ?? [] { openBlocks.insert(key) }
                    DispatchQueue.main.async { withAnimation(NookTheme.scroll) { proxy.scrollTo(failure, anchor: .center) } }
                }
            }
            if canGoOn {
                NookGhostButton(title: tr("ws.action.retryFromLast")) { workspace.retry(runID) }
                    .help(tr("ws.action.retry.help"))
                NookPrimaryButton(title: tr("ws.action.goOn")) { _ = workspace.send(runID, text: UsageLimits.resumeMessage) }
                    .help(tr("ws.action.goOn.help"))
            } else if fixFirst {
                // Signing in again or updating the agent is the main action; it runs the turn again itself.
                NookGhostButton(title: tr("ws.action.retry")) { workspace.retry(runID) }
                    .help(tr("ws.action.retry.help"))
            } else {
                NookPrimaryButton(title: tr("ws.action.retry")) { workspace.retry(runID) }
                    .help(tr("ws.action.retry.help"))
            }
            // The login ran out: sign in again in the browser, and the turn runs again once you are back.
            if run.status == .failed, AgentSignInFailure.needsSignIn(run.statusDetail),
               AgentSignInFailure.canSignInAgain(run.provider) {
                let profile = app.profiles.profile(id: run.profileID) ?? .defaultProfile(run.provider.kind)
                let signingIn = app.agentConnect[profile.id]?.isBusy == true
                NookPrimaryButton(title: signingIn ? tr("accounts.reauthWaiting") : tr("accounts.reauth"),
                                  symbol: "person.badge.key") {
                    app.reauthenticate(profile) { workspace.retry(runID) }
                }
                .disabled(signingIn)
            } else if terminalSignIn {
                // Its sign-in runs in a Terminal window; Retry then starts the agent again with the saved login.
                NookPrimaryButton(title: tr("accounts.reauth"), symbol: "person.badge.key") {
                    workspace.signInAcpInTerminal(profileID: run.profileID)
                }
            }
            // The API refused this agent's version for the model: Settings › Agents updates it after you confirm.
            if run.status == .failed, !run.isRemote, AgentUpdates.updatable(run.provider),
               AgentVersionRejection.parse(run.statusDetail) != nil {
                NookPrimaryButton(title: tr("ws.recovery.updateAgent", run.provider.displayName), symbol: "arrow.down.circle") {
                    app.requestAgentUpdate([run.provider])
                }
            }
        }
        .padding(NookTheme.Spacing.md)
        .cardBackground(NookTheme.surface, stroke: failed ? NookTheme.coral.opacity(0.3) : NookTheme.fieldStroke,
                        radius: NookTheme.Radius.card)
    }
}
