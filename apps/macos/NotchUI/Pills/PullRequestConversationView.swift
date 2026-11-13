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
                Image(icon: "line.3.horizontal.decrease")
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
struct PullRequestConversationRow: View {
    let item: PullRequestConversationItem
    let now: Date

    var body: some View {
        if item.finished {
            FoldedConversation(item: item, now: now)
        } else {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                PullRequestCommentCard(event: item.root, now: now)
                if !item.replies.isEmpty { PullRequestReplies(replies: item.replies, now: now) }
                if item.isThread { PullRequestThreadControls(item: item) }
            }
        }
    }
}

/// What a comment card can do on the page it is on. Nil where nothing may be written (a page without an account).
struct PullRequestCommentActions {
    let viewer: String
    /// False on a locked conversation.
    let canWrite: Bool
    let features: PullRequestForgeFeatures
    let state: PullRequestActionState
    let react: (PullRequestEvent, String) -> Void
    let resolve: (_ threadID: String, _ resolved: Bool) -> Void
}

extension EnvironmentValues {
    @Entry var pullRequestCommentActions: PullRequestCommentActions?
}

/// Under a thread on a line: answer it, and mark it resolved or open it again.
private struct PullRequestThreadControls: View {
    let item: PullRequestConversationItem
    @Environment(\.pullRequestCommentActions) private var actions
    @State private var replying = false

    var body: some View {
        if let actions, actions.canWrite, actions.features.threads {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                if replying, let id = item.root.restComment?.id {
                    PullRequestInlineEditor(initial: "", placeholder: tr("agents.pr.thread.replyPlaceholder"), state: actions.state,
                                            close: { replying = false }) { text in
                        actions.state.pending = .reply(to: id, body: text)
                    }
                } else {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        SmallGhostButton(title: tr("agents.pr.thread.reply")) { replying = true }
                        if let thread = item.root.threadID {
                            SmallGhostButton(title: tr(item.root.resolved ? "agents.pr.thread.unresolve" : "agents.pr.thread.resolve")) {
                                actions.resolve(thread, !item.root.resolved)
                            }
                        }
                    }
                }
            }
            .padding(.leading, NookTheme.Spacing.lg)
        }
    }
}

