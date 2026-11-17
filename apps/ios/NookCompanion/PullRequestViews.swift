import SwiftUI

// Pull requests on the phone (docs/COMPANION.md, "Pull requests"): the Mac's list (yours, for your review, watched), a
// session's linked ones, and one in full with its summary, checks and files, to review line by line, mark files viewed,
// approve or request changes, merge, or hand to an agent. The Mac reads and acts with its own accounts and rules; what
// was read last stays readable without a connection (`PullCache`), and every action needs the Mac.

/// The Mac's pull request list, or a session's linked ones (`session`). With `CompanionFeature.pullActions` it is the
/// Mac's page sized for a phone: the chips of what asks something of you, the search (with `label:`, `repo:`,
/// `author:`, `branch:`…), the state, the order and the grouping in one menu, and rows that hold to show what you can do.
struct PullRequestListView: View {
    @EnvironmentObject private var client: CompanionClient
    var session: String? = nil
    @State private var loaded = false
    @State private var query = ""
    @State private var attention: PullList.Attention?
    @AppStorage("pulls.state") private var stateRaw = PullList.State.open.rawValue
    @AppStorage("pulls.sort") private var sortRaw = PullList.Sort.attention.rawValue
    @AppStorage("pulls.grouping") private var groupingRaw = PullList.Grouping.involvement.rawValue
    @State private var asking: PullQuickAsk?

    private var list: [PullDigest] { session.map { client.linkedPulls[$0] ?? [] } ?? client.pulls }
    private var full: Bool { session == nil && client.can(CompanionFeature.pullActions) }
    private var state: PullList.State { PullList.State(rawValue: stateRaw) ?? .open }
    private var sort: PullList.Sort { PullList.Sort(rawValue: sortRaw) ?? .attention }
    private var grouping: PullList.Grouping { PullList.Grouping(rawValue: groupingRaw) ?? .involvement }
    private var filtering: Bool { !query.isEmpty || attention != nil || state != .open }

