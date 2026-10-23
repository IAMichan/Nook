import SwiftUI

/// A permission request from an agent: what it wants (the whole command or the whole change), how risky that looks, and
/// the buttons to decide. The notch, the Agents list and the session view all show it this way.
struct ApprovalView: View {
    let approval: AgentApproval
    /// Other requests waiting behind this one.
    var more = 0
    /// Fixed palette for the dark notch and the window alike.
    var maxHeight: CGFloat = 96
    let onDecide: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            // Calm by default: no icon, no colored fill. The edge says it waits on you (amber), or that it looks risky
            // (coral), as a question from the agent does. The buttons sit beside the title, so the request takes no
            // more room than the composer it replaces.
            HStack(alignment: .center, spacing: NookTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                        Text(approval.title)
                            .font(NookTheme.TextStyle.strong)
                            .foregroundStyle(NookTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                        if more > 0 {
                            Text(tr("ws.approval.more", more)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                        }
                    }
                    if !approval.note.isEmpty {
                        Text(approval.note)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(approval.danger ? NookTheme.coralSoft : NookTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                NookNoticeActions(
                    primary: NookNoticeAction(tr("button.allow")) { onDecide(.allow) },
                    secondary: NookNoticeAction(tr("button.deny")) { onDecide(.deny) },
                    extra: (approval.canAlways ? [NookNoticeAction(tr("button.always")) { onDecide(.always) }] : [])
                        + (approval.canTerminal ? [NookNoticeAction(tr("approval.inTerminal")) { onDecide(.terminal) }] : [])
                )
                .fixedSize()
            }
            content
        }
        .padding(.leading, NookTheme.Spacing.xl)
        .padding(.trailing, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.md)
        // The composer's shape, so the request reads as the input it stands in for.
        .cardBackground(NookTheme.surface, stroke: approval.danger ? NookTheme.coral.opacity(0.35) : NookTheme.amber.opacity(0.25),
                        radius: NookTheme.Radius.pill, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(showsIndicators: true) {
            if approval.diff.isEmpty {
                // The whole command: scrolled, never cut off.
                Text(approval.command)
                    .font(NookTheme.mono(11.5))
                    .foregroundStyle(NookTheme.paper)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(approval.diff) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(NookTheme.mono(11))
                            .foregroundStyle(line.kind == .context ? NookTheme.textTertiary : NookTheme.paper)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.kind == .context ? Color.clear : line.color)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.well))
    }
}
