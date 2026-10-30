import SwiftUI
import AppKit

/// One pull request in a list, on the Pull requests page and in the side panel's picker alike: GitHub's state mark (with
/// a small warning on it for a conflict), then two lines. On top the title (so titles line up in one column), the checks
/// and the review decision, and the lines added and removed at the end; under it the repository and number, the author's
/// picture and login, up to three labels in their own colors, its place in a stack, and when it last changed at the end.
struct PullRequestRow: View {
    let item: PullRequestItem
    let role: PullRequestRepoGroup.Role
    /// The repository is named on the row unless its group heading already does.
    let showRepo: Bool
    let accountID: String
    /// The pull request open beside the list.
    var selected = false
    /// Where it stands in a stack of pull requests built on each other, if it is in one.
    var stack: (index: Int, count: Int)? = nil
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
            // Shift shows the quick actions; outside the row's own button, so their clicks stay theirs.
            PullRequestQuickActionButtons(item: item, accountID: accountID)
        }
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
            .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
        .selectionMark(selected)
        .onHover { hovering = $0 }
        // Resting on a row reads it ahead, so the click opens it at once.
        .task(id: hovering) {
            guard hovering else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { PullRequestDetailModel.prefetch(accountID: accountID, item: item) }
        }
        .help(tr("agents.pulls.view"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            if let url = item.url {
                Button(tr("agents.pulls.open")) { NSWorkspace.shared.open(url) }
                Button(tr("agents.pr.copyLink")) {
                    Pasteboard.copy(url.absoluteString)
                    ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                }
            }
            if !item.headBranch.isEmpty {
                Button(tr("agents.pr.copyBranch")) {
                    Pasteboard.copy(item.headBranch)
                    ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
                }
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            stateMark.padding(.top, 2)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                // The title leads, so the titles of a list line up in one column; what it is about follows it.
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(item.title)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(item.state == .open ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                        .help(item.title)
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ciMark
                        reviewMark
                    }
                    .fixedSize()
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let additions = item.additions, let deletions = item.deletions {
                        PullRequestLineCounts(additions: additions, deletions: deletions)
                    }
                }
                // Where and who: "acme/app #12", the author, what it waits on, its labels, and when it last changed.
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(showRepo ? "\(item.repo) #\(item.number)" : "#\(item.number)")
                        .monospacedDigit()
                        .lineLimit(1)
                        // Shortened in the middle, so the number at the end always shows.
                        .truncationMode(.middle)
                    if !item.author.isEmpty {
                        HStack(spacing: NookTheme.Spacing.xs) {
                            GitHubAvatar(login: item.author, size: 14)
                            Text(item.author).lineLimit(1)
                        }
                        .help("@" + item.author)
                    }
                    if item.draft, item.state == .open {
                        PullRequestTag(text: tr("agents.pulls.draft").localizedCapitalized, color: NookTheme.textSecondary)
                    }
                    // Grouped by repository, the row says it waits for your review; grouped by role, the heading does.
                    if role == .review, item.state == .open, !showRepo { PullRequestTag(text: tr("agents.pulls.scope.reviews"), color: NookTheme.amber) }
                    labels.layoutPriority(-2)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let stack {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            PullRequestStateIcon(glyph: .stack, tinted: false)
                            Text("\(stack.index)/\(stack.count)").monospacedDigit()
                        }
                        .fixedSize()
                        .help(tr("agents.pulls.stack.position", stack.index, stack.count))
                    }
                    if let updated = item.updated {
                        Text(AgentFormat.short(Date().timeIntervalSince(updated)))
                            .monospacedDigit()
                            .fixedSize()
                            .help(updated.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    /// GitHub's mark in the state's color; an open pull request that conflicts with its base wears the conflict mark.
    private var stateMark: some View {
        PullRequestStateIcon(glyph: item.stateGlyph, size: .header)
            .help(tr(stateKey))
    }

    /// The first label, and the next two when there is room; "+2" for the ones left out.
    @ViewBuilder
    private var labels: some View {
        if let first = item.labels.first {
            ViewThatFits(in: .horizontal) {
                ForEach([3, 2, 1], id: \.self) { count in
                    HStack(spacing: NookTheme.Spacing.xs) {
                        let shown = Array(item.labels.prefix(count))
                        ForEach(Array(shown.enumerated()), id: \.offset) { index, name in
                            let rest = item.labels.count - shown.count
                            LabelChip(name: name, color: item.labelColors[name],
                                      suffix: index == shown.count - 1 && rest > 0 ? "+\(rest)" : nil)
                        }
                    }
                    .fixedSize()
                }
                LabelChip(name: first, color: item.labelColors[first]).frame(maxWidth: 120)
            }
        }
    }

    private var stateKey: String {
        switch item.state {
        case .merged: return "agents.pulls.state.merged"
        case .closed: return "agents.pulls.state.closed"
        case .open: return item.conflict ? "agents.pulls.state.conflict" : item.draft ? "agents.pulls.draft" : "agents.pulls.state.open"
        }
    }

    /// The checks as their filled circle, right behind the title, so you see at a glance whether CI passed.
    @ViewBuilder
    private var ciMark: some View {
        if let outcome = item.checkOutcome {
            CheckOutcomeGlyph(outcome: outcome)
                .help(tr("agents.pulls.status." + outcome.rawValue))
        }
    }
}

extension PullRequestRow {
    /// The review decision next to the checks: approved, changes requested, or waiting for a required review.
    @ViewBuilder
    var reviewMark: some View {
        if item.state == .open, let review = item.reviewIcon {
            PullRequestReviewIcon(review: review)
                .help(tr(Self.reviewKey(review)))
        }
    }

    private static func reviewKey(_ review: PullRequestIcon.Review) -> String {
        switch review {
        case .approved: return "agents.pulls.review.approved"
        case .changesRequested: return "agents.pulls.review.changes"
        default: return "agents.pulls.review.required"
        }
    }
}

/// A small tinted capsule on a row or a group heading: "Draft", "Reviews", "2 to review".
struct PullRequestTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(color)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}

/// "+120 −8": the lines a pull request adds and removes, the same on a row, the page's header and a file. Large numbers
/// are grouped ("1,204"), and the minus is a real minus sign so both columns line up.
struct PullRequestLineCounts: View {
    let additions: Int
    let deletions: Int
    var font: Font = NookTheme.mono(11, .medium)

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text("+" + additions.formatted()).foregroundStyle(NookTheme.mint)
            Text("−" + deletions.formatted()).foregroundStyle(NookTheme.coral)
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .help(tr("agents.pulls.linesChanged", additions, deletions))
    }
}
