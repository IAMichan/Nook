import AppKit
import SwiftUI

/// One pull request, read in full inside Nook. On top what it is (title, state,
/// author, branches, size), then four tabs: Summary (reviewers and labels, then the description, the checks and
/// the comments in sections that fold), Guide, Timeline (everything that happened, commits included) and Code (every
/// changed file with its diff). The bar under the tabs says what the open tab holds: the checks on Summary, the
/// comments, commits and approvals with the order on Timeline, the files viewed on Code. The bar at the bottom merges
/// it, after you confirm, with the account it was listed under.
///
/// The page opens at once: the top shows what the list already knew while GitHub is asked, the overview follows with
/// the first answer and the timeline, commits and files after it (see PullRequestDetailModel, which also keeps it
/// current while open).
struct PullRequestDetailView: View {
    @EnvironmentObject private var app: AppModel
    let accountID: String
    let item: PullRequestItem
    /// Beside the pull request list (a side panel): the button that leaves it closes the panel, on the right.
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
    @State private var confirmMerge = false
    @State private var merging = false
    @State private var mergeError: String?
    /// The composer, the ⋯ menu's actions and their confirmation.
    @StateObject private var actions = PullRequestActionState()
    /// The timeline newest first, when chosen.
    @AppStorage("agents.pr.timelineNewest") private var newestFirst = false
    /// The Summary's sections that fold, open at first: the description and comments, the checks folded.
    @State private var descriptionOpen = true
    @State private var checksOpen = false
    @State private var commentsOpen = true
    @AppStorage("agents.pr.commentsNewest") private var commentsNewestFirst = false
    /// Comments by bots (CI reports, coverage, previews) are left out of the Summary until you ask for them.
    @AppStorage("agents.pr.showBotComments") private var showBotComments = false

