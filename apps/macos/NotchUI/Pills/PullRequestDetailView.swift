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

    private var method: PullRequestMergeMethod {
        let chosen = PullRequestMergeMethod(rawValue: methodRaw) ?? .merge
        guard let detail, !detail.methods.contains(chosen) else { return chosen }
        return detail.methods.first ?? chosen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("agents.pr.loadFailed")).font(NookTheme.font(15, .semibold)).foregroundStyle(NookTheme.paper)
                    Text(error)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    NookPrimaryButton(title: tr("agents.pr.retry")) { Task { await load() } }.padding(.top, 4)
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("agents.pr.loading")).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textSecondary)
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: item.id) {
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

    private var header: some View {
        HStack(spacing: 8) {
            NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 28, action: onBack)
                .help(tr("agents.pr.back"))
            Text(item.id)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(NookTheme.textSecondary)
                .lineLimit(1)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            NookIconButton(systemName: "arrow.clockwise", label: tr("agents.pulls.refresh"), size: 28) { Task { await load() } }
                .help(tr("agents.pulls.refresh"))
            if let url = detail?.url ?? item.url {
                NookIconButton(systemName: "arrow.up.right.square", label: tr("agents.pulls.open"), size: 28) { NSWorkspace.shared.open(url) }
                    .help(tr("agents.pulls.open"))
            }
        }
        .frame(height: 30)
    }

    private func summary(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.title)
                .font(NookTheme.font(15, .semibold))
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                stateBadge(detail.state)
                Text("@" + detail.author)
                Text("·")
                Text(detail.headBranch + " → " + detail.baseBranch).font(NookTheme.mono(11.5)).lineLimit(1).truncationMode(.middle)
                Text("·")
                Text("+\(detail.additions)").foregroundStyle(NookTheme.mint)
                Text("−\(detail.deletions)").foregroundStyle(NookTheme.coral)
            }
            .font(NookTheme.font(11.5))
            .foregroundStyle(NookTheme.textTertiary)
        }
    }

    /// The state with the same GitHub mark the agent row's pull request pill uses.
    private func stateBadge(_ state: PullRequestDetail.State) -> some View {
        let color: Color
        let glyph: PullRequestBadge.Glyph
        switch state {
        case .open: (color, glyph) = (NookTheme.mint, .open)
        case .draft: (color, glyph) = (NookTheme.textSecondary, .draft)
        case .merged: (color, glyph) = (NookTheme.violet, .merged)
        case .closed: (color, glyph) = (NookTheme.coral, .closed)
        }
        return HStack(spacing: 3) {
            PullRequestStateGlyph(glyph: glyph, size: 12, lineWidth: 1.6, nodeRadius: 1.8)
            Text(tr("agents.pr.state." + state.rawValue))
        }
        .font(NookTheme.font(11, .semibold))
        .foregroundStyle(color)
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private func tabs(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 0) {
            NookTabBar<Tab>(items: [
                .init(value: Tab.description, title: tr("agents.pr.tab.description")),
                .init(value: Tab.timeline, title: tr("agents.pr.tab.timeline", detail.events.count)),
                .init(value: Tab.commits, title: tr("agents.pr.tab.commits", detail.commits.count)),
                .init(value: Tab.checks, title: tr("agents.pr.tab.checks", detail.checks.count)),
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

    // MARK: Description

    private func description(_ detail: PullRequestDetail) -> some View {
        card {
            if detail.body.isEmpty {
                Text(tr("agents.pr.noDescription")).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary)
            } else {
                MarkdownView(text: detail.body, size: 13)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Timeline

    private func timeline(_ detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let created = detail.created {
                activityRow(symbol: "arrow.triangle.pull", color: NookTheme.mint, author: detail.author,
                            sentence: tr("agents.pr.timeline.opened"), date: created, now: now)
            }
            if detail.events.isEmpty {
                Text(tr("agents.pr.conversation.none")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
            } else {
                ForEach(detail.events) { event in timelineRow(event, detail: detail, now: now) }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Checks

    private func checks(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if detail.checks.isEmpty {
                Text(tr("agents.pr.checks.none")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
            } else {
                ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in checkRow(check) }
            }
        }
        .padding(.bottom, 8)
    }

    private func checkRow(_ check: PullRequestCheck) -> some View {
        Button {
            if let url = check.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                checkGlyph(check.outcome).frame(width: 16)
                Text(check.name).font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.paper).lineLimit(1)
                Text(check.detail).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
                Spacer(minLength: 4)
                if check.url != nil {
                    Image(systemName: "arrow.up.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(check.url == nil)
    }

    @ViewBuilder
    private func checkGlyph(_ outcome: PullRequestCheck.Outcome) -> some View {
        switch outcome {
        case .passing: Image(systemName: "checkmark.circle.fill").font(NookTheme.font(12)).foregroundStyle(NookTheme.mint)
        case .failing: Image(systemName: "xmark.circle.fill").font(NookTheme.font(12)).foregroundStyle(NookTheme.coral)
        case .pending: Circle().fill(NookTheme.amber).frame(width: 7, height: 7)
        case .skipped: Image(systemName: "minus.circle").font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
        }
    }

    /// Commits and events such as a label or the merge take one quiet line; reviews and comments get a card.
    @ViewBuilder
    private func timelineRow(_ event: PullRequestEvent, detail: PullRequestDetail, now: Date) -> some View {
        switch event.kind {
        case .commit(let sha):
            Button {
                if let url = detail.url?.appendingPathComponent("commits/" + sha) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "smallcircle.filled.circle").font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary).frame(width: 16)
                    Text(String(sha.prefix(7))).font(NookTheme.mono(11.5)).foregroundStyle(NookTheme.textSecondary)
                    Text(event.body).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.paper).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("@" + event.author).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary).lineLimit(1)
                    if let date = event.date {
                        Text(AgentFormat.short(now.timeIntervalSince(date))).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        case .activity(let type, let subject):
            let look = activityLook(type)
            activityRow(symbol: look.symbol, color: look.color, author: event.author,
                        sentence: tr("agents.pr.timeline." + type.replacingOccurrences(of: "-", with: "_"), subject), date: event.date, now: now)
        default:
            eventRow(event, now: now)
        }
    }

    private func activityRow(symbol: String, color: Color, author: String, sentence: String, date: Date?, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(NookTheme.font(11)).foregroundStyle(color).frame(width: 16)
            (Text("@" + author + " ").font(NookTheme.font(12.5, .semibold)).foregroundStyle(NookTheme.paper)
                + Text(sentence).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textSecondary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let date {
                Text(AgentFormat.short(now.timeIntervalSince(date))).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
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

    private func eventRow(_ event: PullRequestEvent, now: Date) -> some View {
        let (label, color) = eventLabel(event.kind)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("@" + event.author).font(NookTheme.font(12.5, .semibold)).foregroundStyle(NookTheme.paper)
                Text(label).font(NookTheme.font(12)).foregroundStyle(color).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let date = event.date {
                    Text(AgentFormat.short(now.timeIntervalSince(date))).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
                }
                if let url = event.url {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(tr("agents.pulls.open"))
                }
            }
            if !event.body.isEmpty {
                MarkdownView(text: event.body, size: 12.5)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.rowHover))
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

    // MARK: Commits

    private func commits(_ detail: PullRequestDetail, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if detail.commits.isEmpty {
                Text(tr("agents.pr.commits.none")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
            }
            ForEach(detail.commits) { commit in
                HoverRow(action: { if let url = detail.url?.appendingPathComponent("commits/" + commit.sha) { NSWorkspace.shared.open(url) } }) {
                    HStack(spacing: 10) {
                        Text(commit.shortSHA).font(NookTheme.mono(11.5)).foregroundStyle(NookTheme.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(commit.subject).font(NookTheme.font(13, .medium)).foregroundStyle(NookTheme.paper).lineLimit(1)
                            HStack(spacing: 4) {
                                Text("@" + commit.author)
                                if let date = commit.date { Text("· " + AgentFormat.short(now.timeIntervalSince(date))) }
                            }
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textTertiary)
                        }
                        Spacer(minLength: 4)
                    }
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: Files

    private func files(_ detail: PullRequestDetail) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if detail.files.isEmpty {
                Text(tr("agents.pr.files.none")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textTertiary)
            }
            ForEach(detail.files) { file in
                HoverRow(action: { openFile = file.path }) {
                    HStack(spacing: 10) {
                        fileGlyph(file.status)
                        Text(file.path)
                            .font(NookTheme.mono(12))
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 6)
                        Text("+\(file.additions)").font(NookTheme.font(11.5)).foregroundStyle(NookTheme.mint)
                        Text("−\(file.deletions)").font(NookTheme.font(11.5)).foregroundStyle(NookTheme.coral)
                    }
                }
            }
        }
        .padding(.bottom, 8)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                NookIconButton(systemName: "chevron.left", label: tr("agents.pr.back"), size: 24) { openFile = nil }
                fileGlyph(file.status)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.path).font(NookTheme.mono(12)).foregroundStyle(NookTheme.paper).lineLimit(1).truncationMode(.head)
                    if let previous = file.previousPath {
                        Text(previous + " →").font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 6)
                Text("+\(file.additions)").font(NookTheme.font(11.5)).foregroundStyle(NookTheme.mint)
                Text("−\(file.deletions)").font(NookTheme.font(11.5)).foregroundStyle(NookTheme.coral)
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
        return VStack(alignment: .leading, spacing: 6) {
            if confirmMerge {
                confirmation(detail)
            } else {
                mergeRow(detail, note: note, ready: ready)
            }
            if let mergeError {
                Text(mergeError)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.rowHover))
    }

    /// The confirmation, inside the bar: a system dialog is a window of its own, and on the notch panel its buttons do not
    /// reliably get the click (the merge never ran).
    private func confirmation(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .font(NookTheme.font(13))
                .foregroundStyle(NookTheme.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("agents.pr.confirmTitle", "#\(detail.number)", detail.baseBranch))
                    .font(NookTheme.font(12.5, .semibold))
                    .foregroundStyle(NookTheme.paper)
                Text(confirmMessage)
                    .font(NookTheme.font(12))
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
                .font(NookTheme.font(13))
                .foregroundStyle(ready ? NookTheme.mint : detail.canMerge ? NookTheme.amber : NookTheme.textSecondary)
            Text(tr(note ?? "agents.pr.note.ready"))
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if detail.isOpen && detail.canPush != false && !detail.methods.isEmpty {
                Menu {
                    ForEach(detail.methods) { option in
                        Button(tr(option.titleKey)) { methodRaw = option.rawValue }
                    }
                } label: {
                    Text(tr(method.titleKey)).font(NookTheme.font(12))
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

    private func load() async {
        guard !loading else { return }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            error = tr("agents.pr.noToken")
            return
        }
        loading = true
        defer { loading = false }
        do {
            // Not tied to the view: leaving the pull request halfway must not end the load as a failed one.
            let repo = item.repo, number = item.number
            let fresh = try await Task { try await GitHubPullRequestDetail.load(repo: repo, number: number, token: token) }.value
            detail = fresh
            error = nil
            if let path = openFile, !fresh.files.contains(where: { $0.path == path }) { openFile = nil }
        } catch {
            // A failed refresh keeps what was shown, quietly: the next one is half a minute away.
            if detail == nil { self.error = error.localizedDescription }
        }
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
                merging = false
                PullRequestStore.shared.markStale()
                await load()
                await PullRequestStore.shared.refresh(force: true)
            } catch {
                app.store.audit(tool: "github_merge_pr", args: args, result: "error: " + error.localizedDescription)
                mergeError = error.localizedDescription
                merging = false
            }
        }
    }

    // MARK: Pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.rowHover))
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
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(hovering ? NookTheme.rowHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
