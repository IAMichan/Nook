import AppKit
import SwiftUI

/// The side panel's Pull request tab before one is open: a search, then the session's own pull requests (the ones of its
/// branches and the ones you linked, chains indented), then the rest to open beside it: yours, the ones waiting for your
/// review and the watched ones, from every GitHub account (`PullRequestStore`). A click opens it in the tab; a line at the
/// bottom says how many are open and linked and when they were last read, with the button that links another.
struct SidePanelPullRequestPicker: View {
    let directory: String
    let runID: UUID?
    let choose: (PullRequestOpenRequest) -> Void
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var store = PullRequestStore.shared
    @ObservedObject private var sync = PullRequestSync.shared
    @StateObject private var git: FolderGitModel
    /// The same search and Filters as the Pull requests page (open ones by default); a change in one applies to both.
    @ObservedObject private var filterStore = PullRequestFilterStore.shared
    private var filter: PullRequestFilter { filterStore.filter }
    @ObservedObject private var watching = PullRequestWatchSettings.shared
    /// The field that links a pull request, open under the list.
    @State private var linking = false
    @State private var linkText = ""
    @State private var linkError: String?
    @State private var linkBusy = false
    @FocusState private var linkFocused: Bool

    init(directory: String, runID: UUID? = nil, choose: @escaping (PullRequestOpenRequest) -> Void) {
        self.directory = directory
        self.runID = runID
        self.choose = choose
        _git = StateObject(wrappedValue: FolderGitModel.make(directory: directory))
    }

    /// One group of the list: its heading and its pull requests with the account each is read with.
    private struct PickGroup: Identifiable {
        let id: String
        let title: String
        let role: PullRequestRepoGroup.Role
        let items: [PullRequestOpenRequest]
    }

    private var sessionKey: String { PullRequestSync.sessionKey(run: runID, directory: directory) }
    private var linked: [LinkedPullRequest] { sync.linked(run: runID, directory: directory, branch: git.status?.branch) }

    /// What the store lists, for a linked pull request: it knows the checks, the author and the size.
    private func listed(_ link: PullRequestLink) -> PullRequestOpenRequest? {
        let key = "\(link.repository)#\(link.number)".lowercased()
        return store.accounts.lazy.compactMap { account in
            (account.mine + account.reviews + account.watched).first { $0.id.lowercased() == key }
                .map { PullRequestOpenRequest(account: account.id, item: $0) }
        }.first
    }

    private func groups(excluding linked: Set<String>) -> [PickGroup] {
        let branch = git.status?.branch ?? ""
        var seen = linked
        func take(_ pick: (AccountPullRequests) -> [PullRequestItem]) -> [PullRequestOpenRequest] {
            filter.apply(store.accounts).flatMap { account in pick(account).map { PullRequestOpenRequest(account: account.id, item: $0) } }
                .filter { seen.insert($0.item.id.lowercased()).inserted }
        }
        // What the store lists for this branch and the session's sync has not seen: a session Nook does not follow.
        let onBranch = branch.isEmpty ? [] : take { ($0.mine + $0.reviews + $0.watched).filter { $0.headBranch == branch } }
        return [
            PickGroup(id: "branch", title: tr("agents.pr.pick.branch", branch), role: .mine, items: onBranch),
            PickGroup(id: "mine", title: tr("agents.pr.pick.mine"), role: .mine, items: take(\.mine)),
            PickGroup(id: "reviews", title: tr("agents.pr.pick.reviews"), role: .review, items: take(\.reviews)),
            PickGroup(id: "watched", title: tr("agents.pr.pick.watched"), role: .watched, items: take(\.watched)),
        ].filter { !$0.items.isEmpty }
    }

    /// Every pull request of one account, for where one stands in a stack.
    private func items(of account: String) -> [PullRequestItem] {
        guard let found = store.accounts.first(where: { $0.id == account }) else { return [] }
        return found.reviews + found.mine + found.watched
    }

