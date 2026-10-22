import AppKit
import SwiftUI

/// One pull request, read in full inside Nook: the description, the timeline, the commits, the checks, and every
/// changed file with its diff. The bar at the bottom merges it, after you confirm, with the account it was listed under.
struct PullRequestDetailView: View {
    @EnvironmentObject private var app: AppModel
    let accountID: String
    let item: PullRequestItem
    let onBack: () -> Void

    enum Tab: Hashable { case description, timeline, commits, checks, files }

    @State private var detail: PullRequestDetail?
    @State private var loading = false
    @State private var error: String?
    @State private var tab: Tab = .description
    @State private var openFile: String?
    @AppStorage("agents.pr.mergeMethod") private var methodRaw = PullRequestMergeMethod.merge.rawValue
    @State private var confirmMerge = false
    @State private var merging = false
    @State private var mergeError: String?
    /// Merged from this view: GitHub's answer already said so, so a load that started before the merge (or reads a
    /// replica that has not caught up) cannot turn it back to open.
    @State private var mergedHere = false
    /// A load was asked for while one ran: it runs again right after, so the merge shows in the timeline too.
    @State private var reloadAgain = false

    private var method: PullRequestMergeMethod {
        let chosen = PullRequestMergeMethod(rawValue: methodRaw) ?? .merge
        guard let detail, !detail.methods.contains(chosen) else { return chosen }
        return detail.methods.first ?? chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header
            if let detail {
                summary(detail)
                tabs(detail)
                // The relative times in the timeline and the commits tick along, once a minute.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    content(detail, now: context.date)
                }
                mergeBar(detail)
            } else if let error {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    Text(tr("agents.pr.loadFailed")).font(NookTheme.TextStyle.title).foregroundStyle(NookTheme.paper)
                    Text(error)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    NookPrimaryButton(title: tr("agents.pr.retry")) { Task { await load() } }.padding(.top, NookTheme.Spacing.xs)
                }
                .padding(.top, NookTheme.Spacing.md)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: NookTheme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text(tr("agents.pr.loading")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                }
                .padding(.top, NookTheme.Spacing.md)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) {
            mergedHere = false
            await load()
            // GitHub works out mergeability after the first ask: look again once it has.
            if let detail, detail.isOpen, detail.mergeable == nil {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { await load() }
            }
            // New commits, checks and comments come in while it is open: look again every half minute.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if !Task.isCancelled, !merging { await load() }
            }
        }
    }

    // MARK: Header

    /// Back on the left, the pull request's own actions on the right; the title block sits under it.
    private var header: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Button(action: onBack) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    Image(systemName: "chevron.left").font(NookTheme.font(11, .semibold))
                    Text(tr("agents.pr.back")).font(NookTheme.TextStyle.label)
                }
                .foregroundStyle(NookTheme.textSecondary)
                .padding(.horizontal, NookTheme.Spacing.sm)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help(tr("agents.pr.back"))
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) { Task { await load() } }
            if let url = detail?.url ?? item.url {
                NookIconButton(systemName: "arrow.up.right.square", label: tr("agents.pulls.open"), size: 28) { NSWorkspace.shared.open(url) }
            }
        }
        .frame(height: 30)
    }

    /// "owner/repo #123", the title, then who wants to merge what into what, and how big it is.
    private func summary(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(detail.repo + "  #\(detail.number)")
                .font(NookTheme.TextStyle.label.monospacedDigit())
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(detail.title)
                .font(NookTheme.TextStyle.heading)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: NookTheme.Spacing.sm) {
                PullRequestStateBadge(glyph: PullRequestBadge.Glyph(rawValue: detail.state.rawValue) ?? .open)
                Text("@" + detail.author).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                    .layoutPriority(1)
                Text(tr("agents.pr.wantsToMerge")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                BranchChip(name: detail.baseBranch)
                Image(systemName: "arrow.left").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
                BranchChip(name: detail.headBranch)
            }
            .lineLimit(1)
        }
    }

    private func tabs(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 0) {
            NookTabBar<Tab>(items: [
                .init(value: Tab.description, title: tr("agents.pr.tab.description")),
                .init(value: Tab.timeline, title: tr("agents.pr.tab.timeline", detail.events.count)),
                .init(value: Tab.commits, title: tr("agents.pr.tab.commits", detail.commits.count)),
                .init(value: Tab.checks, title: tr("agents.pr.tab.checks", detail.checks.count)),
                .init(value: Tab.files, title: tr("agents.pr.tab.files", max(detail.changedFiles, detail.files.count))),
            ], selected: tab) { value in show(value) }
            Spacer()
        }
    }

    private func show(_ value: Tab) {
        withAnimation(NookTheme.swap) { tab = value }
        if value != .files { openFile = nil }
    }

    @ViewBuilder
    private func content(_ detail: PullRequestDetail, now: Date) -> some View {
        switch tab {
        case .description:
            ScrollView(showsIndicators: false) { description(detail).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity)
        case .timeline:
            ScrollView(showsIndicators: false) { timeline(detail, now: now).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity)
        case .commits:
            ScrollView(showsIndicators: false) { commits(detail, now: now).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity)
        case .checks:
            ScrollView(showsIndicators: false) { checks(detail).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: .infinity)
        case .files:
            if let path = openFile, let file = detail.files.first(where: { $0.path == path }) {
                fileDiff(file, detail: detail)
            } else {
                ScrollView(showsIndicators: false) { files(detail).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: Description and overview

    /// The overview first (checks, review, commits, changes: each opens its tab), then the description.
    private func description(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            overview(detail)
            VStack(alignment: .leading, spacing: 0) {
                if detail.body.isEmpty {
                    Text(tr("agents.pr.noDescription")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textTertiary)
                } else {
                    MarkdownView(text: detail.body, size: 13.5)
                }
            }
            .padding(NookTheme.Spacing.lg + NookTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelCard()
        }
        .padding(.bottom, NookTheme.Spacing.md)
    }

    private func overview(_ detail: PullRequestDetail) -> some View {
        let review = reviewSummary(detail)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NookTheme.Spacing.sm)], alignment: .leading,
                         spacing: NookTheme.Spacing.sm) {
            OverviewTile(title: tr("agents.pr.overview.checks"), value: checksLine(detail), tint: checksTint(detail)) {
                ciGlyph(detail.checkSummary)
            } action: { show(.checks) }
            OverviewTile(title: tr("agents.pr.overview.review"), value: review.text, tint: review.tint) {
                Image(systemName: review.symbol).font(NookTheme.font(12, .medium)).foregroundStyle(review.tint)
            } action: { show(.timeline) }
            OverviewTile(title: tr("agents.pr.overview.commits"), value: tr("agents.pr.overview.commitsCount", detail.commits.count),
                         tint: NookTheme.paper) {
                Image(systemName: "smallcircle.filled.circle").font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
            } action: { show(.commits) }
            OverviewTile(title: tr("agents.pr.overview.changes"),
                         value: tr("agents.pr.overview.filesCount", max(detail.changedFiles, detail.files.count)), tint: NookTheme.paper) {
                DiffStatBar(additions: detail.additions, deletions: detail.deletions)
            } action: { show(.files) }
        }
    }

    /// "2 failing", "1 running", "12 passing": the worst news first, in one short line.
    private func checksLine(_ detail: PullRequestDetail) -> String {
        let failing = detail.checks.filter { $0.outcome == .failing }.count
        let running = detail.checks.filter { $0.outcome == .pending }.count
        let passing = detail.checks.filter { $0.outcome == .passing }.count
        if detail.checks.isEmpty { return tr("agents.pr.checks.none") }
        if failing > 0 { return tr("agents.pr.checks.failing", failing) }
        if running > 0 { return tr("agents.pr.checks.running", running) }
        return tr("agents.pr.checks.passing", passing)
    }

    private func checksTint(_ detail: PullRequestDetail) -> Color {
        switch detail.checkSummary {
        case .failing: return NookTheme.coralSoft
        case .passing: return NookTheme.paper
        case .pending, .unknown: return NookTheme.textSecondary
        }
    }

    @ViewBuilder
    private func ciGlyph(_ ci: PullRequestItem.CI) -> some View {
        switch ci {
        case .passing: CheckOutcomeGlyph(outcome: .passing)
        case .failing: CheckOutcomeGlyph(outcome: .failing)
        case .pending: CheckOutcomeGlyph(outcome: .pending)
        case .unknown: CheckOutcomeGlyph(outcome: .skipped)
        }
    }

    /// Where the reviews stand: each reviewer's latest verdict counts; a request for changes outweighs approvals.
    private func reviewSummary(_ detail: PullRequestDetail) -> (text: String, symbol: String, tint: Color) {
        var latest: [String: String] = [:]
        var order: [String] = []
        for event in detail.events {
            guard case .review(let state) = event.kind, state != "DISMISSED" else { continue }
            // A plain comment does not replace a verdict the reviewer gave before.
            if state == "COMMENTED", let earlier = latest[event.author], earlier != "COMMENTED" { continue }
            if latest[event.author] == nil { order.append(event.author) }
            latest[event.author] = state
        }
        func names(_ state: String) -> String {
            order.filter { latest[$0] == state }.map { "@" + $0 }.joined(separator: ", ")
        }
        if latest.values.contains("CHANGES_REQUESTED") {
            return (tr("agents.pr.review.changes", names("CHANGES_REQUESTED")), "exclamationmark.bubble.fill", NookTheme.coralSoft)
        }
        if latest.values.contains("APPROVED") {
            return (tr("agents.pr.review.approved", names("APPROVED")), "checkmark.bubble.fill", NookTheme.mint)
        }
        if latest.values.contains("COMMENTED") {
            return (tr("agents.pr.review.commented", names("COMMENTED")), "text.bubble", NookTheme.paper)
        }
        return (tr("agents.pr.review.none"), "bubble.left", NookTheme.textSecondary)
    }

    // MARK: Timeline

    /// One line through the pull request's history, from opening to now: small marks on a thin rail, comments and
    /// reviews as cards beside it.
    private func timeline(_ detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let created = detail.created {
                activityRow(symbol: "arrow.triangle.pull", color: NookTheme.textSecondary, author: detail.author,
                            sentence: tr("agents.pr.timeline.opened"), date: created, now: now)
            }
            if detail.events.isEmpty {
                ListEmptyNote(tr("agents.pr.conversation.none"))
            } else {
                ForEach(detail.events) { event in timelineRow(event, detail: detail, now: now) }
            }
        }
        .background(alignment: .leading) {
            NookDivider(vertical: true)
                .padding(.vertical, NookTheme.Spacing.md)
                .padding(.leading, TimelineMark.size / 2)
        }
        .padding(.bottom, NookTheme.Spacing.md)
    }

    /// Commits and events such as a label or the merge take one quiet line; reviews and comments get a card.
    @ViewBuilder
    private func timelineRow(_ event: PullRequestEvent, detail: PullRequestDetail, now: Date) -> some View {
        switch event.kind {
        case .commit(let sha):
            Button {
                if let url = detail.url?.appendingPathComponent("commits/" + sha) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: NookTheme.Spacing.md) {
                    TimelineMark(symbol: "smallcircle.filled.circle", color: NookTheme.textTertiary)
                    Text(event.body).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textStrong).lineLimit(1)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    Text(String(sha.prefix(7))).font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary)
                    if let date = event.date {
                        Text(AgentFormat.short(now.timeIntervalSince(date))).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("@" + event.author)
        case .activity(let type, let subject):
            let look = activityLook(type)
            activityRow(symbol: look.symbol, color: look.color, author: event.author,
                        sentence: tr("agents.pr.timeline." + type.replacingOccurrences(of: "-", with: "_"), subject), date: event.date, now: now)
        default:
            eventRow(event, now: now)
        }
    }

    private func activityRow(symbol: String, color: Color, author: String, sentence: String, date: Date?, now: Date) -> some View {
        HStack(alignment: .center, spacing: NookTheme.Spacing.md) {
            TimelineMark(symbol: symbol, color: color)
            (Text("@" + author + " ").font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textStrong)
                + Text(sentence).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: NookTheme.Spacing.xs)
            if let date {
                Text(AgentFormat.short(now.timeIntervalSince(date))).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            }
        }
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
        case "closed": return ("xmark", NookTheme.coral)
        case "reopened": return ("arrow.uturn.left", NookTheme.textSecondary)
        case "cross-referenced", "referenced": return ("link", NookTheme.textTertiary)
        case "milestoned", "demilestoned": return ("flag", NookTheme.textTertiary)
        case "auto_merge_enabled", "auto_merge_disabled": return ("bolt", NookTheme.textTertiary)
        case "review_dismissed": return ("xmark.bubble", NookTheme.textTertiary)
        default: return ("circle", NookTheme.textTertiary)
        }
    }

    /// A comment or a review: its mark on the rail, and a card with who, what and when over the text.
    private func eventRow(_ event: PullRequestEvent, now: Date) -> some View {
        let look = eventLook(event.kind)
        return HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            TimelineMark(symbol: look.symbol, color: look.color)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text("@" + event.author).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                    Text(look.label).font(NookTheme.TextStyle.detail).foregroundStyle(look.labelColor)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: NookTheme.Spacing.xs)
                    if let date = event.date {
                        Text(AgentFormat.short(now.timeIntervalSince(date))).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                    }
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
    }

    /// The mark, its color, and the words after the author: a verdict keeps its color, a comment stays neutral.
    private func eventLook(_ kind: PullRequestEvent.Kind) -> (symbol: String, color: Color, label: String, labelColor: Color) {
        switch kind {
        case .comment: return ("text.bubble", NookTheme.textTertiary, tr("agents.pr.event.comment"), NookTheme.textTertiary)
        case .commit, .activity: return ("circle", NookTheme.textTertiary, "", NookTheme.textTertiary)
        case .lineComment(let path, let line):
            return ("text.bubble", NookTheme.textTertiary,
                    tr("agents.pr.event.line", line.map { "\(path):\($0)" } ?? path), NookTheme.textTertiary)
        case .review(let state):
            switch state {
            case "APPROVED": return ("checkmark", NookTheme.mint, tr("agents.pr.event.approved"), NookTheme.mint)
            case "CHANGES_REQUESTED": return ("exclamationmark", NookTheme.coral, tr("agents.pr.event.changes"), NookTheme.coralSoft)
            case "DISMISSED": return ("xmark", NookTheme.textTertiary, tr("agents.pr.event.dismissed"), NookTheme.textTertiary)
            default: return ("eye", NookTheme.textTertiary, tr("agents.pr.event.reviewed"), NookTheme.textTertiary)
            }
        }
    }

    // MARK: Checks

    /// What failed first, then what still runs, then the rest; one line on top says where they stand.
    private func checks(_ detail: PullRequestDetail) -> some View {
        let failing = detail.checks.filter { $0.outcome == .failing }
        let running = detail.checks.filter { $0.outcome == .pending }
        let rest = detail.checks.filter { $0.outcome == .passing || $0.outcome == .skipped }
        return VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if detail.checks.isEmpty {
                ListEmptyNote(tr("agents.pr.checks.none"))
            } else {
                HStack(spacing: NookTheme.Spacing.md) {
                    ciGlyph(detail.checkSummary)
                    Text(checkCounts(detail)).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                ForEach(Array([failing, running, rest].filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, group in
                    VStack(spacing: 0) {
                        ForEach(Array(group.enumerated()), id: \.offset) { index, check in
                            if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 16 + NookTheme.Spacing.md) }
                            CheckRow(check: check)
                        }
                    }
                    .panelCard()
                }
            }
        }
        .padding(.bottom, NookTheme.Spacing.md)
    }

    /// "2 failing · 1 running · 12 passing · 1 skipped", only the parts that are there.
    private func checkCounts(_ detail: PullRequestDetail) -> String {
        let counts: [(PullRequestCheck.Outcome, String)] = [(.failing, "failing"), (.pending, "running"), (.passing, "passing"), (.skipped, "skipped")]
        var parts: [String] = []
        for (outcome, key) in counts {
            let count = detail.checks.filter { $0.outcome == outcome }.count
            if count > 0 { parts.append(tr("agents.pr.checks." + key, count)) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Commits

    private func commits(_ detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if detail.commits.isEmpty {
                ListEmptyNote(tr("agents.pr.commits.none"))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(detail.commits.enumerated()), id: \.element.id) { index, commit in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg) }
                        HoverRow(action: { if let url = detail.url?.appendingPathComponent("commits/" + commit.sha) { NSWorkspace.shared.open(url) } }) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                                    Text(commit.subject).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper).lineLimit(1)
                                    Text(commitMeta(commit, now: now))
                                        .font(NookTheme.TextStyle.detail)
                                        .foregroundStyle(NookTheme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: NookTheme.Spacing.xs)
                                Text(commit.shortSHA).font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary)
                            }
                        }
                    }
                }
                .panelCard()
            }
        }
        .padding(.bottom, NookTheme.Spacing.md)
    }

    private func commitMeta(_ commit: PullRequestCommit, now: Date) -> String {
        guard let date = commit.date else { return "@" + commit.author }
        return "@" + commit.author + " · " + AgentFormat.short(now.timeIntervalSince(date))
    }

    // MARK: Files

    /// How much changed in one line on top, then every file: its name first, the folder quieter, and how much changed.
    private func files(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if detail.files.isEmpty {
                ListEmptyNote(tr("agents.pr.files.none"))
            } else {
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("agents.pr.overview.filesCount", max(detail.changedFiles, detail.files.count)))
                        .font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                    DiffCounts(additions: detail.additions, deletions: detail.deletions)
                    DiffStatBar(additions: detail.additions, deletions: detail.deletions)
                }
                .padding(.horizontal, NookTheme.Spacing.xs)
                VStack(spacing: 0) {
                    ForEach(Array(detail.files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { NookDivider(inset: NookTheme.Spacing.lg + 14 + NookTheme.Spacing.md) }
                        HoverRow(action: { openFile = file.path }) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                fileGlyph(file.status)
                                FilePathText(path: file.path)
                                Spacer(minLength: NookTheme.Spacing.sm)
                                DiffCounts(additions: file.additions, deletions: file.deletions)
                            }
                        }
                    }
                }
                .panelCard()
            }
        }
        .padding(.bottom, NookTheme.Spacing.md)
    }

    private func fileGlyph(_ status: String) -> some View {
        let letter: String
        let color: Color
        switch status {
        case "added": letter = "A"; color = NookTheme.mint
        case "removed": letter = "D"; color = NookTheme.coral
        case "renamed", "copied": letter = "R"; color = NookTheme.blue
        default: letter = "M"; color = NookTheme.textSecondary
        }
        return Text(letter).font(NookTheme.mono(11, .semibold)).foregroundStyle(color).frame(width: 14)
    }

    private func fileDiff(_ file: PullRequestFile, detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24) { openFile = nil }
                fileGlyph(file.status)
                VStack(alignment: .leading, spacing: 1) {
                    FilePathText(path: file.path)
                    if let previous = file.previousPath {
                        Text(previous + " →").font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                DiffCounts(additions: file.additions, deletions: file.deletions)
                if let index = detail.files.firstIndex(of: file) {
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
                    .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
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
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .cardBackground(NookTheme.surface, stroke: mergeTone(detail, ready: ready).opacity(0.3),
                        radius: NookTheme.Radius.panel, style: .continuous)
    }

    /// The bar's edge says where the merge stands: mint when it is ready, amber when something needs you, neutral when
    /// it is closed or merged.
    private func mergeTone(_ detail: PullRequestDetail, ready: Bool) -> Color {
        if confirmMerge { return NookTheme.amber }
        if !detail.isOpen { return NookTheme.line2 }
        return ready ? NookTheme.mint : NookTheme.amber
    }

    /// The confirmation, inside the bar: a system dialog is a window of its own, and on the notch panel its buttons do not
    /// reliably get the click (the merge never ran).
    private func confirmation(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
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
            Spacer(minLength: NookTheme.Spacing.sm)
            NookGhostButton(title: tr("button.cancel")) { confirmMerge = false }
            NookPrimaryButton(title: tr("agents.pr.confirmButton")) {
                confirmMerge = false
                merge()
            }
        }
    }

    private func mergeRow(_ detail: PullRequestDetail, note: String?, ready: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: ready ? "checkmark.circle.fill" : detail.canMerge ? "exclamationmark.triangle.fill" : "info.circle")
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(ready ? NookTheme.mint : detail.canMerge ? NookTheme.amber : NookTheme.textSecondary)
            Text(tr(note ?? "agents.pr.note.ready"))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(ready ? NookTheme.paper : NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: NookTheme.Spacing.sm)
            if detail.isOpen && detail.canPush != false && !detail.methods.isEmpty {
                Menu {
                    ForEach(detail.methods) { option in
                        Button(tr(option.titleKey)) { methodRaw = option.rawValue }
                    }
                } label: {
                    Text(tr(method.titleKey)).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                }
                .help(tr(method.titleKey))
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

    private func load() async {
        guard !loading else {
            reloadAgain = true
            return
        }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            error = tr("agents.pr.noToken")
            return
        }
        loading = true
        defer { loading = false }
        repeat {
            reloadAgain = false
            do {
                // Not tied to the view: leaving the pull request halfway must not end the load as a failed one.
                let repo = item.repo, number = item.number
                var fresh = try await Task { try await GitHubPullRequestDetail.load(repo: repo, number: number, token: token) }.value
                if mergedHere, fresh.isOpen { fresh.state = .merged }
                detail = fresh
                error = nil
                if let path = openFile, !fresh.files.contains(where: { $0.path == path }) { openFile = nil }
            } catch {
                // A failed refresh keeps what was shown, quietly: the next one is half a minute away.
                if detail == nil { self.error = error.localizedDescription }
            }
        } while reloadAgain && !Task.isCancelled
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
        mergeError = nil
        Task {
            do {
                let sha = try await GitHubPullRequestDetail.merge(repo: detail.repo, number: detail.number, method: method,
                                                                  sha: detail.headSHA, token: token)
                app.store.audit(tool: "github_merge_pr", args: args, result: "merged" + (sha.isEmpty ? "" : " " + String(sha.prefix(7))))
                settle(detail)
                await load()
                await PullRequestStore.shared.refresh(force: true)
            } catch {
                app.store.audit(tool: "github_merge_pr", args: args, result: "error: " + error.localizedDescription)
                merging = false
                // The answer can get lost (a timeout) after GitHub merged after all: look before calling it failed.
                await load()
                if self.detail?.state == .merged {
                    settle(detail)
                    await PullRequestStore.shared.refresh(force: true)
                } else {
                    mergeError = error.localizedDescription
                }
            }
        }
    }

    /// Shows the merge at once, here, in the list and on the agent rows, without waiting for GitHub's next answers.
    private func settle(_ merged: PullRequestDetail) {
        mergedHere = true
        merging = false
        mergeError = nil
        detail?.state = .merged
        PullRequestStore.shared.markMerged(merged.id)
        PullRequestSync.shared.markMerged(repository: merged.repo, number: merged.number)
    }
}

