import AppKit
import SwiftUI

/// What you are writing or about to send on a pull request's page: shared by the ⋯ menu in the top bar, the write
/// button and the panel above the merge bar (PullRequestActionPanel).
@MainActor
final class PullRequestActionState: ObservableObject {
    enum Panel: Equatable { case none, write, reviewers, edit }

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

    /// What the panel would send now, or nil while it is not complete.
    func draft(_ detail: PullRequestDetail) -> PullRequestAction? {
        let action: PullRequestAction
        switch panel {
        case .none: return nil
        case .write: action = asReview ? .review(verdict, body: text) : .comment(text)
        case .reviewers: action = .requestReviewers([text])
        case .edit: action = .edit(title: title, body: text)
        }
        return action.request(repo: detail.repo, number: detail.number) == nil ? nil : action
    }
}

/// The ⋯ menu of a pull request: copy its link, number or checkout command, ask for reviews, edit it, bring
/// its branch up to date, close or reopen it. What changes GitHub goes through the confirmation in the action panel.
struct PullRequestMoreMenu: View {
    @ObservedObject var state: PullRequestActionState
    let detail: PullRequestDetail

    var body: some View {
        Menu {
            if let url = detail.url {
                Button(tr("agents.pr.copyLink")) { copy(url.absoluteString, tr("agents.pr.copiedLink")) }
            }
            Button(tr("agents.pr.action.copyNumber")) { copy("#\(detail.number)", tr("agents.pr.action.copied")) }
            Button(tr("agents.pr.action.copyCheckout")) { copy(Self.checkout(detail), tr("agents.pr.action.copied")) }
            if detail.isOpen {
                Divider()
                Button(tr("agents.pr.action.requestReviewers")) { state.open(.reviewers, detail: detail) }
                Button(tr("agents.pr.action.edit")) { state.open(.edit, detail: detail) }
                if detail.state == .draft, !detail.nodeID.isEmpty {
                    Button(tr("agents.pr.action.ready")) { ask(.markReady(nodeID: detail.nodeID)) }
                }
                if detail.mergeState == "behind" {
                    Button(tr("agents.pr.action.updateBranch")) { ask(.updateBranch(headSHA: detail.headSHA)) }
                }
                Divider()
                Button(tr("agents.pr.action.close"), role: .destructive) { ask(.close) }
            } else if detail.state == .closed {
                Divider()
                Button(tr("agents.pr.action.reopen")) { ask(.reopen) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(NookTheme.TextStyle.label)
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.pr.action.more"))
        .accessibilityLabel(tr("agents.pr.action.more"))
        .disabled(state.sending)
    }

    /// The command that checks the pull request out locally, as shown under the title.
    static func checkout(_ detail: PullRequestDetail) -> String {
        "gh pr checkout \(detail.number) --repo \(detail.repo)"
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.rowHover))
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
            HStack(spacing: NookTheme.Spacing.sm) {
                if state.asReview {
                    Menu {
                        ForEach(PullRequestAction.Verdict.allCases, id: \.self) { verdict in
                            Button(tr(Self.verdictKey(verdict))) { state.verdict = verdict }
                        }
                    } label: {
                        HStack(spacing: NookTheme.Spacing.xs) {
                            Image(systemName: Self.verdictSymbol(state.verdict))
                                .foregroundStyle(Self.verdictColor(state.verdict))
                            Text(tr(Self.verdictKey(state.verdict)))
                        }
                        .font(NookTheme.TextStyle.detail)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                send(title: tr(state.asReview ? "agents.pr.write.submitReview" : "agents.pr.write.send"))
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
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.smoke))
                .onSubmit { review() }
            HStack {
                Spacer(minLength: 0)
                send(title: tr("agents.pr.reviewers.send"))
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            header(tr("agents.pr.action.edit"))
            TextField(tr("agents.pr.edit.title"), text: $state.title)
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.strong)
                .padding(NookTheme.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.smoke))
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
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous).fill(NookTheme.smoke))
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
            Image(systemName: Self.symbol(action))
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
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            state.error = tr("agents.pr.noToken")
            return
        }
        let repo = detail.repo, number = detail.number
        let args = action.auditArgs(repo: repo, number: number)
        state.sending = true
        state.error = nil
        Task {
            do {
                try await GitHubPullRequestDetail.perform(action, repo: repo, number: number, token: token)
                app.store.audit(tool: action.auditTool, args: args, result: "ok")
                state.sending = false
                state.close()
                ToastCenter.shared.success(tr("agents.pr.action.done"))
                await model.refresh(activity: true)
                await PullRequestStore.shared.refresh(force: true)
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
        case .changeBase(let branch): return tr("agents.pr.confirm.changeBase", target, branch)
        }
    }

    static func symbol(_ action: PullRequestAction) -> String {
        switch action {
        case .review(let verdict, _): return verdictSymbol(verdict)
        case .comment: return "text.bubble"
        case .close: return "xmark.circle"
        case .reopen: return "arrow.uturn.backward.circle"
        case .edit: return "pencil"
        case .requestReviewers: return "person.badge.plus"
        case .updateBranch: return "arrow.triangle.2.circlepath"
        case .addLabels, .removeLabel: return "tag"
        case .markReady: return "eye"
        case .changeBase: return "arrow.triangle.branch"
        }
    }

    static func destructive(_ action: PullRequestAction) -> Bool {
        if case .close = action { return true }
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

    static func verdictSymbol(_ verdict: PullRequestAction.Verdict) -> String {
        switch verdict {
        case .comment: return "text.bubble"
        case .approve: return "checkmark.circle.fill"
        case .requestChanges: return "exclamationmark.circle.fill"
        }
    }

    static func verdictColor(_ verdict: PullRequestAction.Verdict) -> Color {
        switch verdict {
        case .comment: return NookTheme.textSecondary
        case .approve: return NookTheme.mint
        case .requestChanges: return NookTheme.amber
        }
    }
}