/// A small field in a comment card: its text is sent with the page's confirmation, and it closes once that went through.
struct PullRequestInlineEditor: View {
    let initial: String
    let placeholder: String
    @ObservedObject var state: PullRequestActionState
    let close: () -> Void
    let send: (String) -> Void
    @State private var text = ""
    @State private var waiting = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(NookTheme.textTertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .lineLimit(2...12)
                .padding(NookTheme.Spacing.sm)
                .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.chip)
                .onExitCommand(perform: close)
            HStack(spacing: NookTheme.Spacing.sm) {
                Spacer(minLength: 0)
                SmallGhostButton(title: tr("button.cancel"), action: close)
                SmallPrimaryButton(title: tr("agents.pr.write.send")) {
                    waiting = true
                    send(text)
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { text = initial }
        .onChange(of: state.finished) { _, _ in if waiting { close() } }
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
/// Your own comment has a pencil under the pointer.
struct PullRequestCommentCard: View {
    let event: PullRequestEvent
    let now: Date
    var reply = false
    var showsAvatar = true
    @Environment(\.pullRequestCommentActions) private var actions
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PullRequestCommentHeader(event: event, now: now, showsAvatar: showsAvatar, onEdit: { editing = true })
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
                .background(NookTheme.rowHover)
            if !reply {
                PullRequestCommentLocation(event: event)
                    .padding(.horizontal, NookTheme.Spacing.lg)
                    .padding(.top, NookTheme.Spacing.md)
            }
            if editing, let actions, let comment = event.restComment {
                PullRequestInlineEditor(initial: event.rawBody ?? event.body, placeholder: "", state: actions.state,
                                        close: { editing = false }) { text in
                    actions.state.pending = .editComment(id: comment.id, lineComment: comment.lineComment, body: text)
                }
                .padding(NookTheme.Spacing.lg)
            } else if !event.body.isEmpty {
                MarkdownView(text: event.body, size: 14)
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
    var onEdit: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory
    @State private var hovering = false
    @Environment(\.sessionContextTarget) private var session
    @Environment(\.sessionPullRequestRef) private var pullRequest
    @Environment(\.pullRequestCommentActions) private var actions

    init(event: PullRequestEvent, now: Date, showsAvatar: Bool = true, onEdit: (() -> Void)? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.event = event
        self.now = now
        self.showsAvatar = showsAvatar
        self.onEdit = onEdit
        self.accessory = accessory
    }

    /// Emoji can be added to comments; GitHub offers no address for a review's.
    private var reactable: Bool { actions?.features.reactions == true && event.reactionPath != nil }
    private var editable: Bool {
        guard let actions, onEdit != nil, event.restComment != nil else { return false }
        return actions.canWrite && actions.features.editComments && !actions.viewer.isEmpty && actions.viewer.lowercased() == event.author.lowercased()
    }

    var body: some View {
        // On one line where it fits; in a narrow panel the emoji take a line of their own under it.
        ViewThatFits(in: .horizontal) {
            row(reactions: true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                row(reactions: false)
                if !event.reactions.isEmpty { PullRequestReactionBar(event: event) }
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
            if let session, let pullRequest, let finding {
                SessionFixButton(help: tr("session.context.fixComment")) {
                    ComposerInbox.shared.add(SessionPrompts.fixComment(pullRequest, author: event.author, path: finding.path,
                                                                       line: finding.line, text: event.body), to: session)
                }
            }
            if let session, let pullRequest, event.replyTo == nil, !event.body.isEmpty {
                // As the link below: under the pointer only, keeping its room.
                ToolbarIconButton("plus.bubble", tr("session.context.addComment"), height: 20, width: 20) {
                    ComposerInbox.shared.add(SessionPrompts.comment(pullRequest, author: event.author, path: place.path, line: place.line,
                                                                    text: event.body), to: session)
                }
                .revealOnHover(hovering)
            }
            if editable, let onEdit {
                ToolbarIconButton("pencil", tr("agents.pr.comment.edit"), height: 20, width: 20, onEdit)
                    .revealOnHover(hovering)
            }
            if reactable {
                PullRequestReactionPicker(event: event).revealOnHover(hovering)
            }
            if reactions, !event.reactions.isEmpty { PullRequestReactionBar(event: event) }
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
                .revealOnHover(hovering)
            }
        }
    }

    /// Where on the diff the comment is, if anywhere.
    private var place: (path: String?, line: Int?) {
        if case .lineComment(let path, let line) = event.kind { return (path, line) }
        return (nil, nil)
    }

    /// What a fix can be about: a line comment or a review that asks for something, not a reply or an approval.
    private var finding: (path: String?, line: Int?)? {
        guard event.replyTo == nil, !event.body.isEmpty else { return nil }
        switch event.kind {
        case .lineComment(let path, let line): return (path, line)
        case .review(let state) where state != "APPROVED": return (nil, nil)
        default: return nil
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
        NookTag(text, tint: color)
    }

    private func plain(_ text: String) -> some View {
        Text(text).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
    }
}

extension PullRequestCommentHeader where Accessory == EmptyView {
    init(event: PullRequestEvent, now: Date, showsAvatar: Bool = true, onEdit: (() -> Void)? = nil) {
        self.init(event: event, now: now, showsAvatar: showsAvatar, onEdit: onEdit) { EmptyView() }
    }
}

/// Where on the diff a comment is: the file and line in mono, and "Outdated" when a push moved the code under it.
private struct PullRequestCommentLocation: View {
    let event: PullRequestEvent

    var body: some View {
        if case .lineComment(let path, let line) = event.kind {
            let label = path + (line.map { ":\($0)" } ?? "")
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: "doc.text").font(NookTheme.font(10))
                Text(label).font(NookTheme.mono(11)).lineLimit(1).truncationMode(.head).help(label)
                if event.outdated {
                    NookTag(tr("agents.pr.thread.outdated"), tint: NookTheme.amber)
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
                        Image(icon: "chevron.down")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.line2))
                    .contentShape(NookTheme.shape(NookTheme.Radius.control))
                }
                .buttonStyle(.nookPlain)
                .accessibilityValue(open ? tr("compose.queue.expanded") : "")
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
            PullRequestCommentLocation(event: item.root)
                .padding(.horizontal, NookTheme.Spacing.lg)
            if open {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    if !item.root.body.isEmpty { MarkdownView(text: item.root.body, size: 14) }
                    if !item.replies.isEmpty { PullRequestReplies(replies: item.replies, now: now) }
                    if item.isThread { PullRequestThreadControls(item: item) }
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
                    .buttonStyle(.nookPlain)
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
struct PullRequestReactionBar: View {
    let event: PullRequestEvent
    @Environment(\.pullRequestCommentActions) private var actions

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ForEach(event.reactions) { reaction in
                Button {
                    actions?.react(event, reaction.content)
                } label: {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        Text(reaction.emoji).font(NookTheme.font(11))
                        Text("\(reaction.count)").font(NookTheme.TextStyle.caption).monospacedDigit()
                    }
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, 1)
                    .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.line2))
                    .contentShape(NookTheme.shape(NookTheme.Radius.control))
                }
                .buttonStyle(.nookPlain)
                .disabled(actions == nil || event.reactionPath == nil)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tr("agents.pr.reaction", reaction.emoji, reaction.count))
            }
        }
    }
}

/// Adds an emoji to a comment; a second click on the same one takes yours off again.
struct PullRequestReactionPicker: View {
    let event: PullRequestEvent
    @Environment(\.pullRequestCommentActions) private var actions

    var body: some View {
        ComposerDropdown(width: 196) {
            Image(icon: "face.smiling")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        } content: {
            ChipFlow(spacing: NookTheme.Spacing.xxs) {
                ForEach(PullRequestReaction.order, id: \.self) { content in
                    DropdownEmoji(emoji: PullRequestReaction(content: content, count: 0).emoji) { actions?.react(event, content) }
                }
            }
        }
        .help(tr("agents.pr.comment.react"))
        .accessibilityLabel(tr("agents.pr.comment.react"))
    }
}

/// One emoji in a dropdown; a click closes it.
private struct DropdownEmoji: View {
    let emoji: String
    let action: () -> Void
    @Environment(\.closeDropdown) private var close

    var body: some View {
        Button {
            close()
            action()
        } label: {
            Text(emoji).font(NookTheme.font(16)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
    }
}
