import AppKit
import SwiftUI

/// One pull request, read in full inside Nook, laid out. A fixed top with the crumbs
/// (repository and the number in its state's color), the main action (merge, ready for review, or the state) and the ⋯
/// menu, then the title, author, checkout command, branches and size, then the tabs; it folds to one line once you
/// scroll past the title. Under it four tabs: Summary (reviewers and labels, then the description, the checks and
/// the comments in sections that fold, the comments as threads them; see
/// PullRequestConversationList), Guide, Timeline (everything that happened, commits included) and Code (every
/// changed file with its diff). The bar under the tabs says what the open tab holds: the checks on Summary, the
/// comments, commits and approvals with the order on Timeline, the files viewed on Code. Merge asks for a second click and
/// uses the account it was listed under; the round button at the bottom right opens the composer.
///
/// The page opens at once: the top shows what the list already knew while GitHub is asked, the overview follows with
/// the first answer and the timeline, commits and files after it (see PullRequestDetailModel, which also keeps it
/// current while open).
struct PullRequestDetailView: View {
    @EnvironmentObject private var app: AppModel
    let accountID: String
    let item: PullRequestItem
    /// Beside the pull request list (a side panel): the button that leaves it closes the panel, on the right. The
    /// Pull requests page puts that button on its tab line instead and passes no `onBack`.
    let inline: Bool
    /// Nil beside a session, where the side panel's tab closes it instead.
    let onBack: (() -> Void)?

    enum Tab: Hashable { case summary, guide, timeline, code }

    @StateObject private var model: PullRequestDetailModel
    @State private var tab: Tab = .summary
    @State private var openFile: String?
    /// Files you marked as viewed; a mark lapses when a push changes the file.
    @State private var viewed = PullRequestViewedFiles.load()
    /// The review guide written for this pull request, if any, and whether one is being written.
    @State private var guide: PullRequestReviewGuide?
    @State private var writingGuide = false
    @State private var guideFailed = false
    @AppStorage("agents.pr.mergeMethod") private var methodRaw = PullRequestMergeMethod.merge.rawValue
    /// The merge button's first click arms it ("Confirm merge?"), the second merges; it disarms by itself after a while.
    @State private var armedMerge = false
    @State private var armToken = UUID()
    @State private var merging = false
    /// Scrolled past the title: the top folds to one line (number and title).
    @State private var condensed = false
    /// The popover that says in full what may still hold the merge back.
    @State private var showBlocker = false
    /// The composer, the ⋯ menu's actions and their confirmation.
    @StateObject private var actions = PullRequestActionState()
    /// The timeline newest first, when chosen.
    @AppStorage("agents.pr.timelineNewest") private var newestFirst = false
    /// The Summary's sections that fold, open at first: the description and comments, the checks folded.
    @State private var descriptionOpen = true
    @State private var checksOpen = false
    @State private var commentsOpen = true
    @AppStorage("agents.pr.commentsNewest") private var commentsNewestFirst = false
    /// Comments by bots (CI reports, coverage, previews), resolved threads and dismissed reviews are left out of the
    /// Summary until you ask for them in its filter.
    @AppStorage("agents.pr.showBotComments") private var showBotComments = false
    @AppStorage("agents.pr.showFinishedComments") private var showFinishedComments = false

    /// The stack this pull request is part of, bottom first (empty when it stands alone), and how to open another one of it.
    let stack: [PullRequestItem]
    let onOpenPullRequest: ((PullRequestItem) -> Void)?
    /// Merging the stack up to here waits for its second click, then runs.
    @State private var confirmStackMerge = false
    @State private var mergingStack = false

    /// Hands the row back as the page last read it (merged, closed, ready for review, in conflict), so the tab that
    /// holds it shows the same mark as the page.
    let onUpdate: ((PullRequestItem) -> Void)?

    init(accountID: String, item: PullRequestItem, inline: Bool = false, stack: [PullRequestItem] = [],
         onOpenPullRequest: ((PullRequestItem) -> Void)? = nil, onUpdate: ((PullRequestItem) -> Void)? = nil,
         onBack: (() -> Void)? = nil) {
        self.accountID = accountID
        self.item = item
        self.inline = inline
        self.stack = stack
        self.onOpenPullRequest = onOpenPullRequest
        self.onUpdate = onUpdate
        self.onBack = onBack
        _model = StateObject(wrappedValue: PullRequestDetailModel(accountID: accountID, item: item))
    }

    private var detail: PullRequestDetail? { model.detail }

