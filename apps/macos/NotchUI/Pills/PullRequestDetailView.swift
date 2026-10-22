import AppKit
import SwiftUI

/// One pull request, read in full inside Nook. On top what it is (title, state, author, branches, size), then the
/// tabs: an overview (checks, reviews, labels and the description at a glance), the timeline, the commits, the checks
/// and every changed file with its diff. The bar at the bottom merges it, after you confirm, with the account it was
/// listed under.
///
/// The page opens at once: the top shows what the list already knew while GitHub is asked, the overview follows with
/// the first answer and the timeline, commits and files after it (see PullRequestDetailModel, which also keeps it
/// current while open).
struct PullRequestDetailView: View {
    @EnvironmentObject private var app: AppModel
    let accountID: String
    let item: PullRequestItem
    let onBack: () -> Void

    enum Tab: Hashable { case overview, timeline, commits, checks, files }

    @StateObject private var model: PullRequestDetailModel
    @State private var tab: Tab = .overview
    @State private var openFile: String?
    @AppStorage("agents.pr.mergeMethod") private var methodRaw = PullRequestMergeMethod.merge.rawValue
    @State private var confirmMerge = false
    @State private var merging = false
    @State private var mergeError: String?

    init(accountID: String, item: PullRequestItem, onBack: @escaping () -> Void) {
        self.accountID = accountID
        self.item = item
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
            NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 28, action: onBack)
                .help(tr("agents.pr.back"))
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
            if let url = detail?.url ?? item.url {
                NookIconButton(systemName: "link", label: tr("agents.pr.copyLink"), size: 28) {
                    Pasteboard.copy(url.absoluteString)
                    ToastCenter.shared.success(tr("agents.pr.copiedLink"))
                }
                    .help(tr("agents.pr.copyLink"))
                NookIconButton(systemName: "arrow.up.right.square", label: tr("agents.pulls.open"), size: 28) { NSWorkspace.shared.open(url) }
                    .help(tr("agents.pulls.open"))
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
                        ChatPersonBadge(name: author, size: 16)
                        Text("@" + author).foregroundStyle(NookTheme.textSecondary)
                    }
                }
                if let created = detail?.created {
                    Text("· " + tr("agents.pr.openedAgo", AgentFormat.short(Date().timeIntervalSince(created))))
                } else if let updated = item.updated {
                    Text("· " + AgentFormat.short(Date().timeIntervalSince(updated)))
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

    private func tabs(_ detail: PullRequestDetail) -> some View {
        let failing = detail.checkCounts.failing
        return HStack(spacing: 0) {
            NookTabBar<Tab>(items: [
                .init(value: Tab.overview, title: tr("agents.pr.tab.overview")),
                .init(value: Tab.timeline, title: detail.activityLoaded
                      ? tr("agents.pr.tab.timeline", detail.events.count) : tr("agents.pr.tab.timelinePlain")),
                .init(value: Tab.commits, title: tr("agents.pr.tab.commits", detail.activityLoaded ? detail.commits.count : (detail.commitCount ?? 0))),
                .init(value: Tab.checks, title: tr("agents.pr.tab.checks", detail.checks.count),
                      help: failing > 0 ? tr("agents.pr.checks.failing", failing) : nil),
                .init(value: Tab.files, title: tr("agents.pr.tab.files", max(detail.changedFiles, detail.files.count))),
            ], selected: tab) { value in
                withAnimation(NookTheme.swap) { tab = value }
                if value != .files { openFile = nil }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func content(_ detail: PullRequestDetail, now: Date) -> some View {
        switch tab {
        case .overview:
            page { overview(detail, now: now) }
        case .timeline:
            if detail.activityLoaded {
                page { timeline(detail, now: now) }
            } else {
                activityLoading
            }
        case .commits:
            if detail.activityLoaded {
                page { commits(detail, now: now) }
            } else {
                activityLoading
            }
        case .checks:
            page { checks(detail) }
        case .files:
            if !detail.activityLoaded {
                activityLoading
            } else if let path = openFile, let file = detail.files.first(where: { $0.path == path }) {
                fileDiff(file, detail: detail)
            } else {
                page { files(detail) }
            }
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

    // MARK: Overview

    /// Where the pull request stands, at a glance, and its description.
    private func overview(_ detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            VStack(spacing: 0) {
                statusRow(symbol: "checkmark.seal", title: tr("agents.pr.status.checks"), action: { switchTo(.checks) }) {
                    checksSummary(detail)
                }
                NookDivider(inset: NookTheme.Spacing.lg)
                statusRow(symbol: "person.2", title: tr("agents.pr.status.reviews"), action: { switchTo(.timeline) }) {
                    reviewsSummary(detail)
                }
                if !detail.labels.isEmpty {
                    NookDivider(inset: NookTheme.Spacing.lg)
                    statusRow(symbol: "tag", title: tr("agents.pr.status.labels"), action: nil) {
                        labelChips(detail.labels)
                    }
                }
            }
            .panelCard()

            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                NookSectionLabel(tr("agents.pr.tab.description"), inset: NookTheme.Spacing.xs)
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
        }
    }

    private func switchTo(_ value: Tab) {
        withAnimation(NookTheme.swap) { tab = value }
        openFile = nil
    }

    /// One line of the overview card: a name on the left, its state on the right, a click to the tab with the rest.
    private func statusRow<Value: View>(symbol: String, title: String, action: (() -> Void)?,
                                        @ViewBuilder value: () -> Value) -> some View {
        StatusRow(symbol: symbol, title: title, action: action, value: value())
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

    @ViewBuilder
    private func reviewsSummary(_ detail: PullRequestDetail) -> some View {
        let verdicts = detail.verdicts
        let approved = verdicts.filter(\.approved).map { "@" + $0.author }
        let changes = verdicts.filter { !$0.approved }.map { "@" + $0.author }
        let waiting = detail.requestedReviewers.map { "@" + $0 }
        if !detail.activityLoaded && waiting.isEmpty {
            ProgressView().controlSize(.mini)
        } else if approved.isEmpty && changes.isEmpty && waiting.isEmpty {
            Text(tr("agents.pr.reviews.none")).foregroundStyle(NookTheme.textTertiary)
        } else {
            VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
                if !changes.isEmpty {
                    reviewLine("xmark.circle.fill", NookTheme.coral, tr("agents.pr.reviews.changes", changes.joined(separator: ", ")))
                }
                if !approved.isEmpty {
                    reviewLine("checkmark.circle.fill", NookTheme.mint, tr("agents.pr.reviews.approved", approved.joined(separator: ", ")))
                }
                if !waiting.isEmpty {
                    reviewLine("clock", NookTheme.textSecondary, tr("agents.pr.reviews.waiting", waiting.joined(separator: ", ")))
                }
            }
        }
    }

    private func reviewLine(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(systemName: symbol).font(NookTheme.font(11)).foregroundStyle(color)
            Text(text).foregroundStyle(NookTheme.textSecondary).lineLimit(1).truncationMode(.tail)
        }
    }

    private func labelChips(_ labels: [String]) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            ForEach(labels.prefix(4), id: \.self) { label in
                Text(label)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textSecondary)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .background(Capsule().fill(NookTheme.rowHover))
                    .lineLimit(1)
            }
            if labels.count > 4 {
                Text("+\(labels.count - 4)").font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            }
        }
    }

    // MARK: Timeline

    /// The history as one rail, oldest first: who did what, with conversations as cards and commits in runs.
    private func timeline(_ detail: PullRequestDetail, now: Date) -> some View {
        let entries = PullRequestTimelineEntry.entries(detail.events)
        return VStack(alignment: .leading, spacing: 0) {
            if let created = detail.created {
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
                    timelineEntry(entry, detail: detail, now: now, last: index == entries.count - 1)
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
                    ChatPersonBadge(name: event.author, size: 22)
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
    private func eventCard(_ event: PullRequestEvent, now: Date) -> some View {
        let (label, color) = eventLabel(event.kind)
        let verdict = isVerdict(event.kind)
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
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

    // MARK: Commits

    private func commits(_ detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail.commits.isEmpty {
                ListEmptyNote(tr("agents.pr.commits.none"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(detail.commits.enumerated()), id: \.element.id) { index, commit in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 20 + NookTheme.Spacing.md) }
                        HoverRow(action: { openCommit(commit.sha, detail: detail) }) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                ChatPersonBadge(name: commit.author, size: 20)
                                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                                    Text(commit.subject).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
                                    HStack(spacing: NookTheme.Spacing.xs) {
                                        Text(commit.shortSHA).font(NookTheme.mono(11))
                                        Text("· @" + commit.author)
                                        if let date = commit.date { Text("· " + AgentFormat.short(now.timeIntervalSince(date))) }
                                    }
                                    .font(NookTheme.TextStyle.detail)
                                    .foregroundStyle(NookTheme.textTertiary)
                                    .lineLimit(1)
                                }
                                Spacer(minLength: 4)
                            }
                        }
                    }
                }
                .panelCard()
            }
        }
    }

    // MARK: Files

    private func files(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail.files.isEmpty {
                ListEmptyNote(tr("agents.pr.files.none"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(detail.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 14 + NookTheme.Spacing.md) }
                        HoverRow(action: { openFile = file.path }) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                fileGlyph(file.status)
                                filePath(file.path)
                                Spacer(minLength: 6)
                                Text("+\(file.additions)").foregroundStyle(NookTheme.mint)
                                Text("−\(file.deletions)").foregroundStyle(NookTheme.coral)
                                DiffStatBar(additions: file.additions, deletions: file.deletions)
                            }
                            .font(NookTheme.TextStyle.detail.monospacedDigit())
                        }
                    }
                }
                .panelCard()
            }
        }
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
                if let index = detail.files.firstIndex(of: file) {
                    Text("\(index + 1)/\(detail.files.count)")
                        .font(NookTheme.TextStyle.detail.monospacedDigit())
                        .foregroundStyle(NookTheme.textTertiary)
                    NookIconButton(systemName: "chevron.up", label: tr("agents.pr.files.previous"), size: 24) {
                        openFile = detail.files[index - 1].path
                    }
                    .disabled(index == 0)
                    .opacity(index == 0 ? 0.35 : 1)
                    NookIconButton(systemName: "chevron.down", label: tr("agents.pr.files.next"), size: 24) {
                        openFile = detail.files[index + 1].path
                    }
                    .disabled(index + 1 >= detail.files.count)
                    .opacity(index + 1 >= detail.files.count ? 0.35 : 1)
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

/// One line of the overview card: a symbol and a name on the left, the state on the right; with `action` the whole
/// line is a button to the tab with the details.
private struct StatusRow<Value: View>: View {
    let symbol: String
    let title: String
    let action: (() -> Void)?
    let value: Value
    @State private var hovering = false

    var body: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
            Image(systemName: symbol).font(NookTheme.font(11, .medium)).foregroundStyle(NookTheme.textTertiary).frame(width: 16)
            Text(title).foregroundStyle(NookTheme.textSecondary)
            Spacer(minLength: NookTheme.Spacing.md)
            value
            if action != nil {
                Image(systemName: "chevron.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
            }
        }
        .font(NookTheme.TextStyle.detail)
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering && action != nil ? NookTheme.rowHover : Color.clear)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            row
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
