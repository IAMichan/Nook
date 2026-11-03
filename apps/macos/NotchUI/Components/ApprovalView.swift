import SwiftUI

/// A permission request from an agent: what it wants (the whole command or the whole change), how risky that looks, and
/// the buttons to decide. The notch, the Agents list and the session view all show it this way.
struct ApprovalView: View {
    let approval: AgentApproval
    /// Other requests waiting behind this one.
    var more = 0
    /// Fixed palette for the dark notch and the window alike.
    var maxHeight: CGFloat? = nil
    let onDecide: (ApprovalDecision) -> Void

    private var prPreview: PullRequestApprovalPreview? {
        PullRequestApprovalPreview.parse(approval.command)
    }

    private var isPullRequest: Bool {
        approval.tool == BridgeTool.pullRequestCreate.rawValue || approval.tool == "pull_request_create" || prPreview != nil
    }

    private var effectiveMaxHeight: CGFloat {
        if let maxHeight { return maxHeight }
        if isPullRequest { return 260 }
        if !approval.diff.isEmpty { return 280 }
        if approval.prose { return 240 }
        return 180
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: NookTheme.Spacing.md) {
                    titleBlock.frame(minWidth: 0, idealWidth: 180, maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    titleBlock
                    actions
                }
            }
            content
        }
        .padding(NookTheme.Spacing.lg)
        .cardBackground(NookTheme.surface, stroke: approval.danger ? NookTheme.coral.opacity(0.35) : NookTheme.amber.opacity(0.25),
                        radius: NookTheme.Radius.panel, style: .continuous)
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            headerIcon
                .frame(width: 18, height: 18)
                .padding(.top, 1)

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
        }
    }

    @ViewBuilder
    private var headerIcon: some View {
        if isPullRequest {
            NookSymbol(PullRequestIcon.generic, size: 14)
                .foregroundStyle(NookTheme.amber)
        } else if !approval.diff.isEmpty {
            Image(systemName: "pencil.line")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.amber)
        } else if approval.danger {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.coral)
        } else {
            Image(systemName: "terminal.fill")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.amber)
        }
    }

    private var actions: some View {
        NookNoticeActions(
            primary: NookNoticeAction(tr("button.allow")) { onDecide(.allow) },
            secondary: NookNoticeAction(tr("button.deny")) { onDecide(.deny) },
            extra: (approval.canAlways ? [NookNoticeAction(tr("button.always")) { onDecide(.always) }] : [])
                + (approval.canTerminal ? [NookNoticeAction(tr("approval.inTerminal")) { onDecide(.terminal) }] : [])
        )
    }

    @ViewBuilder
    private var content: some View {
        if let pr = prPreview {
            pullRequestCard(pr)
        } else if approval.prose {
            // A pull request, a brief or a message: read as the text it is, headings and lists included.
            ScrollView(showsIndicators: true) {
                MarkdownView(text: approval.command, size: 13)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(maxHeight: effectiveMaxHeight)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.well))
            .overlay(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        } else if approval.diff.isEmpty {
            // The whole command: scrolled, never cut off.
            HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                Text("$")
                    .font(NookTheme.mono(11.5, .bold))
                    .foregroundStyle(NookTheme.amber)
                ScrollView(showsIndicators: true) {
                    Text(approval.command)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(NookTheme.paper)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(maxHeight: effectiveMaxHeight)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.well))
            .overlay(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        } else {
            ScrollView(showsIndicators: true) {
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
            .padding(.horizontal, NookTheme.Spacing.md)
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(maxHeight: effectiveMaxHeight)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.well))
            .overlay(
                RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func pullRequestCard(_ pr: PullRequestApprovalPreview) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            // Branch flow bar
            HStack(spacing: NookTheme.Spacing.xs) {
                if !pr.repository.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox.fill")
                            .font(NookTheme.font(10, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                        Text(pr.repository)
                            .font(NookTheme.font(11, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.field))
                }

                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.amber)
                    Text(pr.sourceBranch)
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(NookTheme.paper)
                    Image(systemName: "arrow.right")
                        .font(NookTheme.font(9, .bold))
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(pr.targetBranch)
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.field))

                if pr.isDraft {
                    Text("Draft")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.amber)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(NookTheme.amber.opacity(0.18)))
                }

                Spacer(minLength: 0)
            }

            if !pr.title.isEmpty {
                Text(pr.title)
                    .font(NookTheme.font(13.5, .bold))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if !pr.body.isEmpty {
                Divider().opacity(0.12)
                ScrollView(showsIndicators: true) {
                    MarkdownView(text: pr.body, size: 13)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: effectiveMaxHeight)
            }
        }
        .padding(NookTheme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.well))
        .overlay(
            RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

/// Parsed details from a pull request approval proposal
struct PullRequestApprovalPreview: Equatable {
    let repository: String
    let sourceBranch: String
    let targetBranch: String
    let isDraft: Bool
    let title: String
    let body: String

    static func parse(_ text: String) -> PullRequestApprovalPreview? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("→") || trimmed.contains("->") else { return nil }

        let components = trimmed.components(separatedBy: "\n\n")
        guard let firstLine = components.first,
              firstLine.contains("→") || firstLine.contains("->") else { return nil }

        let isDraft = firstLine.localizedCaseInsensitiveContains("draft")
        let cleanFirst = firstLine.replacingOccurrences(of: "· draft", with: "")
            .replacingOccurrences(of: "`", with: "")
        let arrow = cleanFirst.contains("→") ? "→" : "->"
        let parts = cleanFirst.components(separatedBy: arrow)
        guard parts.count == 2 else { return nil }

        let leftParts = parts[0].components(separatedBy: "·")
        let repo = leftParts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let head = (leftParts.count > 1 ? leftParts[1] : leftParts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

        var prTitle = ""
        var bodyIndex = 1
        if components.indices.contains(1) {
            var rawTitle = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if rawTitle.hasPrefix("**") && rawTitle.hasSuffix("**") && rawTitle.count >= 4 {
                rawTitle = String(rawTitle.dropFirst(2).dropLast(2))
            }
            prTitle = rawTitle
            bodyIndex = 2
        }

        let bodyLines = components.dropFirst(bodyIndex).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return PullRequestApprovalPreview(
            repository: repo,
            sourceBranch: head,
            targetBranch: base,
            isDraft: isDraft,
            title: prTitle,
            body: bodyLines
        )
    }
}