    private var method: PullRequestMergeMethod {
        let chosen = PullRequestMergeMethod(rawValue: methodRaw) ?? .merge
        guard let detail, !detail.methods.contains(chosen) else { return chosen }
        return detail.methods.first ?? chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock
            if confirmStackMerge || mergingStack { stackMergeBar.padding(.top, NookTheme.Spacing.sm) }
            if let detail {
                ZStack(alignment: .bottomTrailing) {
                    // The relative times in the timeline and the commits tick along, once a minute.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        content(detail, now: context.date)
                    }
                    if actions.panel != .write { writeButton(detail) }
                }
                .frame(maxHeight: .infinity)
                if actions.panel != .none || actions.pending != nil || actions.error != nil {
                    PullRequestActionPanel(state: actions, model: model, accountID: accountID, detail: detail)
                        .padding(.top, NookTheme.Spacing.sm)
                        .transition(.opacity)
                }
            } else if let error = model.error {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    Text(tr("agents.pr.loadFailed")).font(NookTheme.TextStyle.title).foregroundStyle(NookTheme.paper)
                    Text(error)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    NookPrimaryButton(title: tr("agents.pr.retry")) { Task { await model.refresh(activity: true) } }
                        .padding(.top, NookTheme.Spacing.xs)
                }
                .padding(.top, NookTheme.Spacing.lg)
                Spacer(minLength: 0)
            } else {
                PullRequestDetailGhost().padding(.top, NookTheme.Spacing.lg)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await model.run() }
        // Back in Nook after a while elsewhere: look at once instead of at the next tick.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !merging { Task { await model.refresh() } }
        }
        .onChange(of: detail.map { "\($0.state.rawValue)|\($0.conflicted)" }) { _, _ in
            guard let detail, let onUpdate else { return }
            let updated = item.updated(from: detail)
            if updated != item { onUpdate(updated) }
        }
        .onChange(of: detail?.files.map(\.path) ?? []) { _, paths in
            if let path = openFile, detail?.activityLoaded == true, !paths.contains(path) { openFile = nil }
        }
    }

    // MARK: Header

    /// The top of the page, laid out: the crumbs with the page's actions, the title, who and when, the
    /// branches and the size, then the tabs, ruled off from the content that scrolls under it. Once the title is
    /// scrolled away the middle folds to one line and the crumbs show the number and title instead.
    private var headerBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar
            if condensed {
                condensedLine
                    .padding(.bottom, NookTheme.Spacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                header
                    .padding(.top, NookTheme.Spacing.xs)
                    .padding(.bottom, NookTheme.Spacing.lg)
                    .transition(.opacity)
            }
            if let detail {
                NookDivider()
                tabs(detail).padding(.vertical, NookTheme.Spacing.sm)
            }
            NookDivider()
        }
        .animation(NookTheme.reveal, value: condensed)
    }

    private var topBar: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let onBack, !inline {
                ToolbarIconButton("arrow.left", tr("agents.pr.back"), onBack)
            }
            crumbs
            Spacer(minLength: NookTheme.Spacing.sm)
            if stack.count > 1 { stackMenu }
            if let detail {
                primaryAction(detail)
                // Refreshing is in the ⋯ menu, which spins while GitHub is asked.
                PullRequestMoreMenu(state: actions, detail: detail, loading: model.loading, fetchedAt: model.fetchedAt) {
                    Task { await model.refresh(activity: true) }
                }
            } else if model.loading {
                ProgressView().controlSize(.small)
            }
            if let onBack, inline {
                ToolbarIconButton("sidebar.right", tr("agents.pr.closePanel"), onBack)
            }
        }
        .frame(height: 32)
    }

    /// "acme/app #12↗", or "#12↗ Title" once folded. The number wears the state's color and opens it on GitHub.
    private var crumbs: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if condensed {
                numberLink
                Text(detail?.title ?? item.title)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail?.title ?? item.title)
            } else {
                Text(item.repo).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.tail)
                numberLink
            }
        }
        .font(NookTheme.TextStyle.label)
    }

    private var numberLink: some View {
        Button {
            if let url = detail?.url ?? item.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                Text("#\(item.number)").monospacedDigit()
                Image(systemName: "arrow.up.right.square").font(NookTheme.font(9, .medium))
            }
            .foregroundStyle(PullRequestIcon.tint(glyph))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(tr("agents.pulls.open"))
        .accessibilityLabel(tr("agents.pulls.open"))
    }

    /// What the pull request is: shown from the list's row at once, and filled in when GitHub answers.
    private var header: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(detail?.title ?? item.title)
                .font(NookTheme.font(16, .semibold))
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(detail?.title ?? item.title)
                .textSelection(.enabled)
            HStack(spacing: NookTheme.Spacing.sm) {
                let author = detail?.author ?? item.author
                HStack(spacing: NookTheme.Spacing.sm) {
                    if !author.isEmpty {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            GitHubAvatar(login: author, size: 16)
                            Text(author).font(NookTheme.font(12, .medium)).foregroundStyle(NookTheme.paper)
                        }
                        .help("@" + author)
                    }
                    if let updated = detail?.updated ?? item.updated {
                        if !author.isEmpty { Text("·").foregroundStyle(NookTheme.textMuted.opacity(0.6)) }
                        Text(tr("agents.pr.updatedAgo", AgentFormat.short(Date().timeIntervalSince(updated))))
                    }
                }
                .help(detail?.created.map { tr("agents.pr.openedAgo", AgentFormat.short(Date().timeIntervalSince($0))) } ?? "")
                Spacer(minLength: NookTheme.Spacing.sm)
                if let detail { checkoutCommand(detail) }
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
            if let detail {
                branchLine(detail).padding(.top, NookTheme.Spacing.md)
            } else {
                GhostBar(width: 260).padding(.top, NookTheme.Spacing.md)
            }
        }
    }

    /// The folded middle: the author and when, the branches, and the size, in one quiet line.
    private var condensedLine: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            let author = detail?.author ?? item.author
            if !author.isEmpty { GitHubAvatar(login: author, size: 16).help("@" + author) }
            if let updated = detail?.updated ?? item.updated {
                Text(AgentFormat.short(Date().timeIntervalSince(updated))).monospacedDigit()
            }
            if let detail {
                NookDivider(vertical: true).frame(height: 12)
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text(detail.baseBranch).lineLimit(1)
                    Image(systemName: "arrow.left").font(NookTheme.font(8.5, .semibold)).foregroundStyle(NookTheme.textMuted)
                    Text(detail.headBranch).lineLimit(1).truncationMode(.middle)
                }
                .font(NookTheme.mono(10.5))
                .foregroundStyle(NookTheme.textMuted)
                Spacer(minLength: NookTheme.Spacing.sm)
                diffStat(detail, compact: true)
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textTertiary)
        .frame(height: 20)
    }

    /// `gh pr checkout 12 --repo acme/app` in mono; a click copies it.
    private func checkoutCommand(_ detail: PullRequestDetail) -> some View {
        Button {
            Pasteboard.copy(PullRequestMoreMenu.checkout(detail))
            ToastCenter.shared.success(tr("agents.pr.action.copied"))
        } label: {
            Text("gh pr checkout \(detail.number)").font(NookTheme.mono(11.5))
                .foregroundStyle(NookTheme.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(tr("agents.pr.action.copyCheckout"))
    }

    /// The list's state until the page has loaded (so a known conflict shows at once), then the page's.
    private var glyph: PullRequestBadge.Glyph {
        guard let detail else { return item.stateGlyph }
        return PullRequestBadge.Glyph(detail.state, conflicted: detail.conflicted)
    }

    /// "main ← feature" in mono (a click on the head copies it), the update button when the branch is behind, and on
    /// the right how many files and lines changed.
    private func branchLine(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(detail.baseBranch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.left").font(NookTheme.font(10, .medium)).foregroundStyle(NookTheme.textMuted.opacity(0.6))
                Button {
                    Pasteboard.copy(detail.headBranch)
                    ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
                } label: {
                    Text(detail.headBranch).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(tr("agents.pr.copyBranch"))
            }
            .font(NookTheme.mono(11.5))
            .foregroundStyle(NookTheme.textMuted)
            if detail.isOpen && detail.mergeState == "behind" {
                Button {
                    actions.close()
                    actions.pending = .updateBranch(headSHA: detail.headSHA)
                } label: {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(tr("agents.pr.behind"))
                    }
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.amber)
                }
                .buttonStyle(.plain)
                .help(tr("agents.pr.action.updateBranch"))
            }
            Spacer(minLength: NookTheme.Spacing.sm)
            diffStat(detail)
        }
    }

    /// How many files and the lines added and removed them; folded, the number of files alone.
    private func diffStat(_ detail: PullRequestDetail, compact: Bool = false) -> some View {
        let files = max(detail.changedFiles, detail.files.count)
        return HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: "doc.text").font(NookTheme.font(compact ? 9.5 : 10.5))
                Text(compact ? "\(files)" : tr("agents.pr.filesCount", files))
            }
            .foregroundStyle(NookTheme.textTertiary)
            .help(tr("agents.pr.filesCount", files))
            if detail.additions > 0 || detail.deletions > 0 {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Text("+\(detail.additions)").foregroundStyle(NookTheme.mint)
                    Text("-\(detail.deletions)").foregroundStyle(NookTheme.coral)
                }
                .font(NookTheme.mono(compact ? 10.5 : 12))
            }
        }
        .font((compact ? NookTheme.font(10.5) : NookTheme.TextStyle.detail).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    /// The round button at the bottom right that opens the composer (a comment or a review).
    private func writeButton(_ detail: PullRequestDetail) -> some View {
        Button {
            withAnimation(NookTheme.swap) { actions.open(.write, detail: detail) }
        } label: {
            Image(systemName: "bubble.left")
                .font(NookTheme.font(14, .medium))
                .foregroundStyle(NookTheme.paper)
                .frame(width: 38, height: 38)
                .background(Circle().fill(NookTheme.smoke))
                .overlay(Circle().strokeBorder(NookTheme.line2, lineWidth: 1))
                .shadow(color: NookTheme.notch.opacity(0.45), radius: 10, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(actions.sending)
        .help(tr("agents.pr.write.open"))
        .accessibilityLabel(tr("agents.pr.write.open"))
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.bottom, NookTheme.Spacing.md)
    }

    // MARK: Stack

    /// The pull requests to merge to land this one: from the bottom of the stack up to here.
    private var stackToMerge: [PullRequestItem] {
        guard let index = stack.firstIndex(where: { $0.id == item.id }) else { return [] }
        return Array(stack[...index])
    }

    /// The stack this pull request stands in, bottom first: a click opens another one of it, and the last line merges
    /// the stack up to here.
    private var stackMenu: some View {
        let index = (stack.firstIndex { $0.id == item.id } ?? 0) + 1
        return Menu {
            Section(tr("agents.pulls.stack.title", stack.count)) {
                ForEach(Array(stack.enumerated()), id: \.element.id) { position, member in
                    Button {
                        if member.id != item.id { onOpenPullRequest?(member) }
                    } label: {
                        let mark = member.id == item.id ? "✓ " : ""
                        Text(mark + "\(position + 1). #\(member.number) \(member.title)")
                    }
                    .disabled(onOpenPullRequest == nil && member.id != item.id)
                }
            }
            if stackToMerge.count > 1 {
                Divider()
                Button(tr("agents.pulls.stack.merge", stackToMerge.count)) { confirmStackMerge = true }
                    .disabled(mergingStack)
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                PullRequestStateIcon(glyph: .stack, tinted: false)
                Text("\(index)/\(stack.count)").font(NookTheme.TextStyle.caption).monospacedDigit()
            }
            .foregroundStyle(NookTheme.textSecondary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.pulls.stack.position", index, stack.count))
    }

    /// "Merge #1, #2 and #3 from the bottom up?" with its second click, or the progress while it runs.
    private var stackMergeBar: some View {
        let numbers = stackToMerge.map { "#\($0.number)" }.joined(separator: ", ")
        return HStack(spacing: NookTheme.Spacing.md) {
            if mergingStack {
                ProgressView().controlSize(.small)
                Text(tr("agents.pulls.stack.merging", numbers)).foregroundStyle(NookTheme.textSecondary)
            } else {
                PullRequestStateIcon(glyph: .merged)
                Text(tr("agents.pulls.stack.confirm", numbers)).foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NookTheme.Spacing.sm)
                SmallGhostButton(title: tr("button.cancel")) { confirmStackMerge = false }
                SmallPrimaryButton(title: tr("agents.pulls.stack.mergeConfirm")) { mergeStack() }
            }
        }
        .font(NookTheme.TextStyle.body)
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func mergeStack() {
        let targets = stackToMerge
        confirmStackMerge = false
        mergingStack = true
        model.paused = true
        Task {
            defer { model.paused = false }
            do {
                let merged = try await PullRequestQuickRunner.mergeStack(targets, accountID: accountID, app: app)
                ToastCenter.shared.success(tr("agents.pulls.stack.merged", merged))
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pulls.stack.failed"))
            }
            mergingStack = false
            await model.refresh(activity: true)
            await PullRequestStore.shared.refresh(force: true)
        }
    }

    /// The tab bar: the four tabs, and on the right what the open tab holds.
    private func tabs(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            NookTabBar<Tab>(items: [
                .init(value: Tab.summary, title: tr("agents.pr.tab.summary")),
                .init(value: Tab.guide, title: tr("agents.pr.tab.guide"), help: tr("agents.pr.guide.help")),
                .init(value: Tab.timeline, title: tr("agents.pr.tab.timelinePlain")),
                .init(value: Tab.code, title: tr("agents.pr.tab.code")),
            ], selected: tab, onSelect: { value in
                switchTo(value)
            }, segmented: true)
            .fixedSize()
            Spacer(minLength: 0)
            tabAccessory(detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func tabAccessory(_ detail: PullRequestDetail) -> some View {
        switch tab {
        case .summary:
            // The checks in one line; a click unfolds them.
            Button {
                withAnimation(NookTheme.reveal) { checksOpen = true }
            } label: {
                checksSummary(detail)
            }
            .buttonStyle(.plain)
            .help(tr("agents.pr.status.checks"))
        case .timeline:
            HStack(spacing: NookTheme.Spacing.md) {
                if detail.activityLoaded {
                    let approvals = detail.verdicts.filter(\.approved).count
                    Label("\(PullRequestConversation.commentCount(PullRequestConversation.items(detail.events)))", systemImage: "bubble.left")
                        .help(tr("agents.pr.count.comments"))
                    Label("\(detail.commits.count)", systemImage: "circle.and.line.horizontal")
                        .help(tr("agents.pr.count.commits"))
                    if approvals > 0 {
                        Label("\(approvals)", systemImage: PullRequestIcon.symbol(PullRequestIcon.Review.approved))
                            .foregroundStyle(PullRequestIcon.tint(PullRequestIcon.Review.approved))
                            .help(tr("agents.pr.count.approvals"))
                    }
                }
                orderButton(newestFirst: $newestFirst)
            }
            .monospacedDigit()
        case .code:
            if detail.activityLoaded, !detail.files.isEmpty {
                let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
                let viewedCount = viewed.viewedCount(detail.files, in: key)
                Text(tr("agents.pr.files.viewedCount", viewedCount, detail.files.count))
                    .monospacedDigit()
                    .foregroundStyle(viewedCount == detail.files.count ? NookTheme.mint : NookTheme.textTertiary)
            }
        case .guide:
            EmptyView()
        }
    }

    /// "Newest first" or "Oldest first", a click turns it round.
    private func orderButton(newestFirst: Binding<Bool>) -> some View {
        Button {
            newestFirst.wrappedValue.toggle()
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                Image(systemName: "arrow.up.arrow.down")
                Text(tr(newestFirst.wrappedValue ? "agents.pr.timeline.newest" : "agents.pr.timeline.oldest"))
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(_ detail: PullRequestDetail, now: Date) -> some View {
        switch tab {
        case .summary:
            page { summary(detail, now: now) }
        case .guide:
            if detail.activityLoaded {
                page { reviewGuide(detail) }
            } else {
                activityLoading
            }
        case .timeline:
            if detail.activityLoaded {
                // One centered column at most 768 pt wide.
                page { timeline(detail, now: now).frame(maxWidth: 768).frame(maxWidth: .infinity) }
            } else {
                activityLoading
            }
        case .code:
            if !detail.activityLoaded {
                activityLoading
            } else if let path = openFile, let file = detail.files.first(where: { $0.path == path }) {
                fileDiff(file, detail: detail).padding(.top, NookTheme.Spacing.md)
            } else {
                page { files(detail) }
            }
        }
    }

    // MARK: Review guide

    /// A tour of the pull request in reading order: what each part changes, the files with a
    /// note (a click opens the file's diff), what to look at closely, and the questions only a maintainer can answer.
    @ViewBuilder
    private func reviewGuide(_ detail: PullRequestDetail) -> some View {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if writingGuide {
                HStack(spacing: NookTheme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text(tr("agents.pr.guide.writing")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                }
                .padding(NookTheme.Spacing.lg)
            } else if let guide {
                if !guide.isCurrent(for: detail.headSHA) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(NookTheme.amber)
                        Text(tr("agents.pr.guide.stale")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                        Spacer(minLength: 6)
                        NookGhostButton(title: tr("agents.pr.guide.rewrite"), compact: true) { writeGuide(detail, key: key) }
                    }
                    .padding(NookTheme.Spacing.md)
                    .panelCard()
                }
                ForEach(Array(guide.stops.enumerated()), id: \.offset) { index, stop in
                    guideStop(index + 1, stop)
                }
                HStack {
                    Text(tr("agents.pr.guide.written", NookDates.ago(guide.written)))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                    Spacer()
                    if guide.isCurrent(for: detail.headSHA) {
                        SmallGhostButton(title: tr("agents.pr.guide.rewrite")) { writeGuide(detail, key: key) }
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    Text(tr("agents.pr.guide.intro")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if guideFailed {
                        Text(tr("agents.pr.guide.failed")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coral)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    NookPrimaryButton(title: tr("agents.pr.guide.write"), symbol: "map") { writeGuide(detail, key: key) }
                        .fixedSize()
                }
                .padding(NookTheme.Spacing.lg)
                .panelCard()
            }
        }
        .onAppear { if guide == nil { guide = PullRequestReviewGuides.load(key) } }
    }

    private func guideStop(_ number: Int, _ stop: PullRequestReviewGuide.Stop) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Text("\(number)").font(NookTheme.mono(11, .semibold)).foregroundStyle(NookTheme.textTertiary)
                Text(stop.title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Spacer(minLength: 6)
                switch stop.attention {
                case .close:
                    Label(tr("agents.pr.guide.close"), systemImage: "eye")
                        .font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.amber)
                case .skim:
                    Text(tr("agents.pr.guide.skim")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                case .normal:
                    EmptyView()
                }
            }
            if !stop.summary.isEmpty {
                Text(stop.summary).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(stop.files, id: \.path) { file in
                    HoverRow(action: {
                        withAnimation(NookTheme.swap) { tab = .code }
                        openFile = file.path
                    }) {
                        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                            filePath(file.path)
                            if !file.note.isEmpty {
                                Text(file.note).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            ForEach(stop.questions, id: \.self) { question in
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Image(systemName: "questionmark.circle").foregroundStyle(NookTheme.amber)
                    Text(question).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    private func writeGuide(_ detail: PullRequestDetail, key: String) {
        guard !writingGuide else { return }
        writingGuide = true
        guideFailed = false
        Task {
            let written = await app.workspace.writeReviewGuide(detail)
            if let written {
                PullRequestReviewGuides.save(written, for: key)
                guide = written
            } else {
                guideFailed = true
            }
            writingGuide = false
        }
    }

    /// A tab's content, scrolling under the top. Scrolled well past the title (and with enough below to keep it
    /// scrolled), the top folds; back at the start it unfolds.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, NookTheme.Spacing.md)
                // Room for the round write button over the end of the page.
                .padding(.bottom, NookTheme.Spacing.xxxl + NookTheme.Spacing.xxl)
        }
        .frame(maxHeight: .infinity)
        .onScrollGeometryChange(for: PageScroll.self) { geometry in
            PageScroll(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                       overflow: geometry.contentSize.height - geometry.containerSize.height)
        } action: { _, scroll in
            if condensed {
                if scroll.offset < 4 { condensed = false }
            } else if scroll.offset > 72 && scroll.overflow > 200 {
                condensed = true
            }
        }
    }

    /// The summary is in, the timeline, commits and files are still on their way.
    private var activityLoading: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(tr("agents.pr.loadingActivity")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            }
            ForEach(0..<4, id: \.self) { _ in GhostRow() }
            Spacer(minLength: 0)
        }
        .padding(.top, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Summary

    /// The Summary: who reviews and which labels, then the description, the checks and the comments, each a section
    /// that folds under its heading.
    private func summary(_ detail: PullRequestDetail, now: Date) -> some View {
        let conversation = PullRequestConversation.items(detail.events)
        let total = PullRequestConversation.commentCount(conversation)
        let hidden = total - PullRequestConversation.commentCount(
            PullRequestConversation.filtered(conversation, bots: showBotComments, finished: showFinishedComments))
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if let readiness = PullRequestReadiness(detail) { readinessCard(readiness, detail: detail) }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                metaRow(symbol: "person.2", title: tr("agents.pr.status.reviewers")) { reviewers(detail) }
                if !detail.labels.isEmpty {
                    metaRow(symbol: "tag", title: tr("agents.pr.status.labels")) {
                        ChipFlow(spacing: NookTheme.Spacing.xs) {
                            ForEach(detail.labels, id: \.self) { label in
                                LabelChip(name: label, color: detail.labelColors[label])
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xs)

            SummarySection(title: tr("agents.pr.tab.description"), open: $descriptionOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    if detail.body.isEmpty {
                        Text(tr("agents.pr.noDescription")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textTertiary)
                    } else {
                        MarkdownView(text: detail.body, size: 13.5)
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SummarySection(title: tr("agents.pr.status.checks"), open: $checksOpen) {
                checks(detail)
            } accessory: {
                checksSummary(detail).font(NookTheme.TextStyle.detail)
            }

            SummarySection(title: tr("agents.pr.comments", detail.activityLoaded ? total : (detail.commentCount ?? 0)),
                           open: $commentsOpen) {
                if !detail.activityLoaded {
                    ForEach(0..<2, id: \.self) { _ in GhostRow() }
                } else {
                    PullRequestConversationList(detail: detail, now: now, newestFirst: commentsNewestFirst,
                                                showBots: showBotComments, showFinished: showFinishedComments)
                }
            } accessory: {
                HStack(spacing: NookTheme.Spacing.md) {
                    if detail.activityLoaded, total > 0 {
                        PullRequestConversationFilter(showBots: $showBotComments, showFinished: $showFinishedComments,
                                                      hidden: hidden)
                    }
                    orderButton(newestFirst: $commentsNewestFirst)
                }
            }
        }
    }

    // MARK: Readiness

    /// Where the pull request stands, first thing on the Summary: the verdict ("Ready to merge", "Not ready yet", "Needs
    /// changes"), then one line per thing GitHub weighs, each with its mark in the state's color. A line with something
    /// to look at or do takes you there: the checks unfold, the reviews open the timeline, a branch behind updates.
    private func readinessCard(_ readiness: PullRequestReadiness, detail: PullRequestDetail) -> some View {
        let verdict: (symbol: String, color: Color, title: String) = switch readiness.verdict {
        case .ready: ("checkmark.circle.fill", NookTheme.mint, tr("agents.pr.ready.verdict.ready"))
        case .waiting: ("clock.fill", NookTheme.amber, tr("agents.pr.ready.verdict.waiting"))
        case .blocked: ("exclamationmark.circle.fill", NookTheme.coral, tr("agents.pr.ready.verdict.blocked"))
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: verdict.symbol).font(NookTheme.font(14, .semibold)).foregroundStyle(verdict.color)
                Text(verdict.title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            NookDivider()
            ForEach(Array(readiness.items.enumerated()), id: \.offset) { _, item in
                readinessRow(item, detail: detail)
            }
        }
        .padding(.bottom, NookTheme.Spacing.xs)
        .panelCard()
    }

    @ViewBuilder
    private func readinessRow(_ item: PullRequestReadiness.Item, detail: PullRequestDetail) -> some View {
        let line = HStack(spacing: NookTheme.Spacing.md) {
            readinessMark(item.tone).frame(width: 16)
            Text(readinessText(item))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(item.tone == .neutral ? NookTheme.textSecondary : NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NookTheme.Spacing.sm)
            if let hint = readinessHint(item) {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Text(hint)
                    Image(systemName: "chevron.right").font(NookTheme.font(8.5, .bold))
                }
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
            }
        }
        if let action = readinessAction(item, detail: detail) {
            HoverRow(action: action) { line }
        } else {
            line
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
        }
    }

    private func readinessMark(_ tone: PullRequestReadiness.Tone) -> some View {
        let look: (symbol: String, color: Color) = switch tone {
        case .good: ("checkmark", NookTheme.mint)
        case .waiting: ("circle.dotted", NookTheme.amber)
        case .blocking: ("xmark", NookTheme.coral)
        case .neutral: ("minus", NookTheme.textTertiary)
        }
        return Image(systemName: look.symbol).font(NookTheme.font(11, .bold)).foregroundStyle(look.color)
    }

    private func readinessText(_ item: PullRequestReadiness.Item) -> String {
        let names: ([String]) -> String = { $0.map { "@" + $0 }.joined(separator: ", ") }
        return switch item {
        case .draft: tr("agents.pr.ready.draft")
        case .conflicts(let base): tr("agents.pr.ready.conflicts", base)
        case .noConflicts(let base): tr("agents.pr.ready.noConflicts", base)
        case .behind(let base): tr("agents.pr.ready.behind", base)
        case .checksFailing(let failing, let total): tr("agents.pr.ready.checksFailing", failing, total)
        case .checksRunning(let running, let total): tr("agents.pr.ready.checksRunning", running, total)
        case .checksPassed(let total): tr("agents.pr.ready.checksPassed", total)
        case .noChecks: tr("agents.pr.ready.noChecks")
        case .changesRequested(let by): tr("agents.pr.ready.changesRequested", names(by))
        case .approved(let by): tr("agents.pr.ready.approved", names(by))
        case .reviewRequested(let from): tr("agents.pr.ready.reviewRequested", names(from))
        case .noReviews: tr("agents.pr.ready.noReviews")
        }
    }

    /// The few words at the end of a line you can click: what the click does.
    private func readinessHint(_ item: PullRequestReadiness.Item) -> String? {
        switch item {
        case .checksFailing, .checksRunning: tr("agents.pr.ready.showChecks")
        case .changesRequested: tr("agents.pr.ready.showReviews")
        case .behind: tr("agents.pr.action.updateBranch")
        default: nil
        }
    }

    private func readinessAction(_ item: PullRequestReadiness.Item, detail: PullRequestDetail) -> (() -> Void)? {
        switch item {
        case .checksFailing, .checksRunning:
            return { withAnimation(NookTheme.reveal) { checksOpen = true } }
        case .changesRequested:
            return { switchTo(.timeline) }
        case .behind where detail.canPush != false:
            return {
                actions.close()
                actions.pending = .updateBranch(headSHA: detail.headSHA)
            }
        default:
            return nil
        }
    }

    /// One line of the Summary's top: a name in a narrow column on the left, its value on the right.
    private func metaRow<Value: View>(symbol: String, title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Label(title, systemImage: symbol)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 96, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The reviewers' pictures, ringed by what they said (mint approved, amber changes requested, grey still asked).
    @ViewBuilder
    private func reviewers(_ detail: PullRequestDetail) -> some View {
        let verdicts = detail.verdicts
        let waiting = detail.requestedReviewers.filter { login in !verdicts.contains { $0.author == login } }
        if verdicts.isEmpty && waiting.isEmpty {
            if detail.activityLoaded {
                Text(tr("agents.pr.reviews.none")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            } else {
                ProgressView().controlSize(.mini)
            }
        } else {
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(verdicts, id: \.author) { verdict in
                    reviewer(verdict.author, ring: PullRequestIcon.tint(verdict.approved ? PullRequestIcon.Review.approved : .changesRequested),
                             help: tr(verdict.approved ? "agents.pr.reviews.approved" : "agents.pr.reviews.changes", "@" + verdict.author))
                }
                ForEach(waiting, id: \.self) { login in
                    reviewer(login, ring: NookTheme.line2, help: tr("agents.pr.reviews.waiting", "@" + login))
                }
            }
        }
    }

    private func reviewer(_ login: String, ring: Color, help: String) -> some View {
        GitHubAvatar(login: login, size: 20)
            .padding(2)
            .overlay(Circle().strokeBorder(ring, lineWidth: 1.5))
            .help(help)
    }

    private func switchTo(_ value: Tab) {
        withAnimation(NookTheme.swap) { tab = value }
        openFile = nil
        condensed = false
    }

    @ViewBuilder
    private func checksSummary(_ detail: PullRequestDetail) -> some View {
        let counts = detail.checkCounts
        if detail.checks.isEmpty {
            Text(tr("agents.pr.checks.none")).foregroundStyle(NookTheme.textTertiary)
        } else {
            HStack(spacing: NookTheme.Spacing.sm) {
                if counts.failing > 0 { countLabel(.failing, tr("agents.pr.checks.failing", counts.failing)) }
                if counts.pending > 0 { countLabel(.pending, tr("agents.pr.checks.running", counts.pending)) }
                if counts.passing > 0 { countLabel(.passing, tr("agents.pr.checks.passed", counts.passing)) }
                if counts.skipped > 0, counts.failing + counts.pending == 0 {
                    countLabel(.skipped, tr("agents.pr.checks.skipped", counts.skipped))
                }
            }
        }
    }

    private func countLabel(_ outcome: PullRequestCheck.Outcome, _ text: String) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            CheckOutcomeGlyph(outcome: outcome)
            Text(text).foregroundStyle(outcome == .failing ? NookTheme.paper : NookTheme.textSecondary)
        }
    }

    // MARK: Timeline

    /// The history as one rail, oldest first: who did what, with conversations as cards and commits in runs.
    private func timeline(_ detail: PullRequestDetail, now: Date) -> some View {
        let oldestFirst = PullRequestTimelineEntry.entries(detail.events)
        let entries = newestFirst ? Array(oldestFirst.reversed()) : oldestFirst
        return VStack(alignment: .leading, spacing: 0) {
            if let created = detail.created, !newestFirst {
                TimelineRail(last: entries.isEmpty) {
                    TimelineMarker(symbol: PullRequestIcon.symbol(.open), color: PullRequestIcon.tint(.open))
                } content: {
                    activityLine(author: detail.author, sentence: tr("agents.pr.timeline.opened"), date: created, now: now)
                }
            }
            if entries.isEmpty {
                ListEmptyNote(tr("agents.pr.conversation.none"))
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    timelineEntry(entry, detail: detail, now: now,
                                  last: index == entries.count - 1 && !(newestFirst && detail.created != nil))
                }
            }
            if newestFirst, let created = detail.created {
                TimelineRail(last: true) {
                    TimelineMarker(symbol: PullRequestIcon.symbol(.open), color: PullRequestIcon.tint(.open))
                } content: {
                    activityLine(author: detail.author, sentence: tr("agents.pr.timeline.opened"), date: created, now: now)
                }
            }
        }
    }

    @ViewBuilder
    private func timelineEntry(_ entry: PullRequestTimelineEntry, detail: PullRequestDetail, now: Date, last: Bool) -> some View {
        switch entry {
        case .commits(let run):
            // Each commit its own entry with its author's picture, as on timeline.
            ForEach(Array(run.enumerated()), id: \.element.id) { index, event in
                TimelineRail(last: last && index == run.count - 1) {
                    GitHubAvatar(login: event.author, size: 28)
                } content: {
                    commitEntry(event, detail: detail, now: now)
                }
            }
        case .event(let event):
            switch event.kind {
            case .activity(let type, let subject):
                let look = activityLook(type)
                TimelineRail(last: last) {
                    TimelineMarker(symbol: look.symbol, color: look.color)
                } content: {
                    activityLine(author: event.author,
                                 sentence: tr("agents.pr.timeline." + type.replacingOccurrences(of: "-", with: "_"), subject),
                                 date: event.date, now: now)
                }
            default:
                TimelineRail(last: last) {
                    GitHubAvatar(login: event.author, size: 28)
                } content: {
                    PullRequestCommentCard(event: event, now: now, showsAvatar: false)
                }
            }
        }
    }

    /// "ada labeled bug", the time under it writes an event.
    private func activityLine(author: String, sentence: String, date: Date?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            (Text(author + " ").font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.paper)
                + Text(sentence).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let date { timeLabel(date, now: now) }
        }
        .padding(.vertical, NookTheme.Spacing.sm)
    }

    /// A commit: its message in bold, its short hash and when under it; a click opens it on GitHub.
    @ViewBuilder
    private func commitEntry(_ event: PullRequestEvent, detail: PullRequestDetail, now: Date) -> some View {
        if case .commit(let sha) = event.kind {
            CommitEntry(sha: sha, message: event.body, time: event.date.map { AgentFormat.short(now.timeIntervalSince($0)) },
                        date: event.date) { openCommit(sha, detail: detail) }
        }
    }

    private func openCommit(_ sha: String, detail: PullRequestDetail) {
        if let url = detail.url?.appendingPathComponent("commits/" + sha) { NSWorkspace.shared.open(url) }
    }

    private func timeLabel(_ date: Date, now: Date) -> some View {
        Text(AgentFormat.short(now.timeIntervalSince(date)))
            .font(NookTheme.font(11))
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }

    private func activityLook(_ type: String) -> (symbol: String, color: Color) {
        switch type {
        case "labeled", "unlabeled": return ("tag", NookTheme.textTertiary)
        case "assigned", "unassigned": return ("person", NookTheme.textTertiary)
        case "review_requested", "review_request_removed":
            return (PullRequestIcon.symbol(PullRequestIcon.Review.required), PullRequestIcon.tint(PullRequestIcon.Review.required))
        // An event shows the mark of the state it leads to.
        case "ready_for_review", "reopened": return (PullRequestIcon.symbol(.open), PullRequestIcon.tint(.open))
        case "renamed": return ("pencil", NookTheme.textTertiary)
        case "convert_to_draft": return (PullRequestIcon.symbol(.draft), PullRequestIcon.tint(.draft))
        case "head_ref_force_pushed": return ("arrow.up.circle", NookTheme.amber)
        case "head_ref_deleted", "head_ref_restored", "base_ref_changed": return ("arrow.triangle.branch", NookTheme.textTertiary)
        case "merged": return (PullRequestIcon.symbol(.merged), PullRequestIcon.tint(.merged))
        case "closed": return (PullRequestIcon.symbol(.closed), PullRequestIcon.tint(.closed))
        case "cross-referenced", "referenced": return ("link", NookTheme.textTertiary)
        case "milestoned", "demilestoned": return ("flag", NookTheme.textTertiary)
        case "auto_merge_enabled", "auto_merge_disabled": return ("bolt", NookTheme.textTertiary)
        case "review_dismissed":
            return (PullRequestIcon.symbol(PullRequestIcon.Review.dismissed), PullRequestIcon.tint(PullRequestIcon.Review.dismissed))
        default: return ("circle", NookTheme.textTertiary)
        }
    }

    // MARK: Checks

    /// The checks as one plain list them: failing first, then running, then passed or skipped.
    private func checks(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail.checks.isEmpty {
                ListEmptyNote(tr("agents.pr.checks.none"))
            } else {
                // The ones that need you first: failing, then running, then passed, skipped last.
                ForEach(Array(sortedChecks(detail.checks).enumerated()), id: \.offset) { _, check in checkRow(check) }
            }
        }
    }

    private func sortedChecks(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        let rank: [PullRequestCheck.Outcome: Int] = [.failing: 0, .pending: 1, .passing: 2, .skipped: 3]
        return checks.enumerated()
            .sorted { (rank[$0.element.outcome] ?? 4, $0.offset) < (rank[$1.element.outcome] ?? 4, $1.offset) }
            .map(\.element)
    }

    private func checkRow(_ check: PullRequestCheck) -> some View {
        HoverRow(action: { if let url = check.url { NSWorkspace.shared.open(url) } }) {
            HStack(spacing: NookTheme.Spacing.md) {
                CheckOutcomeGlyph(outcome: check.outcome).frame(width: 16)
                Text(check.name).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
                Spacer(minLength: 4)
                Text(check.detail.replacingOccurrences(of: "_", with: " "))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                if check.url != nil {
                    Image(systemName: "arrow.up.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
                }
            }
        }
        .disabled(check.url == nil)
    }

    // MARK: Files

    private func files(_ detail: PullRequestDetail) -> some View {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if detail.files.isEmpty {
                ListEmptyNote(tr("agents.pr.files.none"))
            } else {
                // How many are viewed shows in the tab bar.
                VStack(spacing: 0) {
                    ForEach(Array(orderedFiles(detail).enumerated()), id: \.element.id) { index, file in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 14 + NookTheme.Spacing.md) }
                        let status = viewed.status(file, in: key)
                        let seen = status == .viewed
                        HStack(spacing: 0) {
                            viewedButton(file, key: key, seen: seen)
                                .padding(.leading, NookTheme.Spacing.sm)
                            HoverRow(action: { openFile = file.path }) {
                                HStack(spacing: NookTheme.Spacing.md) {
                                    fileGlyph(file.status)
                                    filePath(file.path)
                                    if status == .changed {
                                        Text(tr("agents.pr.files.changedSince"))
                                            .font(NookTheme.TextStyle.caption)
                                            .foregroundStyle(NookTheme.amber)
                                    } else if PullRequestFileOrder.kind(file.path) == .generated {
                                        Text(tr("agents.pr.files.generated"))
                                            .font(NookTheme.TextStyle.caption)
                                            .foregroundStyle(NookTheme.textTertiary)
                                    }
                                    Spacer(minLength: 6)
                                    Text("+\(file.additions)").foregroundStyle(NookTheme.mint)
                                    Text("−\(file.deletions)").foregroundStyle(NookTheme.coral)
                                    DiffStatBar(additions: file.additions, deletions: file.deletions)
                                }
                                .font(NookTheme.TextStyle.detail.monospacedDigit())
                            }
                            .opacity(seen ? 0.55 : 1)
                        }
                    }
                }
                .panelCard()
            }
        }
    }

    /// The files in reading order: each source file with its tests, then documentation, then generated files.
    private func orderedFiles(_ detail: PullRequestDetail) -> [PullRequestFile] {
        let byPath = Dictionary(detail.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return PullRequestFileOrder.ordered(detail.files.map(\.path)).compactMap { byPath[$0] }
    }

    /// Ticks a file as viewed (or not), as on GitHub. The mark holds the file's revision, so a push that changes the file
    /// clears it again.
    private func viewedButton(_ file: PullRequestFile, key: String, seen: Bool) -> some View {
        ToolbarIconButton(seen ? "checkmark.circle.fill" : "circle", tr(seen ? "agents.pr.files.unmarkViewed" : "agents.pr.files.markViewed")) {
            viewed.setViewed(!seen, file: file, in: key)
            viewed.save()
        }
        .help(tr(seen ? "agents.pr.files.unmarkViewed" : "agents.pr.files.markViewed"))
    }

    /// The file's name in full brightness, the folder it is in dimmed before it.
    private func filePath(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let folder = String(path.dropLast(name.count))
        return (Text(folder).foregroundStyle(NookTheme.textTertiary) + Text(name).foregroundStyle(NookTheme.paper))
            .font(NookTheme.TextStyle.code)
            .lineLimit(1)
            .truncationMode(.head)
            .help(path)
    }

    private func fileGlyph(_ status: String) -> some View {
        let letter: String
        let color: Color
        switch status {
        case "added": letter = "A"; color = NookTheme.mint
        case "removed": letter = "D"; color = NookTheme.coral
        case "renamed", "copied": letter = "R"; color = NookTheme.violet
        default: letter = "M"; color = NookTheme.amber
        }
        return Text(letter).font(NookTheme.mono(11, .semibold)).foregroundStyle(color).frame(width: 14)
    }

    private func fileDiff(_ file: PullRequestFile, detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24) { openFile = nil }
                fileGlyph(file.status)
                VStack(alignment: .leading, spacing: 1) {
                    filePath(file.path)
                    if let previous = file.previousPath {
                        Text(previous + " →").font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 6)
                Text("+\(file.additions)").font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.mint)
                Text("−\(file.deletions)").font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coral)
                viewedButton(file, key: PullRequestViewedFiles.key(repo: detail.repo, number: detail.number),
                             seen: viewed.isViewed(file, in: PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)))
                let ordered = orderedFiles(detail)
                if let index = ordered.firstIndex(of: file) {
                    Text("\(index + 1)/\(ordered.count)")
                        .font(NookTheme.TextStyle.detail.monospacedDigit())
                        .foregroundStyle(NookTheme.textTertiary)
                    NookIconButton(systemName: "chevron.up", label: tr("agents.pr.files.previous"), size: 24) {
                        openFile = ordered[index - 1].path
                    }
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.35 : 1)
                    NookIconButton(systemName: "chevron.down", label: tr("agents.pr.files.next"), size: 24) {
                        openFile = ordered[index + 1].path
                    }
                    .disabled(index + 1 >= ordered.count)
                    .opacity(index + 1 >= ordered.count ? 0.35 : 1)
                }
            }
            if let patch = file.patch, !patch.isEmpty {
                DiffText(text: patch)
                    .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous))
                    .id(file.path)
            } else {
                WSEmptyState(symbol: "doc.text.magnifyingglass", title: tr("agents.pr.files.noDiff"), message: tr("agents.pr.files.noDiffDetail"))
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Merging

    /// The page's main action at the top right, as on: merge an open pull request, mark a draft ready, or say
    /// what it is (merged, closed, in conflict) when there is nothing to do.
    @ViewBuilder
    private func primaryAction(_ detail: PullRequestDetail) -> some View {
        switch detail.state {
        case .merged, .closed:
            PullRequestStateBadge(glyph: glyph)
        case .draft:
            if !detail.nodeID.isEmpty, detail.canPush != false {
                SmallPrimaryButton(title: tr("agents.pr.action.ready"), systemName: PullRequestIcon.symbol(.open)) {
                    actions.close()
                    actions.pending = .markReady(nodeID: detail.nodeID)
                }
                .disabled(actions.sending)
            } else {
                PullRequestStateBadge(glyph: .draft)
            }
        case .open:
            if detail.conflicted {
                PullRequestStateBadge(glyph: .conflict).help(tr("agents.pr.note.conflict"))
            } else if detail.canPush != false && !detail.methods.isEmpty {
                mergeButton(detail)
            }
        }
    }

    /// Merge with its method beside it. The first click arms it, the second merges; beside it, what GitHub may still hold
    /// it back on (branch protection, a branch that is behind, failing checks), named in a few words.
    private func mergeButton(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if let note = detail.mergeNote, detail.canMerge {
                mergeBlocker(note, detail: detail)
            }
            if merging { ProgressView().controlSize(.small) }
            SmallPrimaryButton(title: merging ? tr("agents.pr.merging") : armedMerge ? tr("agents.pr.confirmMerge") : tr("agents.pr.merge"),
                               systemName: armedMerge ? "checkmark" : PullRequestIcon.symbol(.merged)) {
                if armedMerge {
                    armedMerge = false
                    merge()
                } else {
                    armMerge()
                }
            }
            .disabled(!detail.canMerge || merging)
            .help(armedMerge ? confirmMessage : tr(method.titleKey))
            ComposerDropdown(width: 240) {
                Image(systemName: "chevron.down")
                    .font(NookTheme.font(9, .bold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            } content: {
                DropdownHeader(title: tr("agents.pr.mergeMethod.title"))
                ForEach(detail.methods) { option in
                    DropdownRow(title: tr(option.titleKey), chosen: option == method) {
                        methodRaw = option.rawValue
                    }
                }
            }
            .disabled(merging)
            .help(tr("agents.pr.mergeMethod.title"))
        }
    }

    /// What may still hold the merge back, in its own mark and a few words ("Branch protection", "Behind main",
    /// "Checks failing"); a click shows GitHub's whole reason, and for a branch that is behind the button that updates it.
    private func mergeBlocker(_ note: String, detail: PullRequestDetail) -> some View {
        let reason = String(note.split(separator: ".").last ?? "")
        let look: (symbol: String, color: Color, label: String) = switch reason {
        case "blocked": (PullRequestIcon.blocked, PullRequestIcon.blockerTint, tr("agents.pr.blocker.blocked"))
        case "behind": (PullRequestIcon.behind, PullRequestIcon.blockerTint, tr("agents.pr.blocker.behind", detail.baseBranch))
        case "unstable": (PullRequestIcon.symbol(PullRequestCheck.Outcome.failing), PullRequestIcon.tint(PullRequestCheck.Outcome.failing),
                          tr("agents.pr.blocker.unstable"))
        case "checking": (PullRequestIcon.symbol(PullRequestCheck.Outcome.pending), PullRequestIcon.tint(PullRequestCheck.Outcome.pending),
                          tr("agents.pr.blocker.checking"))
        default: ("info.circle", NookTheme.textTertiary, tr(note))
        }
        return Button {
            showBlocker.toggle()
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                Image(systemName: look.symbol).font(NookTheme.font(10, .semibold))
                Text(look.label).lineLimit(1)
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(look.color)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 22)
            .background(Capsule().fill(look.color.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tr(note))
        .accessibilityLabel(tr(note))
        .popover(isPresented: $showBlocker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(tr(note))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                if reason == "behind" {
                    SmallGhostButton(title: tr("agents.pr.action.updateBranch")) {
                        showBlocker = false
                        actions.close()
                        actions.pending = .updateBranch(headSHA: detail.headSHA)
                    }
                }
            }
            .padding(NookTheme.Spacing.lg)
            .frame(width: 280, alignment: .leading)
        }
    }

    private func armMerge() {
        let token = UUID()
        armToken = token
        withAnimation(NookTheme.hover) { armedMerge = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if armToken == token { withAnimation(NookTheme.hover) { armedMerge = false } }
        }
    }

    private var confirmMessage: String {
        var text = tr("agents.pr.confirmMessage", detail?.headBranch ?? "", tr(method.titleKey))
        if let detail, detail.checkSummary != .passing, !detail.checks.isEmpty { text += "\n" + tr("agents.pr.confirmChecks") }
        return text
    }

    /// Only after the confirmation: merges the head that is shown, and writes the outcome to the action log.
    private func merge() {
        guard let detail, detail.canMerge, !merging else { return }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            ToastCenter.shared.error(tr("agents.pr.noToken"))
            return
        }
        let method = self.method
        let args = "\(detail.id) · \(method.rawValue) · \(detail.headBranch) → \(detail.baseBranch)"
        merging = true
        model.paused = true
        Task {
            defer { model.paused = false }
            do {
                let sha = try await GitHubPullRequestDetail.merge(repo: detail.repo, number: detail.number, method: method,
                                                                  sha: detail.headSHA, token: token)
                app.store.audit(tool: "github_merge_pr", args: args, result: "merged" + (sha.isEmpty ? "" : " " + String(sha.prefix(7))))
                settle()
                await model.refresh(activity: true)
                await PullRequestStore.shared.refresh(force: true)
            } catch {
                app.store.audit(tool: "github_merge_pr", args: args, result: "error: " + error.localizedDescription)
                merging = false
                // The answer can get lost (a timeout) after GitHub merged after all: look before calling it failed.
                await model.refresh(activity: true)
                if model.detail?.state == .merged {
                    settle()
                    await PullRequestStore.shared.refresh(force: true)
                } else {
                    ToastCenter.shared.error(error, title: tr("agents.pr.mergeFailed"))
                }
            }
        }
    }

    /// Shows the merge at once, here, in the list and on the agent rows, without waiting for GitHub's next answers.
    private func settle() {
        merging = false
        model.markMerged()
        ToastCenter.shared.success(tr("agents.pr.state.merged"))
    }
}

/// A part of the Summary under a heading that folds it: the name and a chevron on the left,
/// what the part offers (a count, a filter, the order) on the right.
private struct SummarySection<Content: View, Accessory: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder let content: () -> Content
    @ViewBuilder var accessory: () -> Accessory

    init(title: String, open: Binding<Bool>, @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        _open = open
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Button {
                    withAnimation(NookTheme.reveal) { open.toggle() }
                } label: {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Text(title).font(NookTheme.TextStyle.label)
                        Image(systemName: "chevron.right")
                            .font(NookTheme.font(8.5, .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(NookTheme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(open ? tr("compose.queue.expanded") : "")
                Spacer(minLength: NookTheme.Spacing.sm)
                accessory().foregroundStyle(NookTheme.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.xs)
            if open { content() }
        }
    }
}

/// Where a tab's page is scrolled, and how much taller its content is than the room it has.
private struct PageScroll: Equatable {
    let offset: CGFloat
    let overflow: CGFloat
}

/// One entry on the timeline: its marker on a thin rail that runs down to the next entry, the entry beside it.
private struct TimelineRail<Marker: View, Content: View>: View {
    let last: Bool
    @ViewBuilder let marker: () -> Marker
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.xl + NookTheme.Spacing.xs) {
            marker().frame(width: 28, height: 28)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, NookTheme.Spacing.xl + NookTheme.Spacing.xs)
        .background(alignment: .topLeading) {
            if !last {
                NookDivider(vertical: true)
                    .padding(.leading, 13.5)
                    .padding(.top, 30)
            }
        }
    }
}

/// The round marker of an event on the timeline rail.
private struct TimelineMarker: View {
    let symbol: String
    let color: Color

    var body: some View {
        NookSymbol(symbol, size: 12)
            .font(NookTheme.font(10.5, .medium))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(Circle().fill(NookTheme.notch))
    }
}

/// One commit on the timeline: the message in bold (lit under the pointer), the short hash and when under it.
private struct CommitEntry: View {
    let sha: String
    let message: String
    let time: String?
    let date: Date?
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Text(message.isEmpty ? tr("agents.pr.timeline.pushedOne") : message)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(hovering ? NookTheme.iris : NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(String(sha.prefix(7))).font(NookTheme.mono(10.5))
                    if let time { Text(time).font(NookTheme.font(10.5)).monospacedDigit() }
                }
                .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.vertical, NookTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(date?.formatted(date: .abbreviated, time: .shortened) ?? "")
    }
}

/// Five small blocks, like GitHub's: green for the share of added lines, red for removed ones.
private struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = additions + deletions
        let green = total == 0 ? 0 : Int((Double(additions) / Double(total) * 5).rounded())
        let red = total == 0 ? 0 : 5 - green
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < green ? NookTheme.mint : index < green + red ? NookTheme.coral : NookTheme.line2)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A full-width row that lights up under the pointer.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? NookTheme.rowHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: Loading placeholders

/// A grey bar where text will be.
private struct GhostBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
            .fill(NookTheme.rowHover)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// A row-shaped placeholder: a dot and two lines.
private struct GhostRow: View {
    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Circle().fill(NookTheme.rowHover).frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                GhostBar(height: 9)
                GhostBar(width: 120, height: 7)
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
    }
}

/// The page's shape while the first answer is on its way: the tabs, the overview card and the description.
private struct PullRequestDetailGhost: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ForEach(Array([80, 90, 80, 70, 64].enumerated()), id: \.offset) { _, width in
                    GhostBar(width: CGFloat(width), height: 22)
                }
            }
            VStack(spacing: 0) {
                GhostRow()
                GhostRow()
            }
            .panelCard()
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                GhostBar()
                GhostBar()
                GhostBar(width: 180)
            }
            .padding(NookTheme.Spacing.lg)
            .panelCard()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("agents.pr.loading"))
    }
}
