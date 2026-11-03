import AppKit
import SwiftUI

/// The Summary's comments, read as conversations (see PullRequestConversation): a thread on a line keeps its
/// replies under its first comment behind a thin rule, a resolved thread or a dismissed review folds to one line, the
/// filter hides bots and finished threads, and the most recent conversations show first, ten at a time.
struct PullRequestConversationList: View {
    let detail: PullRequestDetail
    let now: Date
    let newestFirst: Bool
    let showBots: Bool
    let showFinished: Bool
    @State private var shown = PullRequestConversation.page

    var body: some View {
        let all = PullRequestConversation.items(detail.events)
        let filtered = PullRequestConversation.filtered(all, bots: showBots, finished: showFinished)
        let page = PullRequestConversation.recent(filtered, count: shown)
        let ordered = newestFirst ? Array(page.shown.reversed()) : page.shown
        Group {
            if all.isEmpty {
                ListEmptyNote(tr("agents.pr.conversation.none"))
            } else if filtered.isEmpty {
                let hidden = PullRequestConversation.commentCount(all)
                ListEmptyNote(hidden == 1 ? tr("agents.pr.comments.oneHidden") : tr("agents.pr.comments.allHidden", hidden))
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    if !newestFirst { olderButton(hidden: page.hidden) }
                    ForEach(ordered) { item in
                        PullRequestConversationRow(item: item, now: now)
                    }
                    if newestFirst { olderButton(hidden: page.hidden) }
                    if shown > PullRequestConversation.page {
                        HStack {
                            Spacer()
                            SmallGhostButton(title: tr("agents.pr.comments.recentOnly", PullRequestConversation.page)) {
                                withAnimation(NookTheme.reveal) { shown = PullRequestConversation.page }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
        .onChange(of: detail.id) { _, _ in shown = PullRequestConversation.page }
    }

    @ViewBuilder
    private func olderButton(hidden: Int) -> some View {
        if hidden > 0 {
            HStack {
                Spacer()
                SmallGhostButton(title: tr("agents.pr.comments.older", hidden)) {
                    withAnimation(NookTheme.reveal) { shown += PullRequestConversation.page }
                }
                Spacer()
            }
        }
    }
}

/// The filter of the Summary's comments: what to show besides the open conversations of people, and how many that
/// hides right now.
struct PullRequestConversationFilter: View {
    @Binding var showBots: Bool
    @Binding var showFinished: Bool
    let hidden: Int

    var body: some View {
        ComposerDropdown(width: 220) {
            HStack(spacing: NookTheme.Spacing.xxs) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(hidden > 0 ? tr("agents.pr.comments.hidden", hidden) : tr("agents.pr.comments.filter"))
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
            .contentShape(Rectangle())
        } content: {
            DropdownHeader(title: tr("agents.pr.comments.show"))
            DropdownRow(symbol: showBots ? "checkmark.square.fill" : "square", title: tr("agents.pr.comments.bots"),
                        chosen: showBots, staysOpen: true) { showBots.toggle() }
            DropdownRow(symbol: showFinished ? "checkmark.square.fill" : "square", title: tr("agents.pr.comments.finished"),
                        chosen: showFinished, staysOpen: true) { showFinished.toggle() }
        }
        .help(tr("agents.pr.comments.filter"))
        .accessibilityLabel(tr("agents.pr.comments.filter"))
    }
}

/// One conversation: a comment card, or a thread's first comment with its replies under it. A finished one folds.
private struct PullRequestConversationRow: View {
    let item: PullRequestConversationItem
    let now: Date

    var body: some View {
        if item.finished {
            FoldedConversation(item: item, now: now)
        } else {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                PullRequestCommentCard(event: item.root, now: now)
                if !item.replies.isEmpty { PullRequestReplies(replies: item.replies, now: now) }
            }
        }
    }
}

/// A thread's replies, indented behind a thin rule that ties them to the comment above.
private struct PullRequestReplies: View {
    let replies: [PullRequestEvent]
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            NookDivider(vertical: true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                ForEach(replies) { reply in
                    PullRequestCommentCard(event: reply, now: now, reply: true)
                }
            }
        }
        .padding(.leading, NookTheme.Spacing.lg)
    }
}

/// A comment or review as a card: who, when and the verdict in a header strip, then where on the diff it is, then the
/// text. A reply leaves out the place, its thread already says it. On the timeline the picture sits on the rail instead.
struct PullRequestCommentCard: View {
    let event: PullRequestEvent
    let now: Date
    var reply = false
    var showsAvatar = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PullRequestCommentHeader(event: event, now: now, showsAvatar: showsAvatar)
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
                .background(NookTheme.rowHover)
            if !reply {
                PullRequestCommentLocation(event: event)
                    .padding(.horizontal, NookTheme.Spacing.lg)
                    .padding(.top, NookTheme.Spacing.md)
            }
            if !event.body.isEmpty {
                MarkdownView(text: event.body, size: 13.5)
                    .padding(NookTheme.Spacing.lg)
            } else if !reply, case .lineComment = event.kind {
                Color.clear.frame(height: NookTheme.Spacing.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }
}

/// The top line of a comment: picture, name, its verdict as a tinted pill (or a review's plain state), the emoji people
/// answered with, how long ago, and a button to open it on GitHub.
private struct PullRequestCommentHeader<Accessory: View>: View {
    let event: PullRequestEvent
    let now: Date
    var showsAvatar = true
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false

    init(event: PullRequestEvent, now: Date, showsAvatar: Bool = true, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.event = event
        self.now = now
        self.showsAvatar = showsAvatar
        self.accessory = accessory
    }

    var body: some View {
        // On one line where it fits; in a narrow panel the emoji take a line of their own under it.
        ViewThatFits(in: .horizontal) {
            row(reactions: true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                row(reactions: false)
                if !event.reactions.isEmpty { PullRequestReactionBar(reactions: event.reactions) }
            }
        }
        .onHover { hovering = $0 }
    }

    private func row(reactions: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if showsAvatar { GitHubAvatar(login: event.author, size: 18) }
            Text("@" + event.author).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
            verdict
            accessory()
            Spacer(minLength: NookTheme.Spacing.xs)
            if reactions, !event.reactions.isEmpty { PullRequestReactionBar(reactions: event.reactions) }
            if let date = event.date {
                Text(AgentFormat.short(now.timeIntervalSince(date)))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .monospacedDigit()
                    .help(date.formatted(date: .abbreviated, time: .shortened))
            }
            if let url = event.url {
                // Under the pointer only: ten comments should not mean ten buttons at rest. It keeps its room, so the
                // time beside it does not jump.
                ToolbarIconButton("arrow.up.right", tr("agents.pulls.open"), height: 20, width: 20) {
                    NSWorkspace.shared.open(url)
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if case .review(let state) = event.kind {
            switch state {
            case "APPROVED": pill(tr("agents.pr.event.approved"), NookTheme.mint)
            case "CHANGES_REQUESTED": pill(tr("agents.pr.event.changes"), NookTheme.coral)
            case "DISMISSED": plain(tr("agents.pr.event.dismissed"))
            default: plain(tr("agents.pr.event.reviewed"))
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(color)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .lineLimit(1)
    }

    private func plain(_ text: String) -> some View {
        Text(text).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
    }
}

extension PullRequestCommentHeader where Accessory == EmptyView {
    init(event: PullRequestEvent, now: Date, showsAvatar: Bool = true) {
        self.init(event: event, now: now, showsAvatar: showsAvatar) { EmptyView() }
    }
}

/// Where on the diff a comment is: the file and line in mono, and "Outdated" when a push moved the code under it.
private struct PullRequestCommentLocation: View {
    let event: PullRequestEvent

    var body: some View {
        if case .lineComment(let path, let line) = event.kind {
            let label = path + (line.map { ":\($0)" } ?? "")
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "doc.text").font(NookTheme.font(10))
                Text(label).font(NookTheme.mono(11)).lineLimit(1).truncationMode(.head).help(label)
                if event.outdated {
                    Text(tr("agents.pr.thread.outdated"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.amber)
                        .padding(.horizontal, NookTheme.Spacing.sm)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(NookTheme.amber.opacity(0.12)))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(NookTheme.textTertiary)
        }
    }
}

/// A resolved thread or a dismissed review, folded to its header and one plain line of what it said. "Resolved ⌄"
/// (or the click on that line) unfolds it with its replies.
private struct FoldedConversation: View {
    let item: PullRequestConversationItem
    let now: Date
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PullRequestCommentHeader(event: item.root, now: now) {
                if !item.replies.isEmpty {
                    Text(item.replies.count == 1 ? tr("agents.pr.comments.reply") : tr("agents.pr.comments.replies", item.replies.count))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Button(action: toggle) {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        Text(tr(item.root.resolved ? "agents.pr.thread.resolved" : "agents.pr.thread.dismissed"))
                        Image(systemName: "chevron.down")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .background(Capsule().fill(NookTheme.line2))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? tr("compose.queue.expanded") : "")
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
            PullRequestCommentLocation(event: item.root)
                .padding(.horizontal, NookTheme.Spacing.lg)
            if open {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    if !item.root.body.isEmpty { MarkdownView(text: item.root.body, size: 13.5) }
                    if !item.replies.isEmpty { PullRequestReplies(replies: item.replies, now: now) }
                }
                .padding(NookTheme.Spacing.lg)
                .transition(.opacity)
            } else {
                let preview = PullRequestConversation.preview(item.root.body)
                if !preview.isEmpty {
                    Button(action: toggle) {
                        Text(preview)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, NookTheme.Spacing.lg)
                    .padding(.top, NookTheme.Spacing.xs)
                }
                Color.clear.frame(height: NookTheme.Spacing.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func toggle() {
        withAnimation(NookTheme.reveal) { open.toggle() }
    }
}

/// The emoji on a comment, each with how many chose it, as quiet pills.
private struct PullRequestReactionBar: View {
    let reactions: [PullRequestReaction]

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ForEach(reactions) { reaction in
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Text(reaction.emoji).font(NookTheme.font(11))
                    Text("\(reaction.count)").font(NookTheme.TextStyle.caption).monospacedDigit()
                }
                .foregroundStyle(NookTheme.textSecondary)
                .padding(.horizontal, NookTheme.Spacing.sm)
                .padding(.vertical, 1)
                .background(Capsule().fill(NookTheme.line2))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("agents.pr.reaction", reaction.emoji, reaction.count))
            }
        }
    }
}
