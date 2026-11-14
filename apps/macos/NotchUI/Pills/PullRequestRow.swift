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

/// One pull request in a list, on the Pull requests page and in the side panel alike, laid out as GitHub lists them:
/// the state mark (with a small warning on it for a conflict), then two lines. On top the title and up to three labels
/// in their own colors (in a session's own list the branches instead); under it the number, the author and when they
/// opened it, their role in the repository, the repository, its place in a stack, the review and the checks that
/// passed. At the end the lines added and removed over the number of comments.
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
            // ⇧- or ⌘-click picks the row for the selection bar instead of opening it.
            Button {
                if readable, PullRequestSelection.picks() {
                    PullRequestSelection.shared.toggle(item, account: accountID)
                } else {
                    onOpen()
                }
            } label: { content }
                .buttonStyle(.nookPlain)
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
        .roundedBackground(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear), radius: NookTheme.Radius.control)
        .overlay { if readable { PullRequestSelectionRing(id: item.id) } }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        // Resting on a row reads it ahead, so the click opens it at once.
        .task(id: hovering) {
            guard hovering, readable else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { PullRequestDetailModel.prefetch(accountID: accountID, item: item) }
        }
        .help(tr(readable ? "agents.pulls.viewOrSelect" : "agents.pulls.view"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Into a composer, or anywhere else that takes a link.
        .onDrag { NSItemProvider(object: (item.url?.absoluteString ?? "#\(item.number)") as NSString) }
        .contextMenu {
            GitHubLinkMenuItems(url: item.url, branch: item.headBranch)
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
        Pasteboard.copy(url.absoluteString, toast: tr("agents.pr.copiedLink"))
    }

    /// The row's ⋯, under the pointer only: copy, open, watch, and take it off the list.
    private var moreMenu: some View {
        ComposerDropdown(width: 220) {
            Image(icon: "ellipsis")
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
        .revealOnHover(hovering)
        .padding(.trailing, NookTheme.Spacing.sm)
        .padding(.bottom, NookTheme.Spacing.xs)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            stateMark.padding(.top, 2)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                // The title leads, with its labels (in a session's own list its branches) right behind it.
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(item.title)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(item.state == .open ? NookTheme.paper : NookTheme.textSecondary)
                        .lineLimit(1)
                        .help(item.title)
                    if linked?.watching == true, item.state == .open {
                        Image(icon: "eye")
                            .font(NookTheme.font(10, .medium))
                            .foregroundStyle(NookTheme.textTertiary)
                            .help(tr("agents.pr.linked.watching"))
                    }
                    Group {
                        if linked != nil { branches } else { labels }
                    }
                    .layoutPriority(-2)
                    Spacer(minLength: 0)
                }
                // Under it, as GitHub lists it: the number, who opened it and when, how they stand in the repository,
                // where it stands (draft, ready, waiting on you), the review, and the checks that passed.
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(verbatim: "#\(item.number)")
                        .monospacedDigit()
                        .fixedSize()
                        .help(linked?.source ?? "")
                    if !item.author.isEmpty {
                        dot
                        HStack(spacing: NookTheme.Spacing.xs) {
                            GitHubAvatar(login: item.author, size: 14)
                            Text(item.author).lineLimit(1)
                        }
                        .help("@" + item.author)
                    }
                    if let opened = item.created ?? item.updated {
                        Text(Self.opened(now.timeIntervalSince(opened)))
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                            .help(opened.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let role = Self.roleKey(item.authorRole) {
                        NookTag(tr(role)).fixedSize()
                    }
                    if showRepo {
                        dot
                        Text(item.repo)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.repo)
                            .layoutPriority(-1)
                    }
                    if let linked, linked.stackSize > 1 {
                        dot
                        HStack(spacing: NookTheme.Spacing.xxs) {
                            PullRequestStateIcon(glyph: .stack, tinted: false)
                            Text(verbatim: "\(linked.stackSize)").monospacedDigit()
                        }
                        .fixedSize()
                        .help(tr("agents.pr.linked.stack", linked.stackSize))
                    }
                    if let stack, linked == nil {
                        dot
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
                    if item.draft, item.state == .open {
                        dot
                        NookTag(tr("agents.pulls.draft").localizedCapitalized, tint: NookTheme.textSecondary)
                    }
                    // Grouped by repository, the row says it waits for your review; grouped by role, the heading does.
                    if role == .review, item.state == .open, !showRepo {
                        dot
                        NookTag(tr("agents.pulls.scope.reviews"), tint: NookTheme.amber)
                    }
                    // Yours, and nothing left in its way: say so, so it does not wait for a reason nobody sees.
                    if role == .mine, PullRequestRepoGroup.Row(item: item, role: role).isReadyToMerge {
                        dot
                        NookTag(tr("agents.pr.ready.verdict.ready"), tint: NookTheme.mint)
                    }
                    reviewText
                    checksText
                    Spacer(minLength: 0)
                }
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
            }
            // At the end, as on GitHub: the lines it changes over the comments on its conversation.
            VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
                if let additions = item.additions, let deletions = item.deletions {
                    PullRequestLineCounts(additions: additions, deletions: deletions)
                }
                if let comments = item.comments, comments > 0 {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        Image(icon: "bubble.left")
                        Text(verbatim: "\(comments)").monospacedDigit()
                    }
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize()
                    .help(tr("agents.pulls.row.comments", comments))
                }
            }
            // The ⋯ of a session's own list sits over this corner while the pointer is on the row.
            .opacity(linked != nil && hovering ? 0 : 1)
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    /// The "·" between the parts of the second line.
    private var dot: some View {
        Text(verbatim: "·").foregroundStyle(NookTheme.textTertiary)
    }

    /// "opened 6m ago", or "opened just now" in its first minute.
    static func opened(_ interval: TimeInterval) -> String {
        interval < 60 ? tr("agents.pulls.row.openedNow") : tr("agents.pulls.row.opened", AgentFormat.short(interval))
    }

    /// The badge for how the author stands in the repository; nil for no tie (GitHub's NONE) or a list saved before it.
    static func roleKey(_ association: String) -> String? {
        switch association {
        case "OWNER": return "agents.pulls.role.owner"
        case "MEMBER": return "agents.pulls.role.member"
        case "COLLABORATOR": return "agents.pulls.role.collaborator"
        case "CONTRIBUTOR": return "agents.pulls.role.contributor"
        case "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER": return "agents.pulls.role.firstTime"
        default: return nil
        }
    }

    /// "· Review required", "· Approved" or "· Changes requested" while it is open, in words as GitHub writes it.
    @ViewBuilder
    private var reviewText: some View {
        if item.state == .open, let review = item.reviewIcon {
            dot
            HStack(spacing: NookTheme.Spacing.xxs) {
                PullRequestReviewIcon(review: review)
                Text(tr(Self.reviewKey(review))).lineLimit(1)
            }
            .fixedSize()
            .help(tr(Self.reviewKey(review)))
        }
    }

    /// "· ✓ 28/30": the checks' mark and how many of them passed; just the mark when the count is not known.
    @ViewBuilder
    private var checksText: some View {
        if let outcome = item.checkOutcome {
            dot
            HStack(spacing: NookTheme.Spacing.xxs) {
                CheckOutcomeGlyph(outcome: outcome)
                if let passed = item.checksPassed, let total = item.checksTotal, total > 0 {
                    Text(verbatim: "\(passed)/\(total)").monospacedDigit()
                }
            }
            .fixedSize()
            .help(item.checksTotal.map { tr("agents.pulls.row.checks", item.checksPassed ?? 0, $0) }
                ?? tr("agents.pulls.status." + outcome.rawValue))
        }
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
                                      suffix: index == shown.count - 1 && rest > 0 ? "+\(rest)" : nil,
                                      description: item.labelDescriptions[name])
                        }
                    }
                    .fixedSize()
                }
                LabelChip(name: first, color: item.labelColors[first], description: item.labelDescriptions[first]).frame(maxWidth: 120)
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

/// "+120 −8": the lines a pull request adds and removes, the same on a row, the page's header and a file. Large numbers
/// are grouped ("1,204"), and the minus is a real minus sign so both columns line up.
struct PullRequestLineCounts: View {
    let additions: Int
    let deletions: Int
    var font: Font = NookTheme.mono(11, .medium)

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text("+" + additions.formatted()).foregroundStyle(NookTheme.diffAdded)
            Text("−" + deletions.formatted()).foregroundStyle(NookTheme.diffRemoved)
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .help(tr("agents.pulls.linesChanged", additions, deletions))
    }
}