    var body: some View {
        let all = linked
        // While a search or filter narrows the list, the session's own pull requests go through it too.
        let matching = filter.isActive ? Set(filter.apply(store.accounts).flatMap { $0.mine + $0.reviews + $0.watched }.map { $0.id.lowercased() }) : nil
        let shownLines = matching.map { keep in all.filter { keep.contains("\($0.link.repository)#\($0.link.number)".lowercased()) } } ?? all
        let groups = groups(excluding: Set(all.map { "\($0.link.repository)#\($0.link.number)".lowercased() }))
        // Where each pull request stands in a stack, per account, worked out once instead of once per row.
        let stacks = Dictionary(store.accounts.map { ($0.id, PullRequestStack.positions(in: items(of: $0.id))) },
                                uniquingKeysWith: { first, _ in first })
        VStack(spacing: 0) {
            PullRequestSearchBar(filter: $filterStore.filter, accounts: store.accounts, prompt: tr("agents.pr.pick.search"),
                                 watching: !watching.entries.isEmpty, style: .inline) {
                // As on the Pull requests page: only a refresh you asked for (or a first load) turns it.
                RefreshIconButton(label: tr("agents.pulls.refresh"), turning: store.showsProgress) {
                    Task { await store.refresh(force: true) }
                }
            }
                .padding(NookTheme.Spacing.sm)
            // The same chips as on the Pull requests page, on the same filter.
            PullRequestAttentionBar(filter: $filterStore.filter, accounts: store.accounts)
                .padding(.horizontal, NookTheme.Spacing.sm).padding(.bottom, NookTheme.Spacing.sm)
            PullRequestCloseSweepBar().padding(.horizontal, NookTheme.Spacing.sm).padding(.bottom, NookTheme.Spacing.sm)
            NookDivider()
            ScrollView {
                TimelineView(.nookTicks(every: 30)) { context in
                    LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        if !shownLines.isEmpty {
                            NookSectionLabel(tr("agents.pr.linked.title"), inset: NookTheme.Spacing.sm)
                                .padding(.top, NookTheme.Spacing.md)
                            ForEach(shownLines) { line in row(line, now: context.date) }
                        } else if all.isEmpty, !filter.isActive {
                            emptyNote
                        }
                        ForEach(groups) { group in
                            NookSectionLabel(group.title, inset: NookTheme.Spacing.sm)
                                .padding(.top, NookTheme.Spacing.md)
                            ForEach(group.items, id: \.item.id) { request in
                                if request.item.id != group.items.first?.item.id { NookRowSeparator() }
                                PullRequestRow(item: request.item, role: group.role, showRepo: true, accountID: request.account,
                                               stack: stacks[request.account]?[request.item.id], now: context.date) {
                                    choose(request)
                                }
                            }
                        }
                        if groups.isEmpty, shownLines.isEmpty, filter.isActive {
                            StackedDiffNote(text: tr("agents.pr.pick.noMatch"))
                        } else if groups.isEmpty, store.loading, !store.loaded {
                            PatientSpinner()
                        } else if !GitHubPullRequestList.isAvailable {
                            StackedDiffNote(text: tr("agents.pr.pick.unavailable"))
                        }
                    }
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.bottom, NookTheme.Spacing.md)
                }
            }
            // ⇧- or ⌘-clicked rows: merge or close them together. It floats over the list with nothing behind it, so
            // the rows stay in sight, and the last ones scroll clear of it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PullRequestSelectionBar(shown: groups.flatMap(\.items), inset: NookTheme.Spacing.sm)
            }
            NookDivider()
            footer(all)
        }
        .task {
            await git.refresh()
            await store.refresh()
        }
    }

    // MARK: Rows

    private func row(_ line: LinkedPullRequest, now: Date) -> some View {
        let link = line.link
        let request = listed(link)
        let url = URL(string: link.url)
        let watchable = runID != nil && (url.map(PullRequestWatch.canWatch) ?? false)
        let info = PullRequestRowLink(source: Self.sourceText(line.source), depth: line.depth, stackSize: line.stackSize,
                                      watching: watchable ? runID.flatMap { id in url.map { workspace.isWatching(id, url: $0) } } : nil,
                                      removeTitle: tr(line.source == .you ? "agents.pr.linked.unlink" : "agents.pr.linked.dismiss"))
        return PullRequestRow(item: Self.item(link, listed: request?.item), role: .mine, showRepo: true,
                              accountID: request?.account ?? "", now: now, linked: info,
                              onWatch: watchable ? { toggleWatch(link, url: url) } : nil,
                              onRemove: { sync.remove(link, session: sessionKey) },
                              readable: request != nil) {
            open(link)
        }
    }

    /// The row a link draws: what the store lists, with the state the link was last read at; only the link when nobody
    /// lists it (a merged one, another forge).
    static func item(_ link: PullRequestLink, listed: PullRequestItem?) -> PullRequestItem {
        var item = listed ?? PullRequestItem(repo: link.repository, number: link.number, title: link.title ?? link.repository,
                                             url: URL(string: link.url), draft: false, updated: link.updatedAt, author: "")
        item.draft = link.state == .draft
        item.state = switch link.state {
        case .draft, .open: .open
        case .merged: .merged
        case .closed: .closed
        }
        item.conflict = link.state.isOpen && link.conflicted
        if item.headBranch.isEmpty { item.headBranch = link.headBranch ?? "" }
        if item.baseBranch.isEmpty { item.baseBranch = link.baseBranch ?? "" }
        return item
    }

    private static func sourceText(_ source: LinkedPullRequest.Source) -> String {
        switch source {
        case .branch: tr("agents.pr.linked.source.branch")
        case .earlierBranch: tr("agents.pr.linked.source.earlier")
        case .you: tr("agents.pr.linked.source.you")
        }
    }

    private func open(_ link: PullRequestLink) {
        guard let url = URL(string: link.url) else { return }
        if let request = AppModel.shared.pullRequestRequest(for: url) {
            choose(request)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private func toggleWatch(_ link: PullRequestLink, url: URL?) {
        guard let runID, let url else { return }
        if workspace.isWatching(runID, url: url) {
            workspace.stopWatchingPullRequest(runID, url: url)
        } else {
            workspace.watchPullRequest(runID, url: url)
        }
    }

    // MARK: Empty and footer

    private var emptyNote: some View {
        WSEmptyState(symbol: PullRequestIcon.generic, title: tr("agents.pr.linked.empty.title"),
                     message: tr("agents.pr.linked.empty.detail")) {
            SmallGhostButton(title: tr("agents.pr.linked.add")) { startLinking() }
        }
    }

    /// "2 open · 3 linked · read 2 m ago", the button that links another, and its field once you press it.
    private func footer(_ lines: [LinkedPullRequest]) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if linking { linkField }
            HStack(spacing: NookTheme.Spacing.sm) {
                TimelineView(.nookTicks(every: 30)) { context in
                    Text(summary(lines, now: context.date))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                Button {
                    linking ? stopLinking() : startLinking()
                } label: {
                    HStack(spacing: NookTheme.Spacing.xxs) {
                        Image(icon: "plus").font(NookTheme.font(9, .semibold))
                        Text(tr("agents.pr.linked.link")).font(NookTheme.TextStyle.caption)
                    }
                    .foregroundStyle(NookTheme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.nookPlain)
                .help(tr("agents.pr.linked.add"))
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
    }

    private func summary(_ lines: [LinkedPullRequest], now: Date) -> String {
        var parts = [tr("agents.pr.linked.open", LinkedPullRequests.openCount(lines)), tr("agents.pr.linked.count", lines.count)]
        if let read = sync.syncedAt(run: runID, directory: directory, branch: git.status?.branch), !lines.isEmpty {
            parts.append(tr("agents.pr.linked.synced", AgentFormat.short(now.timeIntervalSince(read))))
        }
        return parts.joined(separator: " · ")
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            HStack(spacing: NookTheme.Spacing.sm) {
                TextField(tr("agents.pr.linked.placeholder"), text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .font(NookTheme.TextStyle.detail)
                    .focused($linkFocused)
                    .onSubmit { submitLink() }
                    .onExitCommand { stopLinking() }
                if linkBusy { ProgressView().controlSize(.small) }
                SmallPrimaryButton(title: tr("agents.pr.linked.link")) { submitLink() }
                    .disabled(linkBusy || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let linkError {
                InlineErrorText(linkError)
            }
        }
    }

    private func startLinking() {
        linkError = nil
        linking = true
        linkFocused = true
    }

    private func stopLinking() {
        linking = false
        linkText = ""
        linkError = nil
    }

    /// Links what you typed: a link, "owner/repo#12", "#12" or a bare number, the last two in this session's repository.
    private func submitLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !linkBusy else { return }
        linkBusy = true
        linkError = nil
        Task {
            defer { linkBusy = false }
            guard let link = await resolve(text) else {
                linkError = tr("agents.pr.linked.notFound")
                return
            }
            sync.add(link, session: sessionKey)
            stopLinking()
        }
    }

    private func resolve(_ text: String) async -> PullRequestLink? {
        guard let ref = PullRequestRef.parse(text.allSatisfy(\.isNumber) ? "#" + text : text) else { return nil }
        return await PullRequestResolver.resolve(ref, repository: await sync.repository(directory: directory))
    }
}