/// A full-width row inside a card that lights up under the pointer.
private struct HoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, NookTheme.Spacing.lg)
                .padding(.vertical, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
                .background(hovering ? NookTheme.rowHover : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// A branch name as a small mono chip, cut in the middle when it is long.
private struct BranchChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(NookTheme.mono(11))
            .foregroundStyle(NookTheme.textStrong)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.smoke))
            .help(name)
    }
}

/// One fact of the overview (checks, review, commits, changes): a quiet title, a mark and one line; a click opens the
/// tab with the whole story.
private struct OverviewTile<Mark: View>: View {
    let title: String
    let value: String
    var tint: Color = NookTheme.paper
    @ViewBuilder var mark: () -> Mark
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Text(title).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
                HStack(spacing: NookTheme.Spacing.sm) {
                    mark()
                    Text(value)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous)
                .fill(hovering ? NookTheme.graphite : NookTheme.field))
            .contentShape(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(value)
    }
}

/// A mark on the timeline's rail: a small disc that covers the rail behind it, with the event's symbol.
private struct TimelineMark: View {
    static let size: CGFloat = 22
    let symbol: String
    var color: Color = NookTheme.textTertiary

    var body: some View {
        Image(systemName: symbol)
            .font(NookTheme.font(9.5, .semibold))
            .foregroundStyle(color)
            .frame(width: Self.size, height: Self.size)
            .background(Circle().fill(NookTheme.surface))
    }
}

