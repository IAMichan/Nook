import SwiftUI

/// A new session the agent suggests (`SessionSuggestion`), as Claude's "New session" card: a quiet header, the title, where
/// it would run and the agent's summary, then Options on the left and Do it here and Start on the right; × lets it go.
/// Once you chose, it folds to one line that says what happened (Start leaves a link to the new session).
struct SessionSuggestionCard: View {
    @EnvironmentObject private var app: AppModel
    let suggestion: SessionSuggestion
    let state: RunEvent.State?
    /// The new session's id, once started.
    let startedID: String?
    /// Nil where the card cannot act (a read-only view): it shows, without buttons.
    let choose: ((SessionSuggestion.Choice) -> Void)?

    var body: some View {
        Group {
            if state == .pending || state == nil {
                card
            } else {
                outcome
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.vertical, NookTheme.Spacing.xs)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tr("suggest.header"))
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NookTheme.smoke)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                        Text(suggestion.title)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                        (Text(place).foregroundStyle(NookTheme.textStrong)
                            + Text(suggestion.summary.isEmpty ? "" : " · " + suggestion.summary).foregroundStyle(NookTheme.textTertiary))
                            .font(NookTheme.TextStyle.body)
                            .lineLimit(2)
                            .help(suggestion.prompt)
                    }
                    Spacer(minLength: 0)
                    if let choose {
                        ToolbarIconButton("xmark", tr("suggest.dismiss")) { choose(.dismiss) }
                    }
                }
                if let choose {
                    HStack(spacing: NookTheme.Spacing.md) {
                        SmallGhostButton(title: tr("suggest.options")) { choose(.options) }
                            .help(tr("suggest.optionsHelp"))
                        Spacer(minLength: 0)
                        SmallGhostButton(title: tr("suggest.here")) { choose(.here) }
                            .help(tr("suggest.hereHelp"))
                        SmallPrimaryButton(title: tr("suggest.start")) { choose(.start) }
                            .help(tr("suggest.startHelp"))
                    }
                }
            }
            .padding(NookTheme.Spacing.lg)
        }
        .roundedClip(NookTheme.Radius.card)
        .cardBackground(NookTheme.graphite, stroke: NookTheme.line, radius: NookTheme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("suggest.header") + ": " + suggestion.title)
    }

    /// "Codex · New worktree", or just where it runs when it is your agent.
    private var place: String {
        let where_: String
        switch suggestion.worktree {
        case .some(true): where_ = tr("compose.newWorktree")
        case .some(false): where_ = tr("compose.currentCheckout")
        case .none: where_ = tr("suggest.place.default")
        }
        guard let agent = RunProvider.named(suggestion.agent) else { return where_ }
        return agent.displayName + " · " + where_
    }

    @ViewBuilder
    private var outcome: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            switch state {
            case .running:
                BusyLine(tr("suggest.starting", suggestion.title), tone: .inherited)
            case .done:
                Image(icon: "checkmark.circle").foregroundStyle(NookTheme.mint)
                Text(tr("suggest.startedLine", suggestion.title))
                if let startedID, app.workspace.run(UUID(uuidString: startedID) ?? UUID()) != nil {
                    SmallGhostButton(title: tr("suggest.open")) { app.viewModel.selectedAgentID = "run:" + startedID }
                }
            case .allowed:
                Image(icon: "arrow.turn.down.left").foregroundStyle(NookTheme.textTertiary)
                Text(tr("suggest.hereLine", suggestion.title))
            default:
                Image(icon: "xmark").foregroundStyle(NookTheme.textTertiary)
                Text(tr("suggest.dismissedLine", suggestion.title))
            }
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
        .lineLimit(1)
    }
}
