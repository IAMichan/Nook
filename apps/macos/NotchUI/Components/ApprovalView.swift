import SwiftUI

/// A permission request from an agent: what it wants (the whole command or the whole change), how risky that looks, and
/// the buttons to decide. The notch, the Agents list and the session view all show it this way.
struct ApprovalView: View {
    let approval: AgentApproval
    /// Other requests waiting behind this one.
    var more = 0
    /// Fixed palette for the dark notch and the window alike.
    var maxHeight: CGFloat = 180
    let onDecide: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Calm by default: no icon, no colored card. Only a risky request gets a quiet coral accent.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(approval.title)
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                if more > 0 {
                    Text(tr("ws.approval.more", more)).font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            if !approval.note.isEmpty {
                Text(approval.note)
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(approval.danger ? NookTheme.coralSoft : NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            HStack(spacing: 4) {
                NookPrimaryButton(title: tr("button.allow")) { onDecide(.allow) }
                if approval.canAlways {
                    NookGhostButton(title: tr("button.always")) { onDecide(.always) }
                }
                NookGhostButton(title: tr("button.deny")) { onDecide(.deny) }
                if approval.canTerminal {
                    NookGhostButton(title: tr("approval.inTerminal")) { onDecide(.terminal) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .cardBackground(NookTheme.field, stroke: approval.danger ? NookTheme.coral.opacity(0.35) : NookTheme.line2, radius: 12)
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
        .padding(8)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(Color.white.opacity(0.03)))
    }
}
