import SwiftUI
import AppKit

/// A permission request from an agent: what it wants (the whole command or the whole change), how risky that looks, and
/// the buttons to decide. The notch and the Agents list show it as a card; a conversation as a row of its timeline
/// (`inline`), the request lined up with the work lines above it.
struct ApprovalView: View {
    let approval: AgentApproval
    /// Other requests waiting behind this one.
    var more = 0
    /// Fixed palette for the dark notch and the window alike.
    var maxHeight: CGFloat? = nil
    /// In a conversation: no card, the mark in the work lines' column and the words under it indented to theirs.
    var inline = false
    let onDecide: (ApprovalDecision) -> Void
    /// Allow with the secret typed in the field (only for a secret Nook does not keep yet).
    var onSecret: ((BridgeSecretAnswer) -> Void)? = nil
    /// Deny and tell the agent why, or what to do instead (see `ProviderCapabilities.denyReason`). Nil where the
    /// request has nobody to read a reason.
    var onDenyWithReason: ((String) -> Void)? = nil
    @State private var secretValue = ""
    @State private var rememberSecret = false
    @State private var writingReason = false
    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

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
        Group {
            if inline { inlineBody } else { cardBody }
        }
        // A typed secret belongs to its own request only.
        .onChange(of: approval.id) {
            secretValue = ""
            rememberSecret = false
            writingReason = false
            reason = ""
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            titleBlock
            Group {
                content
                secretField
                reasonField
                AdaptiveActionRow {
                    Label(AgentDisplayState.approval.longWord, systemImage: "shield")
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(approval.danger ? NookTheme.coral : NookTheme.amber)
                } actions: {
                    actions
                }
            }
            .padding(.leading, TranscriptStyle.workIndent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardBody: some View {
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
            secretField
            reasonField
        }
        .padding(NookTheme.Spacing.lg)
        .cardBackground(NookTheme.surface, stroke: approval.danger ? NookTheme.coral.opacity(0.35) : NookTheme.amber.opacity(0.25),
                        radius: NookTheme.Radius.panel, style: .continuous)
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            headerIcon
                .frame(width: inline ? TranscriptStyle.workIcon : 18, height: 18)
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
            Image(icon: "pencil.line")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.amber)
        } else if approval.danger {
            Image(icon: "exclamationmark.triangle.fill")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.coral)
        } else {
            Image(icon: "terminal.fill")
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.amber)
        }
    }

    /// Where the value of a secret Nook does not keep yet is typed or pasted: hidden, and gone with the request.
    @ViewBuilder
    private var secretField: some View {
        if let name = approval.secretName, onSecret != nil {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(spacing: NookTheme.Spacing.md) {
                    Image(icon: "key.fill").foregroundStyle(NookTheme.textTertiary)
                    SecureField(approval.secretKeepable ? tr("bridge.approval.secretField", name) : tr("secrets.sudo.field"),
                                text: $secretValue)
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.body)
                        .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                        .frame(minWidth: 160)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.field))
                        .onSubmit(allow)
                }
                if approval.secretKeepable {
                    Toggle(tr("bridge.secret.prompt.remember"), isOn: $rememberSecret)
                        .toggleStyle(.checkbox)
                        .font(NookTheme.TextStyle.caption)
                }
            }
        }
    }

    /// Where the reason for a denial is typed: Return denies with it, Escape closes it again.
    @ViewBuilder
    private var reasonField: some View {
        if writingReason, onDenyWithReason != nil {
            HStack(spacing: NookTheme.Spacing.md) {
                Image(icon: "text.bubble").foregroundStyle(NookTheme.textTertiary)
                TextField(tr("approval.denyReason.placeholder"), text: $reason, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(NookTheme.TextStyle.body)
                    .lineLimit(1...4)
                    .focused($reasonFocused)
                    .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                    .padding(.vertical, NookTheme.Spacing.xs + NookTheme.Spacing.xxs)
                    .frame(minWidth: 160, minHeight: 30)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.field))
                    .onSubmit(deny)
                    .onExitCommand {
                        writingReason = false
                        reason = ""
                    }
            }
            .onAppear { reasonFocused = true }
        }
    }

    /// Deny: with the typed reason when there is one.
    private func deny() {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if writingReason, let onDenyWithReason, !text.isEmpty {
            reason = ""
            writingReason = false
            onDenyWithReason(text)
        } else {
            onDecide(.deny)
        }
    }

    /// Allow: with the typed secret when there is one, otherwise as usual (Nook then asks for the value itself).
    private func allow() {
        let value = secretValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if approval.secretName != nil, let onSecret, !value.isEmpty {
            secretValue = ""
            onSecret(BridgeSecretAnswer(value: value, remember: approval.secretKeepable && rememberSecret))
        } else {
            onDecide(.allow)
        }
    }

    private var actions: some View {
        NookNoticeActions(
            primary: NookNoticeAction(tr("button.allow")) { allow() },
            secondary: NookNoticeAction(tr("button.deny")) { deny() },
            extra: (approval.canAlways ? [NookNoticeAction(tr("button.always")) { onDecide(.always) }] : [])
                + (onDenyWithReason != nil && !writingReason
                    ? [NookNoticeAction(tr("approval.denyReason")) { writingReason = true }] : [])
                + (approval.canTerminal ? [NookNoticeAction(tr("approval.inTerminal")) { onDecide(.terminal) }] : [])
                // The page where the secret is found or made, as the agent named it (http or https only).
                + (approval.signInURL.map { url in [NookNoticeAction(tr("secrets.signIn.open")) { NSWorkspace.shared.open(url) }] } ?? [])
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
                    .stroke(NookTheme.wash.opacity(0.06), lineWidth: 1)
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
                    .stroke(NookTheme.wash.opacity(0.06), lineWidth: 1)
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
                    .stroke(NookTheme.wash.opacity(0.06), lineWidth: 1)
            )
        }
    }

    private func pullRequestCard(_ pr: PullRequestApprovalPreview) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            // Branch flow bar
            HStack(spacing: NookTheme.Spacing.xs) {
                if !pr.repository.isEmpty {
                    HStack(spacing: 4) {
                        Image(icon: "shippingbox.fill")
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
                    Image(icon: "arrow.triangle.branch")
                        .font(NookTheme.font(10, .semibold))
                        .foregroundStyle(NookTheme.amber)
                    Text(pr.sourceBranch)
                        .font(NookTheme.mono(11, .medium))
                        .foregroundStyle(NookTheme.paper)
                    Image(icon: "arrow.right")
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
                .stroke(NookTheme.wash.opacity(0.06), lineWidth: 1)
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
