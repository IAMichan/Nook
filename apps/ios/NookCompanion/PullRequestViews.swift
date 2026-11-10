import SwiftUI

// Pull requests on the phone (docs/COMPANION.md, "Pull requests"): the Mac's list (yours, for your review, watched), a
// session's linked ones, and one in full with its summary, checks and files, to review line by line, mark files viewed,
// approve or request changes, merge, or hand to an agent. The Mac reads and acts with its own accounts and rules; what
// was read last stays readable without a connection (`PullCache`), and every action needs the Mac.

/// The Mac's pull request list, or a session's linked ones (`session`).
struct PullRequestListView: View {
    @EnvironmentObject private var client: CompanionClient
    var session: String? = nil
    @State private var loaded = false

    private var list: [PullDigest] { session.map { client.linkedPulls[$0] ?? [] } ?? client.pulls }

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
        .task {
            await load()
            loaded = true
        }
    }

    private func load() async {
        if let session { await client.loadLinkedPulls(session) } else { await client.loadPulls() }
    }

    @ViewBuilder
    private func section(_ title: String, _ pulls: [PullDigest]) -> some View {
        if !pulls.isEmpty {
            SectionHeader(title: title, count: pulls.count)
            rows(pulls)
        }
    }

    private func rows(_ pulls: [PullDigest]) -> some View {
        ForEach(pulls) { pull in
            NavigationLink(value: PullRoute(url: pull.url)) { PullRow(pull: pull) }
                .buttonStyle(RowPress())
        }
    }
}

/// Where a tap on a pull request goes.
struct PullRoute: Hashable {
    let url: String
}

/// One pull request in a list: its state, title, where it is and how its checks and reviews stand.
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
                }
                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.sm)
            VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                ChecksMark(ci: pull.ci)
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
        Image(systemName: symbol).font(Theme.font(14, .semibold)).foregroundStyle(color)
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
        case "failing": Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.coral).accessibilityLabel(Text("Checks fail"))
        case "pending": Image(systemName: "clock").foregroundStyle(Theme.amber).accessibilityLabel(Text("Checks run"))
        case "passing": Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint).accessibilityLabel(Text("Checks pass"))
        default: EmptyView()
        }
    }
}

// MARK: One pull request

struct PullRequestDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let url: String
    enum Tab: String, CaseIterable, Identifiable {
        case summary, checks, files
        var id: String { rawValue }
    }

    @State private var tab: Tab = .summary
    @State private var drafts: [CompanionPullAction.LineComment] = []
    @State private var open: Set<String> = []
    @State private var reviewing = false
    @State private var confirmMerge = false
    @State private var working = false
    @State private var busy = false

    private var detail: PullDetailDigest? { client.pullDetails[url] }
    private var connected: Bool { client.phase == .connected }
    private var mayAct: Bool { connected && client.allows(.operate) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let detail {
                    header(detail)
                    Picker("Show", selection: $tab) {
                        Text("Summary").tag(Tab.summary)
                        Text("Checks \(detail.checks.count)").tag(Tab.checks)
                        Text("Files \(detail.files.count)").tag(Tab.files)
                    }
                    .pickerStyle(.segmented)
                    switch tab {
                    case .summary: summary(detail)
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
                ForEach(detail.methods, id: \.self) { method in
                    Button(methodTitle(method)) { Task { await act(CompanionPullAction(kind: .merge, method: method, head: detail.headSHA)) } }
                }
            }
        } message: {
            if let detail { Text("\(detail.headBranch) into \(detail.baseBranch), at the head you see now.") }
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
            if !connected, let at = client.pullReadAt(url) {
                Label("As of \(at.formatted(date: .omitted, time: .shortened)) · not connected", systemImage: "wifi.slash")
                    .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
            }
        }
        .card(padding: Theme.Spacing.lg)
    }

    @ViewBuilder
    private func summary(_ detail: PullDetailDigest) -> some View {
        if let blocker = detail.blocker, detail.state == "open" || detail.state == "draft" {
            Label(blockerText(blocker), systemImage: "exclamationmark.circle")
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
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
        let viewed = detail.files.filter { $0.viewed == "viewed" }.count
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
                if detail.blocker == nil, !detail.methods.isEmpty {
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
                        Image(systemName: "chevron.right").font(Theme.font(10, .bold)).foregroundStyle(Theme.textTertiary)
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
                    Image(systemName: viewed ? "checkmark.circle.fill" : "circle")
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
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .cardBackground(Theme.surface, stroke: Theme.line2, radius: Theme.Radius.card, style: .continuous)
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
            Image(systemName: "text.bubble.fill").font(Theme.font(8)).foregroundStyle(Theme.iris).opacity(commented ? 1 : 0)
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
                                Button { drafts.remove(at: index) } label: { Image(systemName: "trash") }
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
