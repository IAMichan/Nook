import AppKit
import SwiftUI

/// The Summary tab: the Status, Reviewers and Labels lines, then the description, the checks and the comments.
extension PullRequestDetailView {
    // MARK: Summary

    /// The Summary: who reviews and which labels, then the description, the checks and the comments, each a section
    /// that folds under its heading.
    func summary(_ detail: PullRequestDetail, now: Date) -> some View {
        let conversation = PullRequestConversation.items(detail.events)
        let total = PullRequestConversation.commentCount(conversation)
        let hidden = total - PullRequestConversation.commentCount(
            PullRequestConversation.filtered(conversation, bots: showBotComments, finished: showFinishedComments))
        // Lazy for the pinned headings alone: each section's heading stays at the top while its section scrolls under it.
        return LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.lg, pinnedViews: .sectionHeaders) {
            // Where it stands, first and in full: the one thing to know before anything else on the page.
            if let readiness = PullRequestReadiness(detail) {
                readinessCard(readiness, detail: detail)
            }
            // A few quiet lines: who reviews, which labels. The rest folds below.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                // Auto-merge belongs with the Status line: both say when it will merge.
                if let auto = detail.autoMerge, detail.isOpen {
                    metaRow(symbol: "bolt", title: tr("agents.pr.status.autoMerge")) {
                        Text([auto.method.map { tr($0.titleKey) }, tr("agents.pr.autoMerge.by", "@" + auto.enabledBy)]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textStrong)
                            .lineLimit(1)
                    }
                }
                metaRow(symbol: "person.2", title: tr("agents.pr.status.reviewers")) { reviewers(detail) }
                // The lines below only show when GitHub has something to say, so a plain pull request stays short.
                if !detail.assignees.isEmpty {
                    metaRow(symbol: "person.crop.circle", title: tr("agents.pr.status.assignees")) { people(detail.assignees) }
                }
                if !detail.labels.isEmpty || (detail.isOpen && detail.canPush != false && detail.features.labels) {
                    metaRow(symbol: "tag", title: tr("agents.pr.status.labels")) {
                        ChipFlow(spacing: NookTheme.Spacing.xs) {
                            ForEach(detail.labels, id: \.self) { label in
                                LabelChip(name: label, color: detail.labelColors[label], description: detail.labelDescriptions[label])
                            }
                            if detail.isOpen, detail.canPush != false, detail.features.labels {
                                ToolbarIconButton("plus", tr("agents.pr.action.labels"), height: 20, width: 20) { actions.open(.labels, detail: detail) }
                            }
                        }
                    }
                }
                if !detail.linkedIssues.isEmpty {
                    metaRow(symbol: "smallcircle.filled.circle", title: tr("agents.pr.status.issues")) { linkedIssues(detail) }
                }
                if let milestone = detail.milestone {
                    metaRow(symbol: "flag", title: tr("agents.pr.status.milestone")) {
                        Text(milestone).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textStrong).lineLimit(1)
                    }
                }
                if detail.locked {
                    metaRow(symbol: "lock", title: tr("agents.pr.status.conversation")) {
                        Text([tr("agents.pr.locked"), detail.lockReason.map { lockReason($0) }].compactMap { $0 }.joined(separator: " · "))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textStrong)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, NookTheme.Spacing.xs)

