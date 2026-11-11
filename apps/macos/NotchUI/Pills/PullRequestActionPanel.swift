import AppKit
import SwiftUI

/// What you are writing or about to send on a pull request's page: shared by the ⋯ menu in the top bar, the write
/// button and the panel above the merge bar (PullRequestActionPanel).
@MainActor
final class PullRequestActionState: ObservableObject {
    enum Panel: Equatable { case none, write, reviewers, edit, labels }

    @Published var panel: Panel = .none
    /// An action waiting for your second click (confirmed inline, never in a separate dialog).
    @Published var pending: PullRequestAction?
    @Published var sending = false
    @Published var error: String?
    @Published var text = ""
    @Published var title = ""
    /// Writing a review (with a verdict) instead of a plain comment.
    @Published var asReview = false
    @Published var verdict: PullRequestAction.Verdict = .comment
    /// Who can be asked for a review, offered as chips under the reviewer field. Nil until GitHub answered.
    @Published var candidates: [String]?
    /// The repository's labels to pick from, with their colors. Nil until GitHub answered.
    @Published var labelChoices: [PullRequestLabelChoice]?
    /// Line comments of the Code tab, waiting for the review.
    @Published var lineComments: [PullRequestPendingComment] = [] {
        didSet { Self.keptComments[key] = lineComments }
    }
    /// Counts what went through, so an editor in a comment card closes when its text was sent.
    @Published var finished = 0
    private let key: String
    /// The waiting comments per pull request, while Nook runs.
    private static var keptComments: [String: [PullRequestPendingComment]] = [:]

    init(pullRequest key: String = "") {
        self.key = key
        lineComments = Self.keptComments[key] ?? []
    }

    func open(_ panel: Panel, detail: PullRequestDetail) {
        error = nil
        pending = nil
        if panel == .edit {
            title = detail.title
            text = detail.body
        } else if panel != self.panel {
            text = ""
        }
        self.panel = panel
    }

    func close() {
        panel = .none
        pending = nil
        error = nil
        text = ""
    }

    /// The logins typed or picked in the reviewer field.
    var chosenReviewers: [String] { PullRequestAction.logins([text]) }

    func isChosen(_ login: String) -> Bool {
        chosenReviewers.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
    }

    /// Picks a reviewer from the chips, or puts one back.
    func toggle(_ login: String) {
        var logins = chosenReviewers
        if let index = logins.firstIndex(where: { $0.caseInsensitiveCompare(login) == .orderedSame }) {
            logins.remove(at: index)
        } else {
            logins.append(login)
        }
        text = logins.joined(separator: ", ")
    }

    /// The chips to offer: the ones picked, and the others matching what is being typed after the last comma.
    func offered(limit: Int = 16) -> [String] {
        let typed = text.split(separator: ",", omittingEmptySubsequences: false).last
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@")) } ?? ""
        let matching = (candidates ?? []).filter { login in
            isChosen(login) || typed.isEmpty || login.range(of: typed, options: .caseInsensitive) != nil
        }
        return Array(matching.prefix(limit))
    }

    /// What the panel would send now, or nil while it is not complete.
    func draft(_ detail: PullRequestDetail) -> PullRequestAction? {
        let action: PullRequestAction
        switch panel {
        case .none: return nil
        case .write:
            if lineComments.isEmpty {
                action = asReview ? .review(verdict, body: text) : .comment(text)
            } else {
                action = .reviewWithComments(verdict, body: text, commit: detail.headSHA, comments: lineComments.map(\.action))
            }
        case .reviewers: action = .requestReviewers([text])
        case .edit: action = .edit(title: title, body: text)
        case .labels: return nil
        }
        return action.request(repo: detail.repo, number: detail.number) == nil ? nil : action
    }
}

