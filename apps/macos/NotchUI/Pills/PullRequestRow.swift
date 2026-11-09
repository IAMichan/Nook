import SwiftUI
import AppKit

/// What a row says in a session's own list: how the pull request got there, and where it stands in its chain.
struct PullRequestRowLink: Equatable {
    /// Why it is in the list, on the number's tooltip.
    var source: String
    /// How far it is indented: one step for each pull request it is built on.
    var depth: Int
    /// How many pull requests its chain has, itself included.
    var stackSize: Int
    /// Nil where the session cannot watch this pull request.
    var watching: Bool?
    /// The words on the ⋯ menu's last line: unlink or dismiss.
    var removeTitle: String
}

/// One pull request in a list, on the Pull requests page and in the side panel alike: GitHub's state mark (with a small
/// warning on it for a conflict), then two lines. On top the number and title, the checks and the review decision, and
/// the lines added and removed at the end; under it the author's picture and login, the repository, up to three labels
/// in their own colors (in a session's own list the branches instead), its place in a stack, and when it last changed.
struct PullRequestRow: View, Equatable {
    let item: PullRequestItem
    let role: PullRequestRepoGroup.Role
    /// The repository is named on the row unless its group heading already does.
    let showRepo: Bool
    let accountID: String
    /// The pull request open beside the list.
    var selected = false
    /// Where it stands in a stack of pull requests built on each other, if it is in one.
    var stack: (index: Int, count: Int, merged: Int)? = nil
    /// The clock the row's time is counted against (the list's tick), so the time moves on while the list is open.
    var now = Date()
    /// In a session's own list: what the row adds there, and its ⋯ menu's actions.
    var linked: PullRequestRowLink? = nil
    var onWatch: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    /// False for a forge Nook cannot read: no quick actions, and nothing to read ahead.
    var readable = true
    let onOpen: () -> Void
    @State private var hovering = false