    private func group(_ group: PullDigest.Group) -> [PullDigest] { list.filter { $0.group == group.rawValue } }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if client.phase != .connected, let at = session == nil ? client.pullsAt : nil {
                    Label("As of \(at.formatted(date: .omitted, time: .shortened)) · not connected", systemImage: "wifi.slash")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                }
                if list.isEmpty {
                    if loaded || client.phase != .connected {
                        WSEmptyState(symbol: "arrow.triangle.pull", title: String(localized: "No pull requests"),
                                     message: session == nil
                                        ? String(localized: "Pull requests from your accounts in Nook on your Mac show up here.")
                                        : String(localized: "This session has no pull request linked yet."))
                    } else {
                        ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxxl)
                    }
                } else if session != nil {
                    rows(list)
                } else if full {
                    toolbar
                    let sections = PullList.sections(list, query: query, state: state, attention: attention, sort: sort, grouping: grouping)
                    if sections.isEmpty {
                        WSEmptyState(symbol: "line.3.horizontal.decrease.circle", title: String(localized: "No pull requests match"),
                                     message: String(localized: "Try other words, or clear the filters."),
                                     action: (String(localized: "Clear filters"), { clear() }))
                    }
                    ForEach(sections) { section in
                        SectionHeader(title: title(section), count: section.pulls.count,
                                      urgent: grouping == .involvement && section.key == PullDigest.Group.review.rawValue)
                        rows(section.pulls)
                    }
                } else {
                    section(String(localized: "Yours"), group(.mine))
                    section(String(localized: "For your review"), group(.review))
                    section(String(localized: "Watched"), group(.watched))
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .refreshable { await load() }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { SheetTitle(title: String(localized: "Pull requests")) } }
        .screen()
        .navigationDestination(for: PullRoute.self) { route in PullRequestDetailView(url: route.url) }
        .confirmationDialog(asking?.title ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { ask in
            Button(ask.button, role: ask.kind.isDestructive && ask.kind != .merge ? .destructive : nil) {
                Task { await quick(ask.pull, ask.kind) }
            }
        } message: { ask in
            Text(verbatim: "\(ask.pull.repo)#\(ask.pull.number) · \(ask.pull.title)")
        }
        .task {
            await load()
            loaded = true
        }
    }

    private func load() async {
        if let session { await client.loadLinkedPulls(session) } else { await client.loadPulls() }
    }

    // MARK: Search, chips and the menu

    /// The Mac's attention bar, search row and Sort menu, stacked for a thumb: the chips first, then the search with the
    /// one menu for state, order and grouping beside it.
    private var toolbar: some View {
        let counts = PullList.counted(list, query: query, state: state)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(PullList.Attention.allCases, id: \.self) { kind in
                        let count = counts[kind] ?? 0
                        if count > 0 || attention == kind {
                            NookFilterChip(title: Self.chipTitle(kind), count: count, selected: attention == kind) {
                                Haptics.tap()
                                withAnimation(Theme.reveal) { attention = attention == kind ? nil : kind }
                            }
                        }
                    }
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                NookSearchField(prompt: "Search, or label:bug repo: author:", text: $query)
                Menu {
                    Picker("State", selection: $stateRaw) {
                        ForEach(PullList.State.allCases, id: \.self) { option in Text(Self.stateTitle(option)).tag(option.rawValue) }
                    }
                    Picker("Sort", selection: $sortRaw) {
                        ForEach(PullList.Sort.allCases, id: \.self) { option in Text(Self.sortTitle(option)).tag(option.rawValue) }
                    }
                    Picker("Group by", selection: $groupingRaw) {
                        Text("Involvement").tag(PullList.Grouping.involvement.rawValue)
                        Text("Repository").tag(PullList.Grouping.repository.rawValue)
                    }
                    if filtering {
                        Button { clear() } label: { Label("Clear filters", systemImage: "xmark.circle") }
                    }
                } label: {
                    Image(icon: state == .open ? "arrow.up.arrow.down" : "line.3.horizontal.decrease.circle.fill")
                        .font(Theme.font(15))
                        .foregroundStyle(state == .open ? Theme.textSecondary : Theme.iris)
                        .frame(width: 44, height: 38)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Sort and filter")
            }
            if state != .open {
                Text(Self.stateTitle(state)).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func clear() {
        withAnimation(Theme.reveal) {
            query = ""
            attention = nil
            stateRaw = PullList.State.open.rawValue
        }
    }

    private func title(_ section: PullList.Section) -> String {
        guard grouping == .involvement else { return section.key }
        switch PullDigest.Group(rawValue: section.key) {
        case .review?: return String(localized: "For your review")
        case .mine?: return String(localized: "Yours")
        case .watched?: return String(localized: "Watched")
        default: return String(localized: "Linked to sessions")
        }
    }

    static func chipTitle(_ kind: PullList.Attention) -> String {
        switch kind {
        case .review: return String(localized: "Review")
        case .failing: return String(localized: "Failing")
        case .ready: return String(localized: "Ready to merge")
        }
    }

    static func stateTitle(_ state: PullList.State) -> String {
        switch state {
        case .open: return String(localized: "Open")
        case .closed: return String(localized: "Closed")
        case .merged: return String(localized: "Merged")
        case .all: return String(localized: "All states")
        }
    }

    static func sortTitle(_ sort: PullList.Sort) -> String {
        switch sort {
        case .attention: return String(localized: "Needs you first")
        case .readiness: return String(localized: "Closest to merging")
        case .blockedOnMe: return String(localized: "Blocked on me")
        case .recent: return String(localized: "Recently updated")
        case .oldest: return String(localized: "Least recently updated")
        case .largest: return String(localized: "Largest change")
        case .smallest: return String(localized: "Smallest change")
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func section(_ title: String, _ pulls: [PullDigest]) -> some View {
        if !pulls.isEmpty {
            SectionHeader(title: title, count: pulls.count)
            rows(pulls)
        }
    }

    private func rows(_ pulls: [PullDigest]) -> some View {
        ForEach(pulls) { pull in
            OpenLink(value: PullRoute(url: pull.url)) { PullRow(pull: pull) }
                .buttonStyle(RowPress())
                .contextMenu { rowMenu(pull) }
        }
    }

    /// What a held row offers: its link, and the Mac's quick actions (close and merge an open one, mark a draft ready,
    /// reopen a closed one), each asked first.
    @ViewBuilder
    private func rowMenu(_ pull: PullDigest) -> some View {
        if let url = URL(string: pull.url) {
            Button { UIPasteboard.general.url = url; Haptics.success() } label: { Label("Copy link", systemImage: "link") }
            Button { UIApplication.shared.open(url) } label: { Label("Open in browser", systemImage: "safari") }
        }
        if client.allows(.operate), client.phase == .connected, client.can(CompanionFeature.pullActions) {
            Divider()
            switch pull.state {
            case "open":
                Button { asking = PullQuickAsk(pull: pull, kind: .merge) } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                Button(role: .destructive) { asking = PullQuickAsk(pull: pull, kind: .close) } label: { Label("Close", systemImage: "xmark.circle") }
            case "draft":
                Button { asking = PullQuickAsk(pull: pull, kind: .ready) } label: { Label("Ready for review", systemImage: "arrow.triangle.pull") }
                Button(role: .destructive) { asking = PullQuickAsk(pull: pull, kind: .close) } label: { Label("Close", systemImage: "xmark.circle") }
            case "closed":
                Button { asking = PullQuickAsk(pull: pull, kind: .reopen) } label: { Label("Reopen", systemImage: "arrow.uturn.backward") }
            default:
                EmptyView()
            }
        }
    }

    /// A quick action from a row: the pull request read in full first, so it goes only at the head the Mac sees now and
    /// only when the Mac would offer it.
    private func quick(_ pull: PullDigest, _ kind: CompanionPullAction.Kind) async {
        await client.loadPull(pull.url)
        guard let detail = client.pullDetails[pull.url] else { Haptics.warning(); return }
        let action: CompanionPullAction
        if kind == .merge {
            guard detail.blocker == nil, let method = detail.methods.first else {
                client.notice = String(localized: "This pull request cannot be merged from your iPhone now.")
                Haptics.warning()
                return
            }
            action = CompanionPullAction(kind: .merge, method: method, head: detail.headSHA)
        } else {
            guard client.pullAllows(detail, kind) else {
                client.notice = String(localized: "Your Mac does not offer this for this pull request now.")
                Haptics.warning()
                return
            }
            action = CompanionPullAction(kind: kind)
        }
        if await client.actOnPull(pull.url, action) { Haptics.success() } else { Haptics.warning() }
    }
}

/// A quick action waiting for its yes.
private struct PullQuickAsk: Identifiable {
    let pull: PullDigest
    let kind: CompanionPullAction.Kind
    var id: String { pull.url + kind.rawValue }

    var title: String {
        switch kind {
        case .merge: return String(localized: "Merge this pull request?")
        case .close: return String(localized: "Close this pull request?")
        case .ready: return String(localized: "Mark ready for review?")
        default: return String(localized: "Reopen this pull request?")
        }
    }

    var button: String {
        switch kind {
        case .merge: return String(localized: "Merge")
        case .close: return String(localized: "Close")
        case .ready: return String(localized: "Ready for review")
        default: return String(localized: "Reopen")
        }
    }
}

/// Where a tap on a pull request goes.
struct PullRoute: Hashable {
    let url: String
}

/// One pull request in a list, the Mac's `PullRequestRow` for a phone: its state, title and labels, where it is, who
/// opened it when, the review decision, and how its checks, comments and lines stand.
private struct PullRow: View {
    let pull: PullDigest

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            PullStateMark(state: pull.state, conflict: pull.conflict)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(pull.title.isEmpty ? "#\(pull.number)" : pull.title)
                    .font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(2)
                HStack(spacing: Theme.Spacing.sm) {
                    Text(verbatim: "\(pull.repo)#\(pull.number)").lineLimit(1).truncationMode(.middle)
                    if !pull.author.isEmpty { Text(verbatim: pull.author).lineLimit(1) }
                    if let created = pull.created {
                        Text("opened \(AgentRow.age(Date().timeIntervalSince1970 - created)) ago").lineLimit(1)
                    }
                }
                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                if let review = PullReviewWord(review: pull.review), pull.isOpen {
                    review.font(Theme.TextStyle.caption)
                }
                if let labels = pull.labels, !labels.isEmpty {
                    PullLabels(labels: labels, colors: pull.labelColors ?? [:], limit: 3)
                }
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xxs) {
                    ChecksMark(ci: pull.ci)
                    if let passed = pull.checksPassed, let total = pull.checksTotal, total > 0 {
                        Text(verbatim: "\(passed)/\(total)").font(Theme.TextStyle.caption).monospacedDigit()
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                if let comments = pull.comments, comments > 0 {
                    Label("\(comments)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                        .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel(Text("\(comments) comments"))
                }
                if let added = pull.additions, let removed = pull.deletions { LineCounts(added: added, removed: removed) }
            }
        }
        .card(padding: Theme.Spacing.lg)
    }
}

/// The pull request's state as a colored mark: open, draft, merged, closed, or a conflict.
private struct PullStateMark: View {
    let state: String
    var conflict = false

    var body: some View {
        Image(icon: symbol).font(Theme.font(14, .semibold)).foregroundStyle(color)
            .frame(width: 22).accessibilityLabel(Text(word))
    }

    private var symbol: String {
        if conflict, state == "open" || state == "draft" { return "exclamationmark.triangle" }
        switch state {
        case "merged": return "arrow.triangle.merge"
        case "closed": return "xmark.circle"
        case "draft": return "circle.dashed"
        default: return "arrow.triangle.pull"
        }
    }

    private var color: Color {
        if conflict, state == "open" || state == "draft" { return Theme.coral }
        switch state {
        case "merged": return Theme.violet
        case "closed": return Theme.coral
        case "draft": return Theme.textTertiary
        default: return Theme.mint
        }
    }

    var word: String {
        if conflict, state == "open" || state == "draft" { return String(localized: "Conflict") }
        switch state {
        case "merged": return String(localized: "Merged")
        case "closed": return String(localized: "Closed")
        case "draft": return String(localized: "Draft")
        default: return String(localized: "Open")
        }
    }
}

/// How the checks stand, as a small mark.
private struct ChecksMark: View {
    let ci: String

    var body: some View {
        switch ci {
        case "failing": Image(icon: "xmark.circle.fill").foregroundStyle(Theme.coral).accessibilityLabel(Text("Checks fail"))
        case "pending": Image(icon: "clock").foregroundStyle(Theme.amber).accessibilityLabel(Text("Checks run"))
        case "passing": Image(icon: "checkmark.circle.fill").foregroundStyle(Theme.mint).accessibilityLabel(Text("Checks pass"))
        default: EmptyView()
        }
    }
}

// MARK: One pull request

struct PullRequestDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let url: String
    enum Tab: String, CaseIterable, Identifiable {
        case summary, conversation, checks, files
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary
    @State private var drafts: [CompanionPullAction.LineComment] = []
    @State private var open: Set<String> = []
    @State private var reviewing = false
    @State private var confirmMerge = false
    @State private var confirm: CompanionPullAction.Kind?
    @State private var working = false
    @State private var busy = false

    private var detail: PullDetailDigest? { client.pullDetails[url] }
    private var connected: Bool { client.phase == .connected }
    private var mayAct: Bool { connected && client.allows(.operate) }
    /// The Mac sends the side info, the conversation and its menu's actions (`CompanionFeature.pullActions`).
    private var full: Bool { client.can(CompanionFeature.pullActions) && detail?.actions != nil }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let detail {
                    header(detail)
                    tabs(detail)
                    switch tab {
                    case .summary: summary(detail)
                    case .conversation: PullConversationView(detail: detail, mayAct: mayAct && full, busy: busy) { action in await act(action) }
                    case .checks: checks(detail)
                    case .files: files(detail)
                    }
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxxl)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .refreshable { await client.loadPull(url) }
        .safeAreaInset(edge: .bottom) { if let detail { actions(detail) } }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SheetTitle(title: detail.map { "#\($0.number)" } ?? String(localized: "Pull request"), subtitle: detail?.repo)
            }
            if let detail { ToolbarItem(placement: .topBarTrailing) { moreMenu(detail) } }
        }
        .screen()
        .sheet(isPresented: $reviewing) {
            if let detail {
                PullReviewSheet(detail: detail, drafts: $drafts) { action in await act(action) }
            }
        }
        .sheet(isPresented: $working) {
            if let detail { WorkOnPullSheet(detail: detail) }
        }
        .confirmationDialog("Merge this pull request?", isPresented: $confirmMerge, titleVisibility: .visible) {
            if let detail {
                if detail.blocker == nil {
                    ForEach(detail.methods, id: \.self) { method in
                        Button(methodTitle(method)) { Task { await act(CompanionPullAction(kind: .merge, method: method, head: detail.headSHA)) } }
                    }
                }
                if mayAct, client.pullAllows(detail, .autoMergeOn) {
                    ForEach(detail.methods, id: \.self) { method in
                        Button(String(localized: "Auto-merge: \(methodTitle(method))")) {
                            Task { await act(CompanionPullAction(kind: .autoMergeOn, method: method)) }
                        }
                    }
                }
            }
        } message: {
            if let detail { Text("\(detail.headBranch) into \(detail.baseBranch), at the head you see now.") }
        }
        .confirmationDialog(confirm.map(confirmTitle) ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { kind in
            Button(menuTitle(kind), role: .destructive) { Task { await act(CompanionPullAction(kind: kind)) } }
        } message: { kind in
            Text(kind == .deleteBranch ? String(localized: "The branch \(detail?.headBranch ?? "") is deleted from the repository.")
                                       : String(localized: "You can reopen it later."))
        }
        .task { await client.loadPull(url) }
    }

    // MARK: Parts

    private func header(_ detail: PullDetailDigest) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                PullStateMark(state: detail.state)
                Text(PullStateMark(state: detail.state).word).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                LineCounts(added: detail.additions, removed: detail.deletions)
            }
            Text(detail.title).font(Theme.TextStyle.title).foregroundStyle(Theme.paper)
            Text(verbatim: "\(detail.author) · \(detail.headBranch) → \(detail.baseBranch)")
                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(2)
            if let created = detail.created {
                Text("opened \(AgentRow.age(Date().timeIntervalSince1970 - created)) ago")
                    .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
            if !connected, let at = client.pullReadAt(url) {
                Label("As of \(at.formatted(date: .omitted, time: .shortened)) · not connected", systemImage: "wifi.slash")
                    .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
            }
        }
        .card(padding: Theme.Spacing.lg)
    }

    /// The Mac's tabs as chips that fit a phone's width: Summary, Conversation (with a Mac that sends it), Checks, Files.
    private func tabs(_ detail: PullDetailDigest) -> some View {
        let talk = (detail.conversation?.count ?? 0) + (detail.threads?.count ?? 0)
        let failing = detail.checks.count(where: { $0.outcome == "failing" })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                NookFilterChip(title: String(localized: "Summary"), selected: tab == .summary) { pick(.summary) }
                if full {
                    NookFilterChip(title: String(localized: "Conversation"), count: talk == 0 ? nil : talk, selected: tab == .conversation) {
                        pick(.conversation)
                    }
                }
                NookFilterChip(title: String(localized: "Checks"), count: failing > 0 ? failing : detail.checks.count, selected: tab == .checks) {
                    pick(.checks)
                }
                NookFilterChip(title: String(localized: "Files"), count: detail.files.count, selected: tab == .files) { pick(.files) }
            }
        }
    }

    private func pick(_ next: Tab) {
        Haptics.tap()
        withAnimation(Theme.reveal) { tab = next }
    }

    @ViewBuilder
    private func summary(_ detail: PullDetailDigest) -> some View {
        if let blocker = detail.blocker, detail.state == "open" || detail.state == "draft" {
            Label(blockerText(blocker), systemImage: "exclamationmark.circle")
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
        }
        if full {
            PullSideInfo(detail: detail, canUpdate: mayAct && client.pullAllows(detail, .updateBranch)) {
                Task { await act(CompanionPullAction(kind: .updateBranch, head: detail.headSHA)) }
            }
        }
        if !detail.verdicts.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(detail.verdicts, id: \.author) { verdict in
                    Label(verdict.approved ? String(localized: "\(verdict.author) approved") : String(localized: "\(verdict.author) asked for changes"),
                          systemImage: verdict.approved ? "checkmark.seal" : "exclamationmark.bubble")
                        .foregroundStyle(verdict.approved ? Theme.mint : Theme.amber)
                }
            }
            .font(Theme.TextStyle.detail)
        }
        if detail.body.isEmpty {
            Text("No description.").font(Theme.TextStyle.body).foregroundStyle(Theme.textTertiary)
        } else {
            RichMessageText(text: detail.body)
        }
    }

    @ViewBuilder
    private func checks(_ detail: PullDetailDigest) -> some View {
        if detail.checks.isEmpty {
            Text("No checks on this head.").font(Theme.TextStyle.body).foregroundStyle(Theme.textTertiary)
        }
        if mayAct, client.pullAllows(detail, .rerunFailed) {
            Button { Task { await act(CompanionPullAction(kind: .rerunFailed)) } } label: {
                Label("Rerun failed checks", systemImage: "arrow.clockwise")
                    .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                    .frame(minHeight: 44)
            }
            .disabled(busy)
        }
        ForEach(detail.checks) { check in
            HStack(spacing: Theme.Spacing.md) {
                ChecksMark(ci: check.outcome == "skipped" ? "" : check.outcome)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(check.name).font(Theme.TextStyle.body).foregroundStyle(Theme.paper).lineLimit(2)
                    if !check.detail.isEmpty {
                        Text(check.detail).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .card(padding: Theme.Spacing.md)
        }
    }

    @ViewBuilder
    private func files(_ detail: PullDetailDigest) -> some View {
        let viewed = detail.files.count(where: { $0.viewed == "viewed" })
        Text("\(viewed) of \(detail.files.count) viewed").font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
        ForEach(detail.files) { file in
            PullFileCard(file: file, open: open.contains(file.path), canComment: detail.lineComments && mayAct,
                         canMark: mayAct, drafts: drafts.filter { $0.path == file.path }) {
                withAnimation(Theme.reveal) { if open.contains(file.path) { open.remove(file.path) } else { open.insert(file.path) } }
            } mark: { viewed in
                Task { await act(CompanionPullAction(kind: viewed ? .viewed : .unviewed, path: file.path)) }
                if viewed { withAnimation(Theme.reveal) { _ = open.remove(file.path) } }
            } add: { note in
                drafts.append(note)
            }
        }
    }

    private func actions(_ detail: PullDetailDigest) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            if !mayAct {
                Text(connected ? String(localized: "Reviewing and merging are turned off for this iPhone in Nook on your Mac.")
                               : String(localized: "Connect to your Mac to review or merge."))
                    .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
            HStack(spacing: Theme.Spacing.md) {
                Button { reviewing = true } label: {
                    Label(drafts.isEmpty ? String(localized: "Review") : String(localized: "Review (\(drafts.count))"), systemImage: "text.bubble")
                }
                .disabled(!mayAct || detail.state == "merged" || detail.state == "closed")
                Button { working = true } label: { Label("Work on this", systemImage: "hammer") }
                    .disabled(!mayAct || !client.can(CompanionFeature.start))
                Spacer(minLength: 0)
                if detail.autoMerge != nil {
                    Label("Auto-merge on", systemImage: "bolt.fill").foregroundStyle(Theme.mint)
                } else if (detail.blocker == nil && !detail.methods.isEmpty) || (mayAct && client.pullAllows(detail, .autoMergeOn)) {
                    NookPrimaryButton(title: String(localized: "Merge"), symbol: "arrow.triangle.merge") { confirmMerge = true }
                        .disabled(!mayAct || busy)
                }
            }
            .font(Theme.TextStyle.label)
            .foregroundStyle(Theme.paper)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.canvas.opacity(0.96))
    }

    /// The Mac's action menu (`PullRequestActionPanel`): the link, then what the Mac offers for this pull request now.
    private func moreMenu(_ detail: PullDetailDigest) -> some View {
        Menu {
            if let link = URL(string: detail.url) {
                Button { UIPasteboard.general.url = link; Haptics.success() } label: { Label("Copy link", systemImage: "link") }
                Button { UIApplication.shared.open(link) } label: { Label("Open in browser", systemImage: "safari") }
            }
            Button { Task { await client.loadPull(url) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            if mayAct, full {
                let kinds: [CompanionPullAction.Kind] = [.ready, .draft, .updateBranch, .rebaseBranch, .autoMergeOff, .rerunFailed, .reopen]
                let shown = kinds.filter { client.pullAllows(detail, $0) }
                if !shown.isEmpty { Divider() }
                ForEach(shown, id: \.self) { kind in
                    Button { Task { await act(menuAction(kind, detail: detail)) } } label: { Label(menuTitle(kind), systemImage: menuSymbol(kind)) }
                }
                if client.pullAllows(detail, .autoMergeOn) {
                    Menu {
                        ForEach(detail.methods, id: \.self) { method in
                            Button(methodTitle(method)) { Task { await act(CompanionPullAction(kind: .autoMergeOn, method: method)) } }
                        }
                    } label: { Label("Enable auto-merge", systemImage: "bolt") }
                }
                let risky = [CompanionPullAction.Kind.deleteBranch, .close].filter { client.pullAllows(detail, $0) }
                if !risky.isEmpty { Divider() }
                ForEach(risky, id: \.self) { kind in
                    Button(role: .destructive) { confirm = kind } label: { Label(menuTitle(kind), systemImage: menuSymbol(kind)) }
                }
            }
        } label: {
            Image(icon: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("More")
    }

    private func menuAction(_ kind: CompanionPullAction.Kind, detail: PullDetailDigest) -> CompanionPullAction {
        [.updateBranch, .rebaseBranch].contains(kind) ? CompanionPullAction(kind: kind, head: detail.headSHA) : CompanionPullAction(kind: kind)
    }

    private func menuTitle(_ kind: CompanionPullAction.Kind) -> String {
        switch kind {
        case .ready: return String(localized: "Ready for review")
        case .draft: return String(localized: "Convert to draft")
        case .updateBranch: return String(localized: "Update branch")
        case .rebaseBranch: return String(localized: "Rebase branch")
        case .autoMergeOff: return String(localized: "Disable auto-merge")
        case .rerunFailed: return String(localized: "Rerun failed checks")
        case .reopen: return String(localized: "Reopen")
        case .deleteBranch: return String(localized: "Delete branch")
        default: return String(localized: "Close")
        }
    }

    private func menuSymbol(_ kind: CompanionPullAction.Kind) -> String {
        switch kind {
        case .ready: return "arrow.triangle.pull"
        case .draft: return "circle.dashed"
        case .updateBranch, .rebaseBranch: return "arrow.triangle.branch"
        case .autoMergeOff: return "bolt.slash"
        case .rerunFailed: return "arrow.clockwise"
        case .reopen: return "arrow.uturn.backward"
        case .deleteBranch: return "trash"
        default: return "xmark.circle"
        }
    }

    private func confirmTitle(_ kind: CompanionPullAction.Kind) -> String {
        kind == .deleteBranch ? String(localized: "Delete the branch?") : String(localized: "Close this pull request?")
    }

    private func act(_ action: CompanionPullAction) async {
        busy = true
        defer { busy = false }
        if await client.actOnPull(url, action) {
            Haptics.success()
            if [.approve, .requestChanges, .comment].contains(action.kind) { drafts = [] }
        } else {
            Haptics.warning()
        }
    }

    private func methodTitle(_ method: String) -> String {
        switch method {
        case "squash": return String(localized: "Squash and merge")
        case "rebase": return String(localized: "Rebase and merge")
        default: return String(localized: "Merge commit")
        }
    }

    private func blockerText(_ blocker: String) -> String {
        switch PullMergeBlocker(rawValue: blocker) {
        case .merged?: return String(localized: "Already merged.")
        case .closed?: return String(localized: "Closed without merging.")
        case .draft?: return String(localized: "A draft: mark it ready on your Mac or the forge first.")
        case .access?: return String(localized: "Your account cannot merge into this repository.")
        case .conflict?: return String(localized: "Conflicts with its base branch.")
        case .checks?: return String(localized: "Checks fail: merge it on your Mac if you are sure.")
        case nil: return String(localized: "Cannot be merged from your iPhone now.")
        }
    }
}

/// One changed file of a pull request: its name and lines, Viewed, and open, its patch with lines to comment on.
private struct PullFileCard: View {
    let file: PullDetailDigest.File
    let open: Bool
    let canComment: Bool
    let canMark: Bool
    let drafts: [CompanionPullAction.LineComment]
    let toggle: () -> Void
    let mark: (Bool) -> Void
    let add: (CompanionPullAction.LineComment) -> Void

    private var viewed: Bool { file.viewed == "viewed" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Button(action: toggle) {
                    HStack(spacing: Theme.Spacing.md) {
                        Image(icon: "chevron.right").font(Theme.font(10, .bold)).foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(verbatim: (file.path as NSString).lastPathComponent)
                                .font(Theme.TextStyle.strong).foregroundStyle(viewed ? Theme.textSecondary : Theme.paper).lineLimit(1)
                            HStack(spacing: Theme.Spacing.sm) {
                                Text(verbatim: (file.path as NSString).deletingLastPathComponent).lineLimit(1).truncationMode(.head)
                                if file.viewed == "changed" { Text("Changed since viewed").foregroundStyle(Theme.amber) }
                                if !drafts.isEmpty { Text("\(drafts.count) comments").foregroundStyle(Theme.iris) }
                            }
                            .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: Theme.Spacing.sm)
                        LineCounts(added: file.additions, removed: file.deletions)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
                Button { mark(!viewed) } label: {
                    Image(icon: viewed ? "checkmark.circle.fill" : "circle")
                        .font(Theme.font(18)).foregroundStyle(viewed ? Theme.mint : Theme.textTertiary)
                }
                .buttonStyle(PressFade())
                .disabled(!canMark)
                .accessibilityLabel(viewed ? Text("Mark as not viewed") : Text("Mark as viewed"))
            }
            .padding(Theme.Spacing.lg)
            if open {
                if let patch = file.patch, !patch.isEmpty {
                    PullPatchView(path: file.path, patch: patch, canComment: canComment, drafts: drafts, add: add)
                }
                if file.truncated || file.patch == nil {
                    Text(file.patch == nil ? "No patch to show for this file." : "The rest of this file's changes is on your Mac.")
                        .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).padding(Theme.Spacing.lg)
                }
            }
        }
        .roundedClip(Theme.Radius.card)
        .cardBackground(Theme.surface, stroke: Theme.line2, radius: Theme.Radius.card)
    }
}

/// A pull request file's patch: tap a line, and another for a range, then Comment adds a comment on those lines to your
/// review (sent with it, as a draft until then).
private struct PullPatchView: View {
    let path: String
    let patch: String
    let canComment: Bool
    let drafts: [CompanionPullAction.LineComment]
    let add: (CompanionPullAction.LineComment) -> Void
    @State private var first: Int?
    @State private var last: Int?
    @State private var writing = false
    @State private var note = ""

    private var lines: [String] { patch.components(separatedBy: "\n") }

    private var picked: ClosedRange<Int>? {
        guard let first else { return nil }
        let end = last ?? first
        return min(first, end)...max(first, end)
    }

    var body: some View {
        let lines = lines
        let positions = PatchPositions.positions(lines)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        let position = positions[index]
                        let commented = position.map { at in drafts.contains { $0.line == at.line && $0.side == at.side } } ?? false
                        PullPatchLine(line: line, number: position?.line, picked: picked?.contains(index) == true, commented: commented)
                            .onTapGesture { pick(index, position: position) }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .background(Theme.well)
            if let picked {
                HStack(spacing: Theme.Spacing.md) {
                    Text(picked.count == 1 ? String(localized: "1 line") : String(localized: "\(picked.count) lines"))
                        .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button("Clear") { withAnimation(Theme.reveal) { first = nil; last = nil } }
                        .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    NookPrimaryButton(title: String(localized: "Comment"), symbol: "text.bubble") { writing = true }
                }
                .padding(Theme.Spacing.lg)
            }
        }
        .alert("Comment on these lines", isPresented: $writing) {
            TextField("Your comment", text: $note, axis: .vertical)
            Button("Add to review") {
                let body = note.trimmingCharacters(in: .whitespacesAndNewlines)
                note = ""
                guard let picked, !body.isEmpty,
                      let comment = PatchPositions.comment(path: path, picked: picked, positions: positions, body: body) else { return }
                add(comment)
                Haptics.success()
                withAnimation(Theme.reveal) { first = nil; last = nil }
            }
            Button("Cancel", role: .cancel) { note = "" }
        } message: {
            Text("It waits with your review and goes when you send it.")
        }
    }

    private func pick(_ index: Int, position: PatchPositions.Position?) {
        guard canComment, position != nil else { return }
        Haptics.tap()
        withAnimation(Theme.reveal) {
            if first == nil || last != nil {
                first = index
                last = nil
            } else if index == first {
                first = nil
            } else {
                last = index
            }
        }
    }
}

private struct PullPatchLine: View {
    let line: String
    let number: Int?
    let picked: Bool
    let commented: Bool

    private var tint: Color? {
        if line.hasPrefix("@@") { return Theme.blue }
        if line.hasPrefix("+") { return Theme.mint }
        if line.hasPrefix("-") { return Theme.coral }
        return nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(verbatim: number.map(String.init) ?? "").foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .trailing)
            Image(icon: "text.bubble.fill").font(Theme.font(8)).foregroundStyle(Theme.iris).opacity(commented ? 1 : 0)
            Text(verbatim: line.isEmpty ? " " : line).foregroundStyle(tint ?? Theme.textStrong).fixedSize(horizontal: true, vertical: false)
        }
        .font(Theme.TextStyle.code)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((picked ? Theme.iris.opacity(0.16) : tint.map { $0.opacity(0.07) }) ?? Color.clear)
        .contentShape(Rectangle())
    }
}

