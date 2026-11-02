import AppKit
import SwiftUI

/// One pull request, read in full inside Nook, laid out. A fixed top with the crumbs
/// (repository and the number in its state's color), the main action (merge, ready for review, or the state) and the ⋯
/// menu, then the title, author, branches and size, then the tabs; it folds to one line once you
/// scroll past the title. Under it four tabs: Summary (reviewers and labels, then the description, the checks and
/// the comments in sections that fold, the comments as threads them; see
/// PullRequestConversationList), Guide, Timeline (everything that happened, commits included) and Code (every
/// changed file with its diff). The bar under the tabs says what the open tab holds: the comments, commits and approvals
/// with the order on Timeline, the files viewed on Code (Summary leads with its readiness card instead). Merge asks for a second click and
/// uses the account it was listed under; the round button at the bottom right opens the composer.
///
/// The page opens at once: the top shows what the list already knew while GitHub is asked, the overview follows with
/// the first answer and the timeline, commits and files after it (see PullRequestDetailModel, which also keeps it
/// current while open).
struct PullRequestDetailView: View {
    @EnvironmentObject var app: AppModel
    let accountID: String
    let item: PullRequestItem
    /// Beside the pull request list (a side panel): the button that leaves it closes the panel, on the right. The
    /// Pull requests page puts that button on its tab line instead and passes no `onBack`.
    let inline: Bool
    /// Nil beside a session, where the side panel's tab closes it instead.
    let onBack: (() -> Void)?
    /// Beside the list with no other pull request open: the button that makes the side panel fill the page sits on the
    /// page's own top line, so there is no second line above it just for that. Nil leaves it out.
    let onMaximize: (() -> Void)?
    let maximized: Bool

    enum Tab: Hashable { case summary, guide, timeline, code }

    /// The widest the page reads: beside the list it takes the room it has, but filling a wide window its top, tabs and
    /// content stay one centered column, so lines stay readable and everything lines up under the title.
    static let pageWidth: CGFloat = PanelLayout.pageColumn

    @StateObject var model: PullRequestDetailModel
    @State var tab: Tab = .summary
    @State var openFile: String?
    /// The check whose steps and log the Summary shows in place of itself.
    @State var openCheck: PullRequestCheck?
    /// Files you marked as viewed; a mark lapses when a push changes the file.
    @State var viewed = PullRequestViewedFiles.load()
    /// The review guide written for this pull request, if any, and whether one is being written.
    @State var guide: PullRequestReviewGuide?
    @State var writingGuide = false
    @State var guideFailed = false
    @AppStorage("agents.pr.mergeMethod") var methodRaw = PullRequestMergeMethod.merge.rawValue
    /// The merge button's first click arms it ("Confirm merge?"), the second merges; it disarms by itself after a while.
    @State var armedMerge = false
    @State var armToken = UUID()
    @State var merging = false
    /// Scrolled past the title: the top folds to one line (number and title). Held without
    /// being observed (only the top watches it, see `headerBlock`): as state of this view, the fold built the open tab's
    /// whole page again in the middle of a scroll.
    @State var fold = PullRequestHeaderFold()
    var condensed: Bool {
        get { fold.condensed }
        nonmutating set { if fold.condensed != newValue { fold.condensed = newValue } }
    }
    /// The popover that says in full what may still hold the merge back.
    @State var showBlocker = false
    /// The popover under the Summary's Status line: everything GitHub weighs before a merge, one line each.
    @State var showReadiness = false
    /// The composer, the ⋯ menu's actions and their confirmation.
    @StateObject var actions = PullRequestActionState()
    /// The timeline newest first, when chosen.
    @AppStorage("agents.pr.timelineNewest") var newestFirst = false
    /// The Summary's sections that fold, open at first: the description and comments, the checks folded.
    @State var descriptionOpen = true
    @State var checksOpen = false
    /// A place on the open tab's page to scroll to, set by a click that points at it (the checks); a fresh request
    /// each time, so a second click scrolls back to it too.
    @State var scrollRequest: PullRequestPageScrollRequest?
    @State var commentsOpen = true
    @AppStorage("agents.pr.commentsNewest") var commentsNewestFirst = false
    /// Comments by bots (CI reports, coverage, previews), resolved threads and dismissed reviews are left out of the
    /// Summary until you ask for them in its filter.
    @AppStorage("agents.pr.showBotComments") var showBotComments = false
    @AppStorage("agents.pr.showFinishedComments") var showFinishedComments = false