            PullRequestSummarySection(title: tr("agents.pr.tab.description"), open: $descriptionOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    if detail.body.isEmpty {
                        Text(tr("agents.pr.noDescription")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textTertiary)
                    } else {
                        PullRequestEditableLine(help: tr("agents.pr.editDescription"), enabled: canEdit) {
                            actions.open(.edit, detail: detail)
                        } content: {
                            PullRequestDescription(text: detail.body, editable: detail.canPush != false) { line, checked in
                                guard let body = MarkdownTasks.setting(checked, line: line, in: detail.body) else { return }
                                actions.close()
                                actions.pending = .edit(title: detail.title, body: body)
                            }
                        }
                    }
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Emoji on the description: as on a comment, with an event that stands for it.
                let description = PullRequestEvent.description(detail)
                if detail.features.reactions {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        if !description.reactions.isEmpty { PullRequestReactionBar(event: description) }
                        PullRequestReactionPicker(event: description)
                    }
                    .padding(.horizontal, NookTheme.Spacing.xs)
                }
            }

            PullRequestSummarySection(title: tr("agents.pr.status.checks"), open: $checksOpen) {
                checks(detail)
            } accessory: {
                checksSummary(detail).font(NookTheme.TextStyle.detail)
            }
            .id(PullRequestPageScrollRequest.checks)

            PullRequestSummarySection(title: tr("agents.pr.comments", detail.activityLoaded ? total : (detail.commentCount ?? 0)),
                           open: $commentsOpen) {
                if !detail.activityLoaded {
                    ForEach(0..<2, id: \.self) { _ in PullRequestGhostRow() }
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

    /// Where the pull request stands, at the top of the Summary: the verdict ("Ready to merge", "Not ready yet", "Needs
    /// changes") in its color with what is already fine under it, a bar of the checks (passed, failed, still running),
    /// and every line that still stands in the way, each saying why in plain words. A line with something to look at
    /// or do takes you there: the checks unfold, the reviews open the timeline, a branch behind updates, a missing
    /// review asks for one. The merge itself stays in the page's header, so there is one place to merge from.
    func readinessCard(_ readiness: PullRequestReadiness, detail: PullRequestDetail) -> some View {
        let verdict = readinessVerdict(readiness)
        let fine = readiness.items.filter { $0.tone == .good }.map(readinessText)
        // What is left, the lines in the way first, then what waits, then what has nothing to say either way.
        let rank: (PullRequestReadiness.Tone) -> Int = { [.blocking: 0, .waiting: 1, .neutral: 2][$0] ?? 3 }
        let open = readiness.items.filter { $0.tone != .good }.sorted { rank($0.tone) < rank($1.tone) }
        let counts = detail.checkCounts
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                Image(icon: verdict.symbol)
                    .font(NookTheme.font(15, .semibold))
                    .foregroundStyle(verdict.color)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(verdict.title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                    if !fine.isEmpty {
                        Text(fine.joined(separator: " · "))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(tr("agents.pr.status.state") + ": " + ([verdict.title] + fine).joined(separator: ", "))
            if !detail.checks.isEmpty {
                PullRequestChecksBar(passing: counts.passing, failing: counts.failing, pending: counts.pending,
                                     skipped: counts.skipped)
            }
            ForEach(Array(open.enumerated()), id: \.offset) { index, item in
                if index > 0 || detail.checks.isEmpty { NookDivider() }
                readinessRow(item, detail: detail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(NookTheme.field, stroke: NookTheme.border, radius: NookTheme.Radius.card)
        .roundedClip(NookTheme.Radius.card)
    }

    func readinessVerdict(_ readiness: PullRequestReadiness) -> (symbol: String, color: Color, title: String) {
        switch readiness.verdict {
        case .ready: ("checkmark.circle.fill", NookTheme.mint, tr("agents.pr.ready.verdict.ready"))
        case .waiting: ("clock.fill", NookTheme.amber, tr("agents.pr.ready.verdict.waiting"))
        case .blocked: ("exclamationmark.circle.fill", NookTheme.coral, tr("agents.pr.ready.verdict.blocked"))
        }
    }

    @ViewBuilder
    func readinessRow(_ item: PullRequestReadiness.Item, detail: PullRequestDetail) -> some View {
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
                    Image(icon: "chevron.right").font(NookTheme.font(8.5, .bold))
                }
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
            }
        }
        if let action = readinessAction(item, detail: detail) {
            PullRequestHoverRow(action: action) { line }
        } else {
            line
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.sm + NookTheme.Spacing.xxs)
        }
    }

    func readinessMark(_ tone: PullRequestReadiness.Tone) -> some View {
        let look: (symbol: String, color: Color) = switch tone {
        case .good: ("checkmark", NookTheme.mint)
        case .waiting: ("circle.dotted", NookTheme.amber)
        case .blocking: ("xmark", NookTheme.coral)
        case .neutral: ("minus", NookTheme.textTertiary)
        }
        return Image(icon: look.symbol).font(NookTheme.font(11, .bold)).foregroundStyle(look.color)
    }

    func readinessText(_ item: PullRequestReadiness.Item) -> String {
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
    func readinessHint(_ item: PullRequestReadiness.Item) -> String? {
        switch item {
        case .checksFailing, .checksRunning: tr("agents.pr.ready.showChecks")
        case .changesRequested: tr("agents.pr.ready.showReviews")
        case .behind: tr("agents.pr.action.updateBranch")
        case .noReviews: tr("agents.pr.ready.askReview")
        case .conflicts where sessionContext != nil: tr("session.context.resolve")
        default: nil
        }
    }

    func readinessAction(_ item: PullRequestReadiness.Item, detail: PullRequestDetail) -> (() -> Void)? {
        switch item {
        case .checksFailing, .checksRunning:
            return { revealChecks() }
        case .changesRequested:
            return { switchTo(.timeline) }
        case .behind where detail.canPush != false:
            return {
                actions.close()
                actions.pending = .updateBranch(headSHA: detail.headSHA)
            }
        case .noReviews where detail.isOpen:
            return { actions.open(.reviewers, detail: detail) }
        case .conflicts:
            guard let sessionContext else { return nil }
            return { ComposerInbox.shared.add(SessionPrompts.resolveConflicts(detail.sessionRef), to: sessionContext) }
        default:
            return nil
        }
    }

    /// One line of the Summary's top: a name in a narrow column on the left, its value on the right.
    func metaRow<Value: View>(symbol: String, title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Label(title, icon: symbol)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 96, alignment: .leading)
            value()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The reviewers' pictures, ringed by what they said (mint approved, amber changes requested, grey still asked).
    /// While the pull request is open a + after them asks someone else for a review.
    @ViewBuilder
    func reviewers(_ detail: PullRequestDetail) -> some View {
        let verdicts = detail.verdicts
        let waiting = detail.requestedReviewers.filter { login in !verdicts.contains { $0.author == login } }
        HStack(spacing: NookTheme.Spacing.xs) {
            if verdicts.isEmpty && waiting.isEmpty {
                if detail.activityLoaded {
                    Text(tr("agents.pr.reviews.none")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            } else {
                // Overlapping, so a long list of reviewers keeps to one line.
                HStack(spacing: -NookTheme.Spacing.xs) {
                    ForEach(verdicts, id: \.author) { verdict in
                        reviewer(verdict.author, ring: PullRequestIcon.tint(verdict.approved ? PullRequestIcon.Review.approved : .changesRequested),
                                 help: tr(verdict.approved ? "agents.pr.reviews.approved" : "agents.pr.reviews.changes", "@" + verdict.author))
                    }
                    ForEach(waiting, id: \.self) { login in
                        if detail.requestedTeams.contains(login) {
                            team(login)
                        } else {
                            reviewer(login, ring: NookTheme.line2, help: tr("agents.pr.reviews.waiting", "@" + login))
                        }
                    }
                }
            }
            if detail.isOpen, detail.features.reviewers {
                ToolbarIconButton("person.badge.plus", tr("agents.pr.action.requestReviewers")) {
                    actions.open(.reviewers, detail: detail)
                }
            }
        }
    }

    /// A team asked for a review: a team mark in the same ring, its name on hover.
    func team(_ name: String) -> some View {
        Image(icon: "person.3.fill")
            .font(NookTheme.font(8, .semibold))
            .foregroundStyle(NookTheme.textSecondary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(NookTheme.rowHover))
            .padding(2)
            .overlay(Circle().strokeBorder(NookTheme.line2, lineWidth: 1.5))
            .help(tr("agents.pr.reviews.waiting", name))
    }

    /// The issues this pull request closes, one per line: open or closed in the state's color, the number (with its
    /// repository when it lives elsewhere) and the title; a click opens it on GitHub.
    func linkedIssues(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            ForEach(detail.linkedIssues) { issue in
                Button {
                    if let url = issue.url { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        Image(icon: issue.open ? "smallcircle.filled.circle" : "checkmark.circle")
                            .font(NookTheme.font(11, .semibold))
                            .foregroundStyle(issue.open ? PullRequestIcon.tint(.open) : PullRequestIcon.tint(.merged))
                        Text((issue.repo.isEmpty || issue.repo.lowercased() == detail.repo.lowercased() ? "" : issue.repo) + "#\(issue.number)")
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .monospacedDigit()
                            .lineLimit(1)
                            // Another repository's long name gives way first; the number at its end stays.
                            .truncationMode(.head)
                            .frame(maxWidth: 160, alignment: .leading)
                            .fixedSize()
                        Text(issue.title)
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textStrong)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .disabled(issue.url == nil)
                .help(issue.title)
            }
        }
    }

    /// GitHub's reason for a lock, in words.
    func lockReason(_ reason: String) -> String {
        switch reason {
        case "off-topic": tr("agents.pr.lockReason.offTopic")
        case "too heated": tr("agents.pr.lockReason.tooHeated")
        case "resolved": tr("agents.pr.lockReason.resolved")
        case "spam": tr("agents.pr.lockReason.spam")
        default: reason
        }
    }

    /// People by picture and login, for the Assignees line.
    func people(_ logins: [String]) -> some View {
        ChipFlow(spacing: NookTheme.Spacing.sm) {
            ForEach(logins, id: \.self) { login in
                GitHubPerson(login: login, size: 18, font: NookTheme.TextStyle.detail)
            }
        }
    }

    func reviewer(_ login: String, ring: Color, help: String) -> some View {
        GitHubAvatar(login: login, size: 20)
            .padding(2)
            .overlay(Circle().strokeBorder(ring, lineWidth: 1.5))
            .help(help)
    }

    /// Unfolds the checks and scrolls the Summary down to them: they sit under the description, often out of sight.
    func revealChecks() {
        withAnimation(NookTheme.reveal) { checksOpen = true }
        scrollRequest = PullRequestPageScrollRequest(target: PullRequestPageScrollRequest.checks)
    }

    @ViewBuilder
    func checksSummary(_ detail: PullRequestDetail) -> some View {
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

    func countLabel(_ outcome: PullRequestCheck.Outcome, _ text: String) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            CheckOutcomeGlyph(outcome: outcome)
            Text(text).foregroundStyle(outcome == .failing ? NookTheme.paper : NookTheme.textSecondary)
        }
    }

    // MARK: Checks

    /// The checks as one card, the ones that need you first: failing, then running, then passed, skipped last. Each row
    /// opens what the check has to say in Nook.
    @ViewBuilder
    func checks(_ detail: PullRequestDetail) -> some View {
        if detail.checks.isEmpty {
            ListEmptyNote(tr("agents.pr.checks.none"))
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sortedChecks(detail.checks).enumerated()), id: \.offset) { index, check in
                    if index > 0 { NookRowSeparator() }
                    checkRow(check, detail: detail)
                }
            }
            .padding(.vertical, NookTheme.Spacing.xs)
            .panelCard()
        }
    }

    func sortedChecks(_ checks: [PullRequestCheck]) -> [PullRequestCheck] {
        let rank: [PullRequestCheck.Outcome: Int] = [.failing: 0, .pending: 1, .passing: 2, .skipped: 3]
        return checks.enumerated()
            .sorted { (rank[$0.element.outcome] ?? 4, $0.offset) < (rank[$1.element.outcome] ?? 4, $1.offset) }
            .map(\.element)
    }

    /// A row opens the check in Nook: an Actions job its steps and log, a check from another app its report and what the
    /// app wrote on the pull request. Only without a readable pull request does it fall back to the check's own page.
    func checkRow(_ check: PullRequestCheck, detail: PullRequestDetail) -> some View {
        let readsHere = detail.url.flatMap(GitHubPullRequests.parse) != nil
        return PullRequestHoverRow(action: {
            if readsHere {
                withAnimation(NookTheme.swap) { openCheck = check }
            } else if let url = check.url {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: NookTheme.Spacing.md) {
                CheckOutcomeGlyph(outcome: check.outcome, running: check.running).frame(width: 16)
                Text(check.name).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
                Spacer(minLength: 4)
                CICheckStatusText(check: check)
                if let runID = check.approvalRunID, detail.canPush != false {
                    ToolbarIconButton("checkmark.shield", tr("agents.pr.action.approveWorkflow")) {
                        actions.close()
                        actions.pending = .approveWorkflow(runID: runID)
                    }
                } else if check.outcome == .failing, let sessionContext {
                    SessionFixButton(help: tr("session.context.fixCheck")) {
                        ComposerInbox.shared.add(SessionPrompts.fixChecks(detail.sessionRef, failing: [check.name]), to: sessionContext)
                    }
                }
                if readsHere || check.url != nil {
                    Image(icon: readsHere ? "chevron.right" : "arrow.up.right")
                        .font(NookTheme.font(9, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                }
            }
        }
        .disabled(!readsHere && check.url == nil)
    }
}

extension PullRequestEvent {
    /// The description as something emoji can be put on.
    static func description(_ detail: PullRequestDetail) -> PullRequestEvent {
        var event = PullRequestEvent(id: "description-\(detail.number)", kind: .comment, author: detail.author, body: "", date: nil, url: nil)
        event.reactions = detail.reactions
        return event
    }
}