/// Sends the review: approve, request changes or comment, with your words and the comments on lines.
private struct PullReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let detail: PullDetailDigest
    @Binding var drafts: [CompanionPullAction.LineComment]
    let send: (CompanionPullAction) async -> Void
    @State private var text = ""
    @State private var kind: CompanionPullAction.Kind = .comment
    @State private var sending = false

    private var action: CompanionPullAction {
        CompanionPullAction(kind: kind, body: text, comments: drafts.isEmpty ? nil : drafts, head: detail.headSHA)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    Picker("Verdict", selection: $kind) {
                        Text("Comment").tag(CompanionPullAction.Kind.comment)
                        if detail.verdictsAllowed {
                            Text("Approve").tag(CompanionPullAction.Kind.approve)
                            Text("Request changes").tag(CompanionPullAction.Kind.requestChanges)
                        }
                    }
                    .pickerStyle(.segmented)
                    SessionComposer(text: $text, prompt: "Your review", minHeight: 88, lines: 4...10, canSend: action.isValid,
                                    sending: sending) {
                        Task {
                            sending = true
                            await send(action)
                            sending = false
                            dismiss()
                        }
                    }
                    if !drafts.isEmpty {
                        SectionHeader(title: String(localized: "Comments on lines"), count: drafts.count)
                        ForEach(Array(drafts.enumerated()), id: \.offset) { index, note in
                            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                    Text(verbatim: "\((note.path as NSString).lastPathComponent):\(note.startLine.map { "\($0)–" } ?? "")\(note.line)")
                                        .font(Theme.TextStyle.code).foregroundStyle(Theme.textTertiary)
                                    Text(note.body).font(Theme.TextStyle.body).foregroundStyle(Theme.paper)
                                }
                                Spacer(minLength: 0)
                                Button { drafts.remove(at: index) } label: { Image(icon: "trash") }
                                    .foregroundStyle(Theme.textTertiary)
                                    .accessibilityLabel("Remove comment")
                            }
                            .card(padding: Theme.Spacing.md)
                        }
                    }
                    Text("The review goes to the forge from your Mac, with its account, only at the head you see now.")
                        .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                }
                .padding(Theme.Spacing.xl)
            }
            .screen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: String(localized: "Review"), subtitle: "#\(detail.number)") }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Theme.paper) }
            }
        }
    }
}