/// The ⋯ menu of a pull request, in Nook's own dropdown panel: refresh it, copy its link, number or checkout command,
/// ask for reviews, edit it, mark it ready for review or turn it back into a draft, bring its branch up to date, close or
/// reopen it. While GitHub is asked the ⋯ spins.
/// What changes GitHub goes through the confirmation in the action panel.
struct PullRequestMoreMenu: View {
    @ObservedObject var state: PullRequestActionState
    let detail: PullRequestDetail
    @Environment(\.sessionContextTarget) private var session
    var loading = false
    /// When the page last heard from GitHub, said in the menu's tooltip.
    var fetchedAt: Date? = nil
    var onRefresh: (() -> Void)? = nil
    /// Your login with the account this page reads with; empty when unknown.
    var viewer = ""
    /// The merge method auto-merge would use.
    var method = PullRequestMergeMethod.merge
    /// The forge it lives on, for what fetching it takes.
    var host = SourceControlHost.github
    var onWriteGuide: (() -> Void)? = nil

    var body: some View {
        ComposerDropdown(width: 248) {
            Group {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(icon: "ellipsis")
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        } content: {
            if let onRefresh {
                DropdownRow(symbol: "arrow.clockwise", title: tr("agents.pulls.refresh"), action: onRefresh)
                DropdownDivider()
            }
            if detail.isOpen {
                DropdownRow(symbol: "arrow.triangle.branch", title: tr("agents.pr.checkout.worktree")) { checkOut { app, plan in
                    try await app.checkOutInWorktree(plan, preferred: session?.directory)
                } }
                DropdownRow(symbol: "folder", title: tr("agents.pr.checkout.here")) { checkOut { app, plan in
                    try await app.checkOutHere(plan, preferred: session?.directory)
                } }
                ForEach(RemoteMachines.load()) { machine in
                    DropdownRow(symbol: "server.rack", title: tr("agents.pr.checkout.on", machine.name)) { checkOut { app, plan in
                        try await app.checkOut(plan, on: machine, pull: detail.sessionRef)
                    } }
                }
                DropdownDivider()
            }
            if let onWriteGuide {
                DropdownRow(symbol: "map", title: tr("agents.pr.guide.write"), action: onWriteGuide)
            }
            if let url = detail.url {
                DropdownRow(symbol: "arrow.up.right", title: host == .github ? tr("agents.pulls.open") : tr("agents.pr.openInBrowser")) { NSWorkspace.shared.open(url) }
                DropdownRow(symbol: "link", title: tr("agents.pr.copyLink")) {
                    copy(url.absoluteString, tr("agents.pr.copiedLink"))
                }
            }
            DropdownRow(symbol: "number", title: tr("agents.pr.action.copyNumber")) {
                copy("#\(detail.number)", tr("agents.pr.action.copied"))
            }
            DropdownRow(symbol: "terminal", title: tr("agents.pr.action.copyCheckout")) {
                copy(Self.checkout(detail), tr("agents.pr.action.copied"))
            }
            if let session {
                DropdownDivider()
                DropdownRow(symbol: "text.bubble", title: tr("session.context.explain")) {
                    ComposerInbox.shared.add(SessionPrompts.explain(detail.sessionRef), to: session)
                }
                DropdownRow(symbol: "plus.bubble", title: tr("session.context.ask")) {
                    ComposerInbox.shared.add(SessionPrompts.ask(detail.sessionRef), to: session)
                }
                if !detail.sessionFindings.isEmpty {
                    // The comments that ask for something, with the failing checks in one message.
                    DropdownRow(symbol: "hammer", title: tr("session.context.fixFindings")) {
                        ComposerInbox.shared.add(SessionPrompts.fixFindings(detail.sessionRef, comments: detail.sessionFindings,
                                                                            failing: detail.failingCheckNames), to: session)
                    }
                } else if !detail.failingCheckNames.isEmpty {
                    DropdownRow(symbol: "hammer", title: tr("session.context.fixChecks")) {
                        ComposerInbox.shared.add(SessionPrompts.fixChecks(detail.sessionRef, failing: detail.failingCheckNames), to: session)
                    }
                }
            }
            if detail.isOpen {
                DropdownDivider()
                if detail.features.reviewers {
                    DropdownRow(symbol: "person.badge.plus", title: tr("agents.pr.action.requestReviewers")) {
                        state.open(.reviewers, detail: detail)
                    }
                }
                DropdownRow(symbol: "pencil", title: tr("agents.pr.action.edit")) { state.open(.edit, detail: detail) }
                if !detail.features.draft {
                    EmptyView()
                } else if detail.state == .draft, !detail.nodeID.isEmpty {
                    DropdownRow(symbol: PullRequestIcon.symbol(.open), title: tr("agents.pr.action.ready")) {
                        ask(.markReady(nodeID: detail.nodeID))
                    }
                } else if detail.state == .open, !detail.nodeID.isEmpty {
                    DropdownRow(symbol: PullRequestIcon.symbol(.draft), title: tr("agents.pr.action.draft")) {
                        ask(.markDraft(nodeID: detail.nodeID))
                    }
                }
                if detail.mergeState == "behind", detail.features.updateBranch {
                    DropdownRow(symbol: PullRequestIcon.behind, title: tr("agents.pr.action.updateBranch")) {
                        ask(.updateBranch(headSHA: detail.headSHA))
                    }
                    DropdownRow(symbol: PullRequestIcon.behind, title: tr("agents.pr.action.rebaseBranch")) {
                        ask(.rebaseBranch(nodeID: detail.nodeID, headSHA: detail.headSHA))
                    }
                }
                if !detail.features.autoMerge {
                    EmptyView()
                } else if detail.autoMerge != nil, !detail.nodeID.isEmpty {
                    DropdownRow(symbol: "bolt.slash", title: tr("agents.pr.action.disableAutoMerge")) { ask(.disableAutoMerge(nodeID: detail.nodeID)) }
                } else if detail.autoMergeAllowed, detail.state == .open, detail.canPush != false, !detail.conflicted, !detail.nodeID.isEmpty {
                    DropdownRow(symbol: "bolt", title: tr("agents.pr.action.enableAutoMerge")) {
                        ask(.enableAutoMerge(nodeID: detail.nodeID, method: method))
                    }
                }
                if detail.canPush != false, detail.features.labels { DropdownRow(symbol: "tag", title: tr("agents.pr.action.labels")) { state.open(.labels, detail: detail) } }
                // Only the author of a fork's pull request decides this.
                if detail.headOwner != nil, !viewer.isEmpty, viewer.lowercased() == detail.author.lowercased() {
                    DropdownRow(symbol: detail.maintainerEdits ? "checkmark.square.fill" : "square", title: tr("agents.pr.action.maintainerEdits"),
                                chosen: detail.maintainerEdits) { ask(.setMaintainerEdits(!detail.maintainerEdits)) }
                }
                DropdownDivider()
                DropdownRow(symbol: PullRequestIcon.symbol(.closed), title: tr("agents.pr.action.close"), tint: PullRequestIcon.tint(.closed)) {
                    ask(.close)
                }
            } else if detail.state == .closed {
                DropdownDivider()
                DropdownRow(symbol: PullRequestIcon.symbol(.open), title: tr("agents.pr.action.reopen")) { ask(.reopen) }
            }
            if detail.state == .merged, detail.canPush != false, !detail.nodeID.isEmpty, detail.features.revert {
                DropdownDivider()
                DropdownRow(symbol: "arrow.uturn.backward", title: tr("agents.pr.action.revert")) { ask(.revert(nodeID: detail.nodeID)) }
            }
            if !detail.isOpen, detail.canPush != false, let repository = detail.headRepository, !detail.branchDeleted, detail.features.deleteBranch {
                DropdownRow(symbol: "trash", title: tr("agents.pr.action.deleteBranch"), tint: PullRequestIcon.tint(.closed)) {
                    ask(.deleteBranch(repository: repository, branch: detail.headBranch))
                }
            }
        }
        .help(fetchedAt.map { tr("agents.pr.action.more") + " · " + tr("agents.pulls.updatedAgo", AgentFormat.short(Date().timeIntervalSince($0))) }
              ?? tr("agents.pr.action.more"))
        .accessibilityLabel(tr("agents.pr.action.more"))
        .disabled(state.sending)
    }

    /// The command that checks the pull request out locally, as shown under the title.
    static func checkout(_ detail: PullRequestDetail) -> String {
        "gh pr checkout \(detail.number) --repo \(detail.repo)"
    }

    private func checkOut(_ work: @escaping (AppModel, PullRequestCheckoutPlan) async throws -> Void) {
        let plan = PullRequestCheckoutPlan(host: host, repository: detail.repo, number: detail.number, headBranch: detail.headBranch, fork: detail.headOwner != nil)
        Task {
            do {
                try await work(AppModel.shared, plan)
                ToastCenter.shared.success(tr("agents.pr.checkout.done", plan.branch))
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pr.checkout.failed"))
            }
        }
    }

    private func ask(_ action: PullRequestAction) {
        state.close()
        state.pending = action
    }

    private func copy(_ text: String, _ toast: String) {
        Pasteboard.copy(text)
        ToastCenter.shared.success(toast)
    }
}

/// Above the merge bar: the composer (a comment, or a review that approves, requests changes or only comments), the
/// field for reviewers, the editor for title and description, and the confirmation of whatever is about to be sent.
/// Every action goes to GitHub only after your second click, and is written to the action log.
struct PullRequestActionPanel: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.sessionContextTarget) private var session
    @ObservedObject var state: PullRequestActionState
    @ObservedObject var model: PullRequestDetailModel
    let accountID: String
    let detail: PullRequestDetail

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            if let pending = state.pending {
                confirmation(pending)
            } else {
                switch state.panel {
                case .none: EmptyView()
                case .write: composer
                case .reviewers: reviewers
                case .edit: editor
                case .labels: labels
                }
            }
            if let error = state.error {
                HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
                    Text(error)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    // An action from the ⋯ menu has no panel of its own to close with it.
                    if state.panel == .none {
                        ToolbarIconButton("xmark", tr("button.cancel")) { state.error = nil }
                    }
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.rowHover, radius: NookTheme.Radius.panel)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.sm) {
                NookTabBar<Bool>(items: [
                    .init(value: false, title: tr("agents.pr.write.comment")),
                    .init(value: true, title: tr("agents.pr.write.review")),
                ], selected: state.asReview) { value in state.asReview = value }
                Spacer(minLength: 0)
                ToolbarIconButton("xmark", tr("button.cancel")) { state.close() }
            }
            field(placeholder: tr(state.asReview ? "agents.pr.write.reviewPlaceholder" : "agents.pr.write.commentPlaceholder"))
            if !state.lineComments.isEmpty {
                Text(tr("agents.pr.code.pending", state.lineComments.count))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.amber)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if state.asReview || !state.lineComments.isEmpty {
                    Menu {
                        ForEach(PullRequestAction.Verdict.allCases.filter { $0 == .comment || detail.features.verdicts }, id: \.self) { verdict in
                            Button(tr(Self.verdictKey(verdict))) { state.verdict = verdict }
                        }
                    } label: {
                        HStack(spacing: NookTheme.Spacing.xs) {
                            Image(icon: Self.verdictSymbol(state.verdict))
                                .foregroundStyle(Self.verdictColor(state.verdict))
                            Text(tr(Self.verdictKey(state.verdict)))
                        }
                        .font(NookTheme.TextStyle.detail)
                    }
                    .menuStyle(.nookBorderlessButton)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                send(title: tr(state.asReview || !state.lineComments.isEmpty ? "agents.pr.write.submitReview" : "agents.pr.write.send"))
            }
        }
    }

    private var reviewers: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header(tr("agents.pr.action.requestReviewers"))
            TextField(tr("agents.pr.reviewers.placeholder"), text: $state.text)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .padding(NookTheme.Spacing.sm)
                .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.chip)
                .onSubmit { review() }
            if state.candidates == nil {
                ProgressView().controlSize(.small)
            } else if !state.offered().isEmpty {
                ChipFlow(spacing: NookTheme.Spacing.xs) {
                    ForEach(state.offered(), id: \.self) { login in candidate(login) }
                }
            }
            HStack {
                Spacer(minLength: 0)
                send(title: tr("agents.pr.reviewers.send"))
            }
        }
        .task(id: detail.id) { await loadCandidates() }
    }

    /// One person who can be asked: their picture and login, filled with the accent once picked.
    private func candidate(_ login: String) -> some View {
        let chosen = state.isChosen(login)
        return Button { state.toggle(login) } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                GitHubAvatar(login: login, size: 16)
                Text(login).font(NookTheme.TextStyle.label)
                if chosen { Image(icon: "checkmark").font(NookTheme.font(9, .bold)) }
            }
            .foregroundStyle(chosen ? NookTheme.onIris : NookTheme.textStrong)
            .padding(.leading, NookTheme.Spacing.xxs)
            .padding(.trailing, NookTheme.Spacing.sm)
            .padding(.vertical, NookTheme.Spacing.xxs)
            .background(NookTheme.shape(NookTheme.Radius.control).fill(chosen ? NookTheme.iris : NookTheme.smoke))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .help(tr(chosen ? "agents.pr.reviewers.remove" : "agents.pr.reviewers.add", "@" + login))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Asks GitHub once per page who can review; without an answer the field still takes names typed by hand.
    private func loadCandidates() async {
        guard state.candidates == nil else { return }
        if PullRequestForges.repository(account: accountID, path: detail.repo) != nil {
            state.candidates = []
            return
        }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            state.candidates = []
            return
        }
        state.candidates = await GitHubPullRequestDetail.reviewerCandidates(for: detail, token: token)
    }

    /// The repository's labels as chips: the ones on the pull request filled, a click adds or takes one off, with the
    /// usual second click.
    private var labels: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header(tr("agents.pr.action.labels"))
            if let choices = state.labelChoices {
                ChipFlow(spacing: NookTheme.Spacing.xs) {
                    ForEach(choices, id: \.name) { label in
                        let on = detail.labels.contains(label.name)
                        Button {
                            state.pending = on ? .removeLabel(label.name) : .addLabels([label.name])
                        } label: {
                            HStack(spacing: NookTheme.Spacing.xs) {
                                LabelChip(name: label.name, color: label.color, description: label.description)
                                if on { Image(icon: "checkmark").font(NookTheme.font(9, .bold)).foregroundStyle(NookTheme.paper) }
                            }
                        }
                        .buttonStyle(.nookPlain)
                        // The button's own tip covers the chip's, so it carries the description too.
                        .help(tr(on ? "agents.pr.labels.remove" : "agents.pr.labels.add", label.name)
                              + (label.description.isEmpty ? "" : "\n" + label.description))
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: detail.repo) {
            guard state.labelChoices == nil else { return }
            if let forge = PullRequestForges.client(account: accountID, path: detail.repo) {
                state.labelChoices = await forge.labels()
                return
            }
            guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
                state.labelChoices = []
                return
            }
            state.labelChoices = await GitHubPullRequestDetail.repositoryLabels(repo: detail.repo, token: token)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header(tr("agents.pr.action.edit"))
            TextField(tr("agents.pr.edit.title"), text: $state.title)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.strong)
                .padding(NookTheme.Spacing.sm)
                .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.chip)
            field(placeholder: tr("agents.pr.edit.body"))
            HStack {
                Spacer(minLength: 0)
                send(title: tr("agents.pr.edit.save"))
            }
        }
    }

    private func header(_ title: String) -> some View {
        HStack {
            Text(title).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
            Spacer(minLength: 0)
            ToolbarIconButton("xmark", tr("button.cancel")) { state.close() }
        }
    }

    private func field(placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if state.text.isEmpty {
                Text(placeholder)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textTertiary)
                    .padding(.horizontal, NookTheme.Spacing.xs)
                    .padding(.vertical, NookTheme.Spacing.xxs)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $state.text)
                .font(NookTheme.TextStyle.body)
                .scrollContentBackground(.hidden)
        }
        .frame(height: 96)
        .padding(NookTheme.Spacing.sm)
        .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.chip)
    }

    private func send(title: String) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if state.sending { ProgressView().controlSize(.small) }
            SmallPrimaryButton(title: title) { review() }
                .disabled(state.sending || state.draft(detail) == nil)
        }
    }

    /// The first click: shows what will be sent and waits for the second.
    private func review() {
        guard let action = state.draft(detail), !state.sending else { return }
        state.error = nil
        state.pending = action
    }

    // MARK: Confirmation

    private func confirmation(_ action: PullRequestAction) -> some View {
        HStack(spacing: 10) {
            NookSymbol(Self.symbol(action), size: 13)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(Self.destructive(action) ? NookTheme.coral : NookTheme.amber)
            Text(Self.question(action, detail: detail))
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if state.sending { ProgressView().controlSize(.small) }
            SmallGhostButton(title: tr("button.cancel")) { state.pending = nil }
                .disabled(state.sending)
            SmallPrimaryButton(title: tr("agents.pr.action.confirm")) { perform(action) }
                .disabled(state.sending)
        }
    }

    /// Only after the second click: sends the action with the account the pull request was listed under, writes the
    /// outcome to the action log and reads the pull request again.
    private func perform(_ action: PullRequestAction) {
        let forge = PullRequestForges.client(account: accountID, path: detail.repo)
        guard let token = forge == nil ? GitHubPullRequestDetail.token(accountID: accountID) : "" else {
            state.error = tr("agents.pr.noToken")
            return
        }
        let repo = detail.repo, number = detail.number
        let args = action.auditArgs(repo: repo, number: number)
        state.sending = true
        state.error = nil
        Task {
            do {
                let made: String?
                var reply: PullRequestActionReply?
                if let forge {
                    made = try await forge.perform(action, number: number, detail: detail)
                } else {
                    reply = try await GitHubPullRequestDetail.perform(action, repo: repo, number: number, token: token)
                    made = reply?.made
                }
                app.store.audit(tool: action.auditTool, args: args, result: "ok")
                state.sending = false
                let keepsPanel = state.panel == .labels
                let panel = state.panel
                state.close()
                if keepsPanel { state.panel = panel }
                state.finished += 1
                if case .reviewWithComments = action { state.lineComments = [] }
                // A revert is a new pull request of its own: it opens beside this one.
                if let made, let url = URL(string: made), !app.openPullRequestLink(url, beside: session != nil) { NSWorkspace.shared.open(url) }
                ToastCenter.shared.success(tr("agents.pr.action.done"))
                // What GitHub answered shows at once; the page then reads only what the answer leaves out (the timeline).
                if let reply { model.apply(reply) }
                await model.refresh(activity: true)
                if action.needsListRead {
                    await PullRequestStore.shared.refresh(force: true)
                } else {
                    PullRequestStore.shared.rereadAfterAction()
                }
            } catch {
                app.store.audit(tool: action.auditTool, args: args, result: "error: " + error.localizedDescription)
                state.sending = false
                state.pending = nil
                state.error = error.localizedDescription
            }
        }
    }

    // MARK: Words and looks

    static func question(_ action: PullRequestAction, detail: PullRequestDetail) -> String {
        let target = "#\(detail.number)"
        switch action {
        case .review(let verdict, _): return tr("agents.pr.confirm.review", tr(verdictKey(verdict)), target)
        case .comment: return tr("agents.pr.confirm.comment", target)
        case .close: return tr("agents.pr.confirm.close", target)
        case .reopen: return tr("agents.pr.confirm.reopen", target)
        case .edit: return tr("agents.pr.confirm.edit", target)
        case .requestReviewers(let people):
            return tr("agents.pr.confirm.reviewers", PullRequestAction.logins(people).map { "@" + $0 }.joined(separator: ", "), target)
        case .updateBranch: return tr("agents.pr.confirm.updateBranch", detail.baseBranch, detail.headBranch)
        case .addLabels, .removeLabel: return tr("agents.pr.confirm.labels", target)
        case .markReady: return tr("agents.pr.confirm.ready", target)
        case .markDraft: return tr("agents.pr.confirm.draft", target)
        case .changeBase(let branch): return tr("agents.pr.confirm.changeBase", target, branch)
        case .approveWorkflow: return tr("agents.pr.confirm.approveWorkflow", target)
        case .reviewWithComments(let verdict, _, _, _): return tr("agents.pr.confirm.review", tr(verdictKey(verdict)), target)
        case .reply: return tr("agents.pr.confirm.reply", target)
        case .setThreadResolved(_, let resolved): return tr(resolved ? "agents.pr.thread.resolve" : "agents.pr.thread.unresolve")
        case .editComment: return tr("agents.pr.confirm.editComment", target)
        case .rebaseBranch: return tr("agents.pr.confirm.rebaseBranch", detail.headBranch, detail.baseBranch)
        case .deleteBranch(_, let branch): return tr("agents.pr.confirm.deleteBranch", branch)
        case .revert: return tr("agents.pr.confirm.revert", target)
        case .setMaintainerEdits(let allowed): return tr(allowed ? "agents.pr.confirm.maintainerOn" : "agents.pr.confirm.maintainerOff", target)
        case .enableAutoMerge(_, let method): return tr("agents.pr.confirm.autoMergeOn", target, tr(method.titleKey))
        case .disableAutoMerge: return tr("agents.pr.confirm.autoMergeOff", target)
        }
    }

    static func symbol(_ action: PullRequestAction) -> String {
        switch action {
        case .review(let verdict, _): return verdictSymbol(verdict)
        case .comment: return PullRequestIcon.symbol(PullRequestIcon.Review.commented)
        // An action shows the mark of the state it leads to.
        case .close: return PullRequestIcon.symbol(.closed)
        case .reopen: return PullRequestIcon.symbol(.open)
        case .edit: return "pencil"
        case .requestReviewers: return "person.badge.plus"
        case .updateBranch: return PullRequestIcon.behind
        case .addLabels, .removeLabel: return "tag"
        case .markReady: return PullRequestIcon.symbol(.open)
        case .markDraft: return PullRequestIcon.symbol(.draft)
        case .changeBase: return "arrow.triangle.branch"
        case .approveWorkflow: return "checkmark.shield"
        case .reviewWithComments(let verdict, _, _, _): return verdictSymbol(verdict)
        case .reply, .editComment: return PullRequestIcon.symbol(PullRequestIcon.Review.commented)
        case .setThreadResolved: return "checkmark.circle"
        case .rebaseBranch: return PullRequestIcon.behind
        case .deleteBranch: return "trash"
        case .revert: return "arrow.uturn.backward"
        case .setMaintainerEdits: return "person.2"
        case .enableAutoMerge: return "bolt"
        case .disableAutoMerge: return "bolt.slash"
        }
    }

    static func destructive(_ action: PullRequestAction) -> Bool {
        if case .close = action { return true }
        if case .deleteBranch = action { return true }
        if case .revert = action { return true }
        if case .review(.requestChanges, _) = action { return true }
        return false
    }

    static func verdictKey(_ verdict: PullRequestAction.Verdict) -> String {
        switch verdict {
        case .comment: return "agents.pr.verdict.comment"
        case .approve: return "agents.pr.verdict.approve"
        case .requestChanges: return "agents.pr.verdict.requestChanges"
        }
    }

    static func verdictSymbol(_ verdict: PullRequestAction.Verdict) -> String { PullRequestIcon.symbol(verdictIcon(verdict)) }

    static func verdictColor(_ verdict: PullRequestAction.Verdict) -> Color { PullRequestIcon.tint(verdictIcon(verdict)) }

    private static func verdictIcon(_ verdict: PullRequestAction.Verdict) -> PullRequestIcon.Review {
        switch verdict {
        case .comment: return .commented
        case .approve: return .approved
        case .requestChanges: return .changesRequested
        }
    }
}