    /// The stack this pull request is part of, bottom first (empty when it stands alone), and how to open another one of it.
    let stack: [PullRequestItem]
    let onOpenPullRequest: ((PullRequestItem) -> Void)?
    /// Merging the stack up to here waits for its second click, then runs.
    @State var confirmStackMerge = false
    @State var mergingStack = false

    /// Hands the row back as the page last read it (merged, closed, ready for review, in conflict), so the tab that
    /// holds it shows the same mark as the page.
    let onUpdate: ((PullRequestItem) -> Void)?

    init(accountID: String, item: PullRequestItem, inline: Bool = false, stack: [PullRequestItem] = [],
         onOpenPullRequest: ((PullRequestItem) -> Void)? = nil, onUpdate: ((PullRequestItem) -> Void)? = nil,
         onBack: (() -> Void)? = nil, onMaximize: (() -> Void)? = nil, maximized: Bool = false) {
        self.accountID = accountID
        self.item = item
        self.inline = inline
        self.stack = stack
        self.onOpenPullRequest = onOpenPullRequest
        self.onUpdate = onUpdate
        self.onBack = onBack
        self.onMaximize = onMaximize
        self.maximized = maximized
        _model = StateObject(wrappedValue: PullRequestDetailModel(accountID: accountID, item: item))
    }

    var detail: PullRequestDetail? { model.detail }