    /// What the row draws: it is redrawn only when one of these changes, not with every change elsewhere in the app.
    static func == (lhs: PullRequestRow, rhs: PullRequestRow) -> Bool {
        lhs.item == rhs.item && lhs.role == rhs.role && lhs.showRepo == rhs.showRepo && lhs.accountID == rhs.accountID
            && lhs.selected == rhs.selected && lhs.stack?.index == rhs.stack?.index && lhs.stack?.count == rhs.stack?.count
            && lhs.stack?.merged == rhs.stack?.merged
            && lhs.now == rhs.now && lhs.linked == rhs.linked && lhs.readable == rhs.readable
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) { content }
                .buttonStyle(.plain)
            // Shift shows the quick actions; outside the row's own button, so their clicks stay theirs.
            if readable { PullRequestQuickActionButtons(item: item, accountID: accountID) }
        }
        // Over the time, which keeps its room. Always there, so the menu stays open once the pointer moves into it.
        .overlay(alignment: .bottomTrailing) { if linked != nil { moreMenu } }
        .padding(.leading, CGFloat(min(linked?.depth ?? 0, 3)) * NookTheme.Spacing.xl)
        .overlay(alignment: .leading) {
            if let depth = linked?.depth, depth > 0 {
                NookDivider(vertical: true)
                    .frame(height: 24)
                    .padding(.leading, CGFloat(min(depth, 3)) * NookTheme.Spacing.xl + NookTheme.Spacing.xxs)
            }
        }
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
            .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        // Resting on a row reads it ahead, so the click opens it at once.
        .task(id: hovering) {
            guard hovering, readable else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { PullRequestDetailModel.prefetch(accountID: accountID, item: item) }
        }
        .help(tr("agents.pulls.view"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Into a composer, or anywhere else that takes a link.
        .onDrag { NSItemProvider(object: (item.url?.absoluteString ?? "#\(item.number)") as NSString) }
        .contextMenu {
            if let url = item.url {
                Button(tr("agents.pulls.open")) { NSWorkspace.shared.open(url) }
                Button(tr("agents.pr.copyLink")) { copyLink(url) }
            }
            if !item.headBranch.isEmpty {
                Button(tr("agents.pr.copyBranch")) {
                    Pasteboard.copy(item.headBranch)
                    ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
                }
            }
            if let linked {
                Divider()
                if let watching = linked.watching, let onWatch, item.state == .open {
                    Button(tr(watching ? "agents.pr.linked.stopWatching" : "agents.pr.linked.watch"), action: onWatch)
                }
                if let onRemove { Button(linked.removeTitle, action: onRemove) }
            }
        }
    }

    private func copyLink(_ url: URL) {
        Pasteboard.copy(url.absoluteString)
        ToastCenter.shared.success(tr("agents.pr.copiedLink"))
    }

    /// The row's ⋯, under the pointer only: copy, open, watch, and take it off the list.
    private var moreMenu: some View {
        ComposerDropdown(width: 220) {
            Image(systemName: "ellipsis")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 22, height: 18)
                .contentShape(Rectangle())
        } content: {
            if let url = item.url {
                DropdownRow(symbol: "link", title: tr("agents.pr.copyLink")) { copyLink(url) }
                DropdownRow(symbol: "arrow.up.right", title: tr("agents.pulls.open")) { NSWorkspace.shared.open(url) }
            }
            if let linked {
                if let watching = linked.watching, let onWatch, item.state == .open {
                    DropdownRow(symbol: watching ? "eye.slash" : "eye",
                                title: tr(watching ? "agents.pr.linked.stopWatching" : "agents.pr.linked.watch"), action: onWatch)
                }
                if let onRemove {
                    DropdownDivider()
                    DropdownRow(symbol: "link.badge.plus", title: linked.removeTitle, action: onRemove)
                }
            }
        }
        .help(tr("agents.pr.action.more"))
        .accessibilityLabel(tr("agents.pr.action.more"))
        .opacity(hovering ? 1 : 0)
        .allowsHitTesting(hovering)
        .padding(.trailing, NookTheme.Spacing.sm)
        .padding(.bottom, NookTheme.Spacing.xs)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            stateMark.padding(.top, 2)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                // The number and title lead; how it stands follows them.
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(verbatim: "#\(item.number)")
                        .font(NookTheme.mono(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .monospacedDigit()
                        .fixedSize()
                        .help(linked?.source ?? "")
                    Text(item.title)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(item.state == .open ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                        .help(item.title)
                    HStack(spacing: NookTheme.Spacing.xs) {
                        if linked?.watching == true, item.state == .open {
                            Image(systemName: "eye")
                                .font(NookTheme.font(10, .medium))
                                .foregroundStyle(NookTheme.textTertiary)
                                .help(tr("agents.pr.linked.watching"))
                        }
                        ciMark
                        reviewMark
                    }
                    .fixedSize()
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let additions = item.additions, let deletions = item.deletions {
                        PullRequestLineCounts(additions: additions, deletions: deletions)
                    }
                }
                // Who and where: its chain, the author, the repository, what it waits on, its labels or branches, and
                // when it last changed.
                HStack(spacing: NookTheme.Spacing.sm) {
                    if let linked, linked.stackSize > 1 {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            PullRequestStateIcon(glyph: .stack, tinted: false)
                            Text(verbatim: "\(linked.stackSize)").monospacedDigit()
                        }
                        .fixedSize()
                        .help(tr("agents.pr.linked.stack", linked.stackSize))
                    }
                    if !item.author.isEmpty {
                        HStack(spacing: NookTheme.Spacing.xs) {
                            GitHubAvatar(login: item.author, size: 14)
                            Text(item.author).lineLimit(1)
                        }
                        .help("@" + item.author)
                    }
                    if showRepo {
                        Text(item.repo)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.repo)
                    }
                    if item.draft, item.state == .open {
                        PullRequestTag(text: tr("agents.pulls.draft").localizedCapitalized, color: NookTheme.textSecondary)
                    }
                    // Grouped by repository, the row says it waits for your review; grouped by role, the heading does.
                    if role == .review, item.state == .open, !showRepo { PullRequestTag(text: tr("agents.pulls.scope.reviews"), color: NookTheme.amber) }
                    if linked != nil {
                        branches.layoutPriority(-2)
                    } else {
                        labels.layoutPriority(-2)
                    }
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if let stack, linked == nil {
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            PullRequestStateIcon(glyph: .stack, tinted: false)
                            Text("\(stack.index)/\(stack.count)").monospacedDigit()
                            if stack.merged > 0 {
                                PullRequestStateIcon(glyph: .merged, tinted: false)
                                    .foregroundStyle(PullRequestIcon.tint(.merged))
                            }
                        }
                        .fixedSize()
                        .help(stack.merged > 0 ? tr("agents.pulls.stack.positionMerged", stack.index, stack.count, stack.merged)
                            : tr("agents.pulls.stack.position", stack.index, stack.count))
                    }
                    if let updated = item.updated {
                        Text(AgentFormat.short(now.timeIntervalSince(updated)))
                            .monospacedDigit()
                            .fixedSize()
                            .help(updated.formatted(date: .abbreviated, time: .shortened))
                            .opacity(linked != nil && hovering ? 0 : 1)
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

    /// "feature → main" in mono, each cut in the middle.
    @ViewBuilder
    private var branches: some View {
        if !item.headBranch.isEmpty, !item.baseBranch.isEmpty {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(item.headBranch).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "→").layoutPriority(1)
                Text(item.baseBranch).lineLimit(1).truncationMode(.middle)
            }
            .font(NookTheme.mono(10.5))
            .help(item.headBranch + " → " + item.baseBranch)
        }
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