/// "Work on this": a new session on the Mac, in a worktree of its own on the pull request's branch.
private struct WorkOnPullSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var client: CompanionClient
    let detail: PullDetailDigest
    @State private var task = ""
    @State private var agent = ""
    @State private var model = ""
    @State private var sending = false

    private var agents: [LaunchOptions.Agent] { client.launchOptions?.agents ?? [] }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if agents.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    SessionComposer(text: $task, prompt: "What should the agent do? (empty: get to know it)", minHeight: 88, lines: 4...10,
                                    canSend: !agent.isEmpty, sending: sending, onSend: start) {
                        Menu {
                            ForEach(agents) { option in
                                Button { agent = option.id; model = "" } label: { Text(option.name) }
                            }
                        } label: {
                            ComposerPill(agent: agents.first { $0.id == agent }?.name, text: agents.first { $0.id == agent }?.name ?? "")
                        }
                        if let models = agents.first(where: { $0.id == agent })?.models, !models.isEmpty {
                            Menu {
                                ForEach(models) { option in Button(option.name) { model = option.id } }
                            } label: {
                                ComposerPill(symbol: "cpu", text: models.first { $0.id == model }?.name ?? String(localized: "Default model"))
                            }
                        }
                    }
                }
                Text("Nook checks out \(detail.headBranch) in a worktree of its own, where your Mac has \(detail.repo), and starts the agent there. It asks before anything risky, as every session started from your iPhone.")
                    .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.xl)
            .screen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { SheetTitle(title: String(localized: "Work on this"), subtitle: "#\(detail.number)") }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Theme.paper) }
            }
            .task {
                await client.loadLaunchOptions()
                if agent.isEmpty { agent = client.launchOptions?.defaultAgent ?? agents.first?.id ?? "" }
            }
        }
    }

    private func start() {
        sending = true
        Task {
            let work = PullWorkRequest(url: detail.url, agent: agent, task: task.trimmingCharacters(in: .whitespacesAndNewlines),
                                       model: model.isEmpty ? nil : model)
            let created = await client.workOnPull(work)
            sending = false
            if let created {
                Haptics.success()
                dismiss()
                client.openSession = created
            }
        }
    }
}