    var method: PullRequestMergeMethod {
        let chosen = PullRequestMergeMethod(rawValue: methodRaw) ?? .merge
        guard let detail, !detail.methods.contains(chosen) else { return chosen }
        return detail.methods.first ?? chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBlock.pullRequestPageColumn()
            if confirmStackMerge || mergingStack { stackMergeBar.padding(.top, NookTheme.Spacing.sm).pullRequestPageColumn() }
            if let detail {
                ZStack(alignment: .bottomTrailing) {
                    // The relative times in the timeline and the commits tick along, once a minute.
                    TimelineView(.nookTicks(every: 60)) { context in
                        content(detail, now: context.date)
                    }
                    // The new tab is simply there: in the spring that slides the tab bar's mark, the old and the new
                    // page were both laid out on every frame.
                    .transaction(value: tab) { $0.animation = nil }
                    // At the column's corner, not the window's; the empty rest of its frame lets clicks through.
                    if actions.panel != .write { writeButton(detail).pullRequestPageColumn(alignment: .trailing) }
                }
                .frame(maxHeight: .infinity)
                if actions.panel != .none || actions.pending != nil || actions.error != nil {
                    PullRequestActionPanel(state: actions, model: model, accountID: accountID, detail: detail)
                        .padding(.top, NookTheme.Spacing.sm)
                        .pullRequestPageColumn()
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
                .pullRequestPageColumn()
                Spacer(minLength: 0)
            } else {
                PullRequestDetailGhost().padding(.top, NookTheme.Spacing.lg).pullRequestPageColumn()
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await model.run() }
        // Back in Nook after a while elsewhere: look at once instead of at the next tick.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !merging { Task { await model.refresh() } }
        }
        // `initial`: a page that opens on a read kept from before (one read ahead under the pointer) already knows the
        // state, and the tab still shows the row's.
        .onChange(of: detail.map { "\($0.state.rawValue)|\($0.conflicted)" }, initial: true) { _, _ in
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
    /// The fold is not animated: its height changing on every frame of a spring laid the page under it out again on
    /// each one, in the middle of the scroll that set it off.
    var headerBlock: some View {
        Observing(fold) {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                if condensed {
                    condensedLine
                        .padding(.bottom, NookTheme.Spacing.sm)
                } else {
                    header
                        .padding(.top, NookTheme.Spacing.xs)
                        .padding(.bottom, NookTheme.Spacing.lg)
                }
                if let detail {
                    NookDivider()
                    tabs(detail).padding(.vertical, NookTheme.Spacing.sm)
                }
                NookDivider()
            }
        }
    }

    var topBar: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let onBack, !inline {
                ToolbarIconButton("arrow.left", tr("agents.pr.back"), onBack)
            }
            crumbs
            Spacer(minLength: NookTheme.Spacing.sm)
            if stack.count > 1 { stackMenu }
            if let detail {
                primaryAction(detail)
                // Refreshing is in the ⋯ menu, which spins while GitHub is asked. It alone
                // watches the reads, so a poll draws the menu again and not the page.
                Observing(model.status) {
                    PullRequestMoreMenu(state: actions, detail: detail, loading: model.loading, fetchedAt: model.fetchedAt) {
                        Task { await model.refresh(activity: true) }
                    }
                }
            } else {
                Observing(model.status) {
                    if model.loading { ProgressView().controlSize(.small) }
                }
            }
            if let onMaximize {
                ToolbarIconButton(maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                  tr(maximized ? "agents.pulls.panel.restore" : "agents.pulls.panel.maximize"), onMaximize)
            }
            if let onBack, inline {
                SidePanelCloseButton(help: tr("agents.pr.closePanel"), action: onBack)
            }
        }
        .frame(height: 32)
    }

    /// "acme/app #12↗", or "#12↗ Title" once folded. The number wears the state's color and opens it on GitHub.
    var crumbs: some View {
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

    var numberLink: some View {
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

    /// What the pull request is: shown from the list's row at once, and filled in when GitHub answers. The title (on two
    /// lines at most), who opened it and when it last changed, then the branches with the size on the right. Copying the
    /// checkout command is in the ⋯ menu, so the top keeps to what you read.
    var header: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(detail?.title ?? item.title)
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(detail?.title ?? item.title)
                .textSelection(.enabled)
            let author = detail?.author ?? item.author
            HStack(spacing: NookTheme.Spacing.sm) {
                if !author.isEmpty {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        GitHubAvatar(login: author, size: 16)
                        Text(author).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textStrong)
                    }
                    .help("@" + author)
                }
                if let updated = detail?.updated ?? item.updated {
                    if !author.isEmpty { Text("·").foregroundStyle(NookTheme.textMuted) }
                    Text(tr("agents.pr.updatedAgo", AgentFormat.short(Date().timeIntervalSince(updated))))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
            .help(detail?.created.map { tr("agents.pr.openedAgo", AgentFormat.short(Date().timeIntervalSince($0))) } ?? "")
            if let detail {
                branchLine(detail).padding(.top, NookTheme.Spacing.xxs)
            } else {
                PullRequestGhostBar(width: 260).padding(.top, NookTheme.Spacing.xxs)
            }
        }
    }

    /// The folded middle: the author and when, the branches, and the size, in one quiet line.
    var condensedLine: some View {
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

    /// The list's state until the page has loaded (so a known conflict shows at once), then the page's.
    var glyph: PullRequestBadge.Glyph {
        guard let detail else { return item.stateGlyph }
        return PullRequestBadge.Glyph(detail.state, conflicted: detail.conflicted)
    }

    /// "main ← feature" in mono (a click on the head copies it), and on the right how many files and lines changed. A
    /// branch that is behind is updated from the Summary's Status line (or the ⋯ menu), not from here.
    func branchLine(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Text(detail.baseBranch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.left").font(NookTheme.font(10, .medium)).foregroundStyle(NookTheme.textMuted.opacity(0.6))
                Button {
                    Pasteboard.copy(detail.headBranch)
                    ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
                } label: {
                    // A fork's branch carries its owner, as on GitHub: "ada:feature".
                    Text((detail.headOwner.map { $0 + ":" } ?? "") + detail.headBranch).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(tr("agents.pr.copyBranch"))
            }
            .font(NookTheme.mono(11.5))
            .foregroundStyle(NookTheme.textMuted)
            Spacer(minLength: NookTheme.Spacing.sm)
            diffStat(detail)
        }
    }

    /// How many files and the lines added and removed them; folded, the number of files alone.
    func diffStat(_ detail: PullRequestDetail, compact: Bool = false) -> some View {
        let files = max(detail.changedFiles, detail.files.count)
        return HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: "doc.text").font(NookTheme.font(compact ? 9.5 : 10.5))
                Text(compact ? "\(files)" : tr("agents.pr.filesCount", files))
            }
            .foregroundStyle(NookTheme.textTertiary)
            .help(tr("agents.pr.filesCount", files))
            if detail.additions > 0 || detail.deletions > 0 {
                PullRequestLineCounts(additions: detail.additions, deletions: detail.deletions,
                                      font: NookTheme.mono(compact ? 10.5 : 11.5, .medium))
            }
        }
        .font((compact ? NookTheme.font(10.5) : NookTheme.TextStyle.detail).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    /// The split button at the bottom right that opens the composer (a comment or a review): the bubble
    /// writes a comment, the chevron beside it starts straight as a comment, an approval or a request for changes.
    func writeButton(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 0) {
            Button {
                openWriter(detail, review: nil)
            } label: {
                Image(systemName: "bubble.left")
                    .font(NookTheme.font(14, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .frame(width: 40, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("agents.pr.write.open"))
            .accessibilityLabel(tr("agents.pr.write.open"))
            Rectangle().fill(NookTheme.line2).frame(width: 1, height: 18)
            ComposerDropdown(width: 220) {
                Image(systemName: "chevron.up")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 30, height: 38)
                    .contentShape(Rectangle())
            } content: {
                ForEach(PullRequestAction.Verdict.allCases, id: \.self) { verdict in
                    DropdownRow(symbol: PullRequestActionPanel.verdictSymbol(verdict),
                                title: tr(PullRequestActionPanel.verdictKey(verdict))) { openWriter(detail, review: verdict) }
                }
            }
            .help(tr("agents.pr.write.choose"))
            .accessibilityLabel(tr("agents.pr.write.choose"))
        }
        .background(Capsule().fill(NookTheme.smoke))
        .overlay(Capsule().strokeBorder(NookTheme.line2, lineWidth: 1))
        .shadow(color: NookTheme.notch.opacity(0.45), radius: 10, y: 4)
        .clipShape(Capsule())
        .disabled(actions.sending)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.bottom, NookTheme.Spacing.md)
    }

    /// Opens the composer as a plain comment (nil) or as a review with the verdict picked in the dropdown.
    func openWriter(_ detail: PullRequestDetail, review verdict: PullRequestAction.Verdict?) {
        withAnimation(NookTheme.swap) {
            actions.open(.write, detail: detail)
            if let verdict {
                actions.asReview = true
                actions.verdict = verdict
            } else {
                actions.asReview = false
            }
        }
    }

    /// The tab bar: the four tabs, and on the right what the open tab holds. Where the page is too narrow for both on
    /// one line (a side panel beside the list), what the tab holds moves to its own line under the tabs instead of
    /// being squeezed or cut off.
    func tabs(_ detail: PullRequestDetail) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NookTheme.Spacing.md) {
                tabBar
                Spacer(minLength: 0)
                tabAccessoryStyled(detail)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                tabBar
                tabAccessoryStyled(detail)
            }
        }
    }

    func tabAccessoryStyled(_ detail: PullRequestDetail) -> some View {
        tabAccessory(detail)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
            .fixedSize()
    }

    var tabBar: some View {
        NookTabBar<Tab>(items: [
                .init(value: Tab.summary, title: tr("agents.pr.tab.summary")),
                .init(value: Tab.guide, title: tr("agents.pr.tab.guide"), help: tr("agents.pr.guide.help")),
                .init(value: Tab.timeline, title: tr("agents.pr.tab.timelinePlain")),
                .init(value: Tab.code, title: tr("agents.pr.tab.code")),
            ], selected: tab, onSelect: { value in
                switchTo(value)
            }, segmented: true)
            .fixedSize()
    }

    @ViewBuilder
    func tabAccessory(_ detail: PullRequestDetail) -> some View {
        switch tab {
        case .summary:
            // Nothing here: the readiness card at the top of the page and the Checks heading already say how the checks
            // went, and a third copy in the bar only crowded it.
            EmptyView()
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
    func orderButton(newestFirst: Binding<Bool>) -> some View {
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
    func content(_ detail: PullRequestDetail, now: Date) -> some View {
        switch tab {
        case .summary:
            if let check = openCheck, let url = detail.url {
                // The check as last read: a running one turns failed or passed in place.
                CICheckLogView(pullRequest: url, check: detail.checks.first { $0.id == check.id } ?? check) {
                    openCheck = nil
                    // Back where the check was: the page is built again on this turn, so it can scroll on the next.
                    DispatchQueue.main.async { revealChecks() }
                }
                .padding(.top, NookTheme.Spacing.md)
                .pullRequestPageColumn()
                .id(check.id)
            } else {
                page { summary(detail, now: now) }
            }
        case .guide:
            if detail.activityLoaded {
                page { reviewGuide(detail) }
            } else {
                activityLoading
            }
        case .timeline:
            if detail.activityLoaded {
                // One centered column at most 768 pt wide.
                page { timeline(detail, now: now) }
            } else {
                activityLoading
            }
        case .code:
            if !detail.activityLoaded {
                activityLoading
            } else if let path = openFile, let file = detail.files.first(where: { $0.path == path }) {
                fileDiff(file, detail: detail).padding(.top, NookTheme.Spacing.md).pullRequestPageColumn()
            } else {
                page { files(detail) }
            }
        }
    }

    /// A tab's content, scrolling under the top. Scrolled well past the title (and with enough below to keep it
    /// scrolled), the top folds; back at the start it unfolds.
    /// A click that points somewhere on the page (see `scrollRequest`) scrolls there once the section has unfolded.
    func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Built here: `ScrollViewReader` holds on to its closure, so it can't call the non-escaping builder.
        let content = content()
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, NookTheme.Spacing.md)
                    // The column inside the scroll view, so the wheel scrolls beside it too.
                    .pullRequestPageColumn()
                    // Room for the round write button over the end of the page.
                    .padding(.bottom, NookTheme.Spacing.xxxl + NookTheme.Spacing.xxl)
            }
            .onChange(of: scrollRequest) { _, request in
                guard let request else { return }
                // On the next turn, so the section that just unfolded is laid out before the page moves to it.
                DispatchQueue.main.async {
                    withAnimation(NookTheme.reveal) { proxy.scrollTo(request.target, anchor: .top) }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onScrollGeometryChange(for: PullRequestPageScroll.self) { geometry in
            PullRequestPageScroll(offset: geometry.contentOffset.y + geometry.contentInsets.top,
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
    var activityLoading: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text(tr("agents.pr.loadingActivity")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            }
            ForEach(0..<4, id: \.self) { _ in PullRequestGhostRow() }
            Spacer(minLength: 0)
        }
        .padding(.top, NookTheme.Spacing.md)
        .frame(maxWidth: Self.pageWidth, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    func switchTo(_ value: Tab) {
        withAnimation(NookTheme.swap) { tab = value }
        // At once: the top unfolding over the new page made it lay out again on every frame of its spring.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            openFile = nil
            openCheck = nil
            condensed = false
        }
    }
}

/// Whether a pull request page's top is folded (`PullRequestDetailView.condensed`). Only the top observes it, so folding
/// it draws the top again and not the tab under it (as `SessionDraftState` in `AgentSessionDetail`).
@MainActor
final class PullRequestHeaderFold: ObservableObject {
    @Published var condensed = false
}