    init(accountID: String, item: PullRequestItem, inline: Bool = false, onBack: (() -> Void)? = nil) {
        self.accountID = accountID
        self.item = item
        self.inline = inline
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
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            topBar
            header
            if let detail {
                tabs(detail)
                // The relative times in the timeline and the commits tick along, once a minute.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    content(detail, now: context.date)
                }
                if actions.panel != .none || actions.pending != nil || actions.error != nil {
                    PullRequestActionPanel(state: actions, model: model, accountID: accountID, detail: detail)
                        .transition(.opacity)
                }
                mergeBar(detail)
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
                .padding(.top, NookTheme.Spacing.md)
                Spacer(minLength: 0)
            } else {
                PullRequestDetailGhost()
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) { await model.run() }
        // Back in Nook after a while elsewhere: look at once instead of at the next tick.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !merging { Task { await model.refresh() } }
        }
        .onChange(of: detail?.files.map(\.path) ?? []) { _, paths in
            if let path = openFile, detail?.activityLoaded == true, !paths.contains(path) { openFile = nil }
        }
    }

    // MARK: Header

    private var topBar: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if let onBack, !inline {
                NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 28, action: onBack)
                    .help(tr("agents.pr.back"))
            }
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(item.repo).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(NookTheme.font(8.5, .semibold)).foregroundStyle(NookTheme.textMuted)
                Text("#\(item.number)").foregroundStyle(NookTheme.textSecondary).monospacedDigit()
            }
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textTertiary)
            Spacer(minLength: NookTheme.Spacing.sm)
            if model.loading {
                ProgressView().controlSize(.small)
            } else if let read = model.fetchedAt {
                PullRequestFreshness(date: read)
            }
            NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) {
                Task { await model.refresh(activity: true) }
            }
            .help(tr("agents.pulls.refresh"))
            if let detail {
                PullRequestMoreMenu(state: actions, detail: detail)
            }
            if let url = detail?.url ?? item.url {
                NookIconButton(systemName: "link", label: tr("agents.pr.copyLink"), size: 28) {
                    Pasteboard.copy(url.absoluteString)
                    ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                }
                    .help(tr("agents.pr.copyLink"))
                NookIconButton(systemName: "arrow.up.right.square", label: tr("agents.pulls.open"), size: 28) { NSWorkspace.shared.open(url) }
                    .help(tr("agents.pulls.open"))
            }
            if let onBack, inline {
                NookIconButton(systemName: "sidebar.right", label: tr("agents.pr.closePanel"), size: 28, action: onBack)
                    .help(tr("agents.pr.closePanel"))
            }
        }
        .frame(height: 30)
    }

    /// What the pull request is: shown from the list's row at once, and filled in when GitHub answers.
    private var header: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(detail?.title ?? item.title)
                .font(NookTheme.TextStyle.title)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: NookTheme.Spacing.sm) {
                PullRequestStateBadge(glyph: glyph)
                let author = detail?.author ?? item.author
                if !author.isEmpty {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        GitHubAvatar(login: author, size: 16)
                        Text("@" + author).foregroundStyle(NookTheme.textSecondary)
                    }
                }
                if let created = detail?.created {
                    Text("· " + tr("agents.pr.openedAgo", AgentFormat.short(Date().timeIntervalSince(created))))
                }
                if let updated = detail?.updated ?? item.updated {
                    Text("· " + tr("agents.pr.updatedAgo", AgentFormat.short(Date().timeIntervalSince(updated))))
                }
                Spacer(minLength: 0)
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .lineLimit(1)
            if let detail {
                branchLine(detail)
            } else {
                GhostBar(width: 260)
            }
        }
    }

    private var glyph: PullRequestBadge.Glyph {
        guard let detail else {
            switch item.state {
            case .merged: return .merged
            case .closed: return .closed
            case .open: return item.draft ? .draft : .open
            }
        }
        if detail.state == .open && detail.conflicted { return .conflict }
        return PullRequestBadge.Glyph(rawValue: detail.state.rawValue) ?? .open
    }

    /// "main ← feature" with the size of the change: how many files, the lines added and removed, and a small bar.
    private func branchLine(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: "arrow.triangle.branch").font(NookTheme.font(10.5, .medium))
                Text(detail.baseBranch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.left").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textMuted)
                Text(detail.headBranch).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.middle)
            }
            .font(NookTheme.mono(11.5))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.xxs)
            .background(Capsule().fill(NookTheme.rowHover))
            .help(tr("agents.pr.copyBranch"))
            .onTapGesture {
                Pasteboard.copy(detail.headBranch)
                ToastCenter.shared.success(tr("agents.pr.copiedBranch"))
            }
            .accessibilityAddTraits(.isButton)
            ToolbarIconButton("terminal", tr("agents.pr.action.copyCheckout")) {
                Pasteboard.copy(PullRequestMoreMenu.checkout(detail))
                ToastCenter.shared.success(tr("agents.pr.action.copied"))
            }
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
            HStack(spacing: NookTheme.Spacing.sm) {
                HStack(spacing: NookTheme.Spacing.xxs) {
                    Image(systemName: "doc").font(NookTheme.font(10))
                    Text(tr("agents.pr.filesCount", max(detail.changedFiles, detail.files.count)))
                }
                .foregroundStyle(NookTheme.textTertiary)
                Text("+\(detail.additions)").foregroundStyle(NookTheme.mint)
                Text("−\(detail.deletions)").foregroundStyle(NookTheme.coral)
                DiffStatBar(additions: detail.additions, deletions: detail.deletions)
            }
            .font(NookTheme.TextStyle.detail.monospacedDigit())
            .lineLimit(1)
            .fixedSize()
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
            ], selected: tab) { value in
                switchTo(value)
            }
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
                    Label("\(comments(detail, includeBots: true).count)", systemImage: "bubble.left")
                        .help(tr("agents.pr.count.comments"))
                    Label("\(detail.commits.count)", systemImage: "circle.and.line.horizontal")
                        .help(tr("agents.pr.count.commits"))
                    if approvals > 0 {
                        Label("\(approvals)", systemImage: "checkmark.circle").foregroundStyle(NookTheme.mint)
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
                page { timeline(detail, now: now) }
            } else {
                activityLoading
            }
        case .code:
            if !detail.activityLoaded {
                activityLoading
            } else if let path = openFile, let file = detail.files.first(where: { $0.path == path }) {
                fileDiff(file, detail: detail)
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

    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, NookTheme.Spacing.md)
        }
        .frame(maxHeight: .infinity)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Summary

    /// The Summary: who reviews and which labels, then the description, the checks and the comments, each a section
    /// that folds under its heading.
    private func summary(_ detail: PullRequestDetail, now: Date) -> some View {
        let shownComments = comments(detail, includeBots: showBotComments)
        let hiddenBots = comments(detail, includeBots: true).count - comments(detail, includeBots: false).count
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
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
                .padding(NookTheme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelCard()
            }

            SummarySection(title: tr("agents.pr.status.checks"), open: $checksOpen) {
                checks(detail)
            } accessory: {
                checksSummary(detail).font(NookTheme.TextStyle.detail)
            }

            SummarySection(title: tr("agents.pr.comments", detail.activityLoaded ? shownComments.count : (detail.commentCount ?? 0)),
                           open: $commentsOpen) {
                if !detail.activityLoaded {
                    ForEach(0..<2, id: \.self) { _ in GhostRow() }
                } else if shownComments.isEmpty {
                    ListEmptyNote(tr("agents.pr.conversation.none"))
                } else {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        ForEach(commentsNewestFirst ? Array(shownComments.reversed()) : shownComments) { event in
                            eventCard(event, now: now, avatar: true)
                        }
                    }
                }
            } accessory: {
                HStack(spacing: NookTheme.Spacing.md) {
                    if hiddenBots > 0 || showBotComments {
                        Button {
                            showBotComments.toggle()
                        } label: {
                            Text(showBotComments ? tr("agents.pr.comments.hideBots") : tr("agents.pr.comments.botsHidden", hiddenBots))
                                .font(NookTheme.TextStyle.caption)
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    orderButton(newestFirst: $commentsNewestFirst)
                }
            }
        }
    }

    /// The conversation: comments, reviews with something to say or a verdict, and comments on lines, oldest first.
    private func comments(_ detail: PullRequestDetail, includeBots: Bool) -> [PullRequestEvent] {
        detail.events.filter { event in
            if !includeBots && event.author.lowercased().hasSuffix("[bot]") { return false }
            switch event.kind {
            case .comment, .lineComment: return true
            case .review: return !event.body.isEmpty || isVerdict(event.kind)
            case .commit, .activity: return false
            }
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

    /// The reviewers' pictures, ringed by what they said (mint approved, coral changes requested, grey still asked).
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
                    reviewer(verdict.author, ring: verdict.approved ? NookTheme.mint : NookTheme.coral,
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
                    TimelineMarker(symbol: "arrow.triangle.pull", color: NookTheme.mint)
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
                    TimelineMarker(symbol: "arrow.triangle.pull", color: NookTheme.mint)
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
            TimelineRail(last: last) {
                TimelineMarker(symbol: "smallcircle.filled.circle", color: NookTheme.textTertiary)
            } content: {
                commitRun(run, detail: detail, now: now)
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
                    GitHubAvatar(login: event.author, size: 22)
                } content: {
                    eventCard(event, now: now)
                }
            }
        }
    }

    private func activityLine(author: String, sentence: String, date: Date?, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            (Text("@" + author + " ").font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.textStrong)
                + Text(sentence).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let date { timeLabel(date, now: now) }
        }
        .padding(.top, 3)
    }

    /// Commits one person added one after the other: one line saying so, and each commit under it.
    private func commitRun(_ run: [PullRequestEvent], detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            activityLine(author: run.first?.author ?? "?",
                         sentence: run.count == 1 ? tr("agents.pr.timeline.pushedOne") : tr("agents.pr.timeline.pushed", run.count),
                         date: run.last?.date, now: now)
            VStack(spacing: 0) {
                ForEach(run) { event in
                    if case .commit(let sha) = event.kind {
                        HoverRow(action: { openCommit(sha, detail: detail) }) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                Text(String(sha.prefix(7))).font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary)
                                Text(event.body).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
                                Spacer(minLength: 4)
                            }
                        }
                    }
                }
            }
            .panelCard()
        }
    }

    private func openCommit(_ sha: String, detail: PullRequestDetail) {
        if let url = detail.url?.appendingPathComponent("commits/" + sha) { NSWorkspace.shared.open(url) }
    }

    private func timeLabel(_ date: Date, now: Date) -> some View {
        Text(AgentFormat.short(now.timeIntervalSince(date)))
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(date.formatted(date: .abbreviated, time: .shortened))
    }

    private func activityLook(_ type: String) -> (symbol: String, color: Color) {
        switch type {
        case "labeled", "unlabeled": return ("tag", NookTheme.textTertiary)
        case "assigned", "unassigned": return ("person", NookTheme.textTertiary)
        case "review_requested", "review_request_removed", "ready_for_review": return ("eye", NookTheme.textTertiary)
        case "renamed": return ("pencil", NookTheme.textTertiary)
        case "convert_to_draft": return ("pencil.circle", NookTheme.textTertiary)
        case "head_ref_force_pushed": return ("arrow.up.circle", NookTheme.amber)
        case "head_ref_deleted", "head_ref_restored", "base_ref_changed": return ("arrow.triangle.branch", NookTheme.textTertiary)
        case "merged": return ("arrow.triangle.merge", NookTheme.violet)
        case "closed": return ("xmark.circle", NookTheme.coral)
        case "reopened": return ("arrow.uturn.left.circle", NookTheme.mint)
        case "cross-referenced", "referenced": return ("link", NookTheme.textTertiary)
        case "milestoned", "demilestoned": return ("flag", NookTheme.textTertiary)
        case "auto_merge_enabled", "auto_merge_disabled": return ("bolt", NookTheme.textTertiary)
        case "review_dismissed": return ("xmark.bubble", NookTheme.textTertiary)
        default: return ("circle", NookTheme.textTertiary)
        }
    }

    /// A comment or review as a card: who and what on top (a review's verdict in its color), the text under it.
    /// With `avatar` the author's picture leads the card (the Summary's comments, which have no rail beside them).
    private func eventCard(_ event: PullRequestEvent, now: Date, avatar: Bool = false) -> some View {
        let (label, color) = eventLabel(event.kind)
        let verdict = isVerdict(event.kind)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                if avatar { GitHubAvatar(login: event.author, size: 18) }
                Text("@" + event.author).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper).lineLimit(1)
                if verdict {
                    Text(label)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(color)
                        .padding(.horizontal, NookTheme.Spacing.sm)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(color.opacity(0.14)))
                        .lineLimit(1)
                } else {
                    Text(label).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let date = event.date { timeLabel(date, now: now) }
                if let url = event.url {
                    ToolbarIconButton("arrow.up.right", tr("agents.pulls.open"), height: 20, width: 20) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if !event.body.isEmpty {
                MarkdownView(text: event.body, size: 13.5)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    /// An approval or a request for changes, which wears its verdict as a tinted pill.
    private func isVerdict(_ kind: PullRequestEvent.Kind) -> Bool {
        if case .review(let state) = kind { return state == "APPROVED" || state == "CHANGES_REQUESTED" }
        return false
    }

    private func eventLabel(_ kind: PullRequestEvent.Kind) -> (String, Color) {
        switch kind {
        case .comment: return (tr("agents.pr.event.comment"), NookTheme.textTertiary)
        case .commit, .activity: return ("", NookTheme.textTertiary)
        case .lineComment(let path, let line):
            return (tr("agents.pr.event.line", line.map { "\(path):\($0)" } ?? path), NookTheme.textTertiary)
        case .review(let state):
            switch state {
            case "APPROVED": return (tr("agents.pr.event.approved"), NookTheme.mint)
            case "CHANGES_REQUESTED": return (tr("agents.pr.event.changes"), NookTheme.coral)
            case "DISMISSED": return (tr("agents.pr.event.dismissed"), NookTheme.textTertiary)
            default: return (tr("agents.pr.event.reviewed"), NookTheme.textTertiary)
            }
        }
    }

    // MARK: Checks

    /// The checks by outcome: what fails first, then what runs, then what passed or was skipped.
    private func checks(_ detail: PullRequestDetail) -> some View {
        let groups: [(PullRequestCheck.Outcome, String)] = [
            (.failing, "agents.pr.checks.group.failing"), (.pending, "agents.pr.checks.group.running"),
            (.passing, "agents.pr.checks.group.passed"), (.skipped, "agents.pr.checks.group.skipped"),
        ]
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if detail.checks.isEmpty {
                ListEmptyNote(tr("agents.pr.checks.none"))
            } else {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    let rows = detail.checks.filter { $0.outcome == group.0 }
                    if !rows.isEmpty {
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                            NookSectionLabel(tr(group.1) + " · \(rows.count)", inset: NookTheme.Spacing.xs)
                            VStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.offset) { index, check in
                                    if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 16 + NookTheme.Spacing.md) }
                                    checkRow(check)
                                }
                            }
                            .panelCard()
                        }
                    }
                }
            }
        }
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

    private func mergeBar(_ detail: PullRequestDetail) -> some View {
        let note = detail.mergeNote
        let ready = detail.canMerge && note == nil
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if confirmMerge {
                confirmation(detail)
            } else {
                mergeRow(detail, note: note, ready: ready)
            }
            if let mergeError {
                Text(mergeError)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.rowHover))
    }

    /// The confirmation, inside the bar: a system dialog is a window of its own, and on the notch panel its buttons do not
    /// reliably get the click (the merge never ran).
    private func confirmation(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.amber)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("agents.pr.confirmTitle", "#\(detail.number)", detail.baseBranch))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Text(confirmMessage)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            NookGhostButton(title: tr("button.cancel")) { confirmMerge = false }
            NookPrimaryButton(title: tr("agents.pr.confirmButton")) {
                confirmMerge = false
                merge()
            }
        }
    }

    private func mergeRow(_ detail: PullRequestDetail, note: String?, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : detail.canMerge ? "exclamationmark.triangle.fill" : "info.circle")
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(ready ? NookTheme.mint : detail.canMerge ? NookTheme.amber : NookTheme.textSecondary)
            Text(tr(note ?? "agents.pr.note.ready"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if actions.panel != .write {
                NookGhostButton(title: tr("agents.pr.write.open"), symbol: "square.and.pencil", compact: true, height: 30) {
                    withAnimation(NookTheme.swap) { actions.open(.write, detail: detail) }
                }
                .disabled(actions.sending)
            }
            if detail.isOpen && detail.canPush != false && !detail.methods.isEmpty {
                Menu {
                    ForEach(detail.methods) { option in
                        Button(tr(option.titleKey)) { methodRaw = option.rawValue }
                    }
                } label: {
                    Text(tr(method.titleKey)).font(NookTheme.TextStyle.detail)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(merging)
                if merging {
                    ProgressView().controlSize(.small)
                }
                NookPrimaryButton(title: merging ? tr("agents.pr.merging") : tr("agents.pr.merge")) {
                    mergeError = nil
                    confirmMerge = true
                }
                .disabled(!detail.canMerge || merging)
                .opacity(!detail.canMerge || merging ? 0.4 : 1)
            }
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
            mergeError = tr("agents.pr.noToken")
            return
        }
        let method = self.method
        let args = "\(detail.id) · \(method.rawValue) · \(detail.headBranch) → \(detail.baseBranch)"
        merging = true
        model.paused = true
        mergeError = nil
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
                    mergeError = error.localizedDescription
                }
            }
        }
    }

    /// Shows the merge at once, here, in the list and on the agent rows, without waiting for GitHub's next answers.
    private func settle() {
        merging = false
        mergeError = nil
        model.markMerged()
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

/// One entry on the timeline: its marker on a thin rail that runs down to the next entry, the entry beside it.
private struct TimelineRail<Marker: View, Content: View>: View {
    let last: Bool
    @ViewBuilder let marker: () -> Marker
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            marker().frame(width: 22, height: 22)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, NookTheme.Spacing.lg)
        .background(alignment: .topLeading) {
            if !last {
                NookDivider(vertical: true)
                    .padding(.leading, 10.5)
                    .padding(.top, 24)
            }
        }
    }
}

/// The round marker of an event on the timeline rail.
private struct TimelineMarker: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(NookTheme.font(10.5, .medium))
            .foregroundStyle(color)
            .frame(width: 22, height: 22)
            .background(Circle().fill(NookTheme.field))
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