/// One check: how it went, its name, GitHub's word for it, and the way to its page under the pointer.
private struct CheckRow: View {
    let check: PullRequestCheck
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = check.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: NookTheme.Spacing.md) {
                CheckOutcomeGlyph(outcome: check.outcome).frame(width: 16)
                Text(check.name)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(check.outcome == .skipped ? NookTheme.textSecondary : NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: NookTheme.Spacing.xs)
                Text(check.detail).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
                if check.url != nil {
                    Image(systemName: "arrow.up.right")
                        .font(NookTheme.font(9, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .opacity(hovering ? 1 : 0)
                }
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .background(hovering && check.url != nil ? NookTheme.rowHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
        .onHover { hovering = $0 }
        .help(check.name)
    }
}

/// "+12 −3" in the diff colors, with tabular digits so a column of them lines up.
private struct DiffCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text("+\(additions)").foregroundStyle(NookTheme.mint)
            Text("−\(deletions)").foregroundStyle(NookTheme.coralSoft)
        }
        .font(NookTheme.TextStyle.caption.monospacedDigit())
        .fixedSize()
    }
}

/// Five small blocks that show the share of added and removed lines at a glance, as GitHub does.
private struct DiffStatBar: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        let total = additions + deletions
        let added = total == 0 ? 0 : Int((Double(additions) / Double(total) * 5).rounded())
        let removed = total == 0 ? 0 : min(5 - added, Int((Double(deletions) / Double(total) * 5).rounded()))
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index < added ? NookTheme.mint : index < added + removed ? NookTheme.coralSoft : NookTheme.line2)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A changed file's name in full, with its folder before it in a quieter tone; a long folder gives way first.
private struct FilePathText: View {
    let path: String

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let folder = String(path.dropLast(name.count))
        HStack(spacing: 0) {
            if !folder.isEmpty {
                Text(folder)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Text(name)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(NookTheme.TextStyle.code)
        .help(path)
    }
}
