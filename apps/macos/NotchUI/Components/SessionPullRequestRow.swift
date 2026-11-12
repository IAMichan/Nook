import AppKit
import SwiftUI

/// A pull request in the session panel: the title on up to two lines, under it the number, how the checks stand, whether
/// the session watches it, and the one thing to do now (`PullRequestRowAction`): hand a conflict or failing checks to the
/// session, mark a draft ready, or merge, which asks for a second click. Resting on the row shows its branches and size.
struct SessionPullRequestRow: View {
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var workspace: WorkspaceManager
    @ObservedObject private var store = PullRequestStore.shared
    let link: PullRequestLink
    let glyph: PullRequestBadge.Glyph
    let runID: UUID?
    let directory: String
    let open: () -> Void
    @State private var armed = false
    @State private var running = false

    /// What the list knows of it: only GitHub's pull requests are listed, so another forge's row has no checks.
    private var listed: (account: String, item: PullRequestItem)? {
        let key = "\(link.repository)#\(link.number)".lowercased()
        return store.accounts.lazy.compactMap { account in
            (account.mine + account.reviews + account.watched).first { $0.id.lowercased() == key }.map { (account.id, $0) }
        }.first
    }

    private var watching: Bool {
        guard let runID, let url = URL(string: link.url) else { return false }
        return workspace.isWatching(runID, url: url)
    }

    private var ref: SessionPullRequestRef {
        SessionPullRequestRef(number: link.number, title: link.title ?? "", url: link.url, headBranch: link.headBranch ?? "", baseBranch: link.baseBranch ?? "")
    }

    var body: some View {
        let listed = listed
        let action = listed.flatMap { PullRequestRowAction.pick(open: link.state.isOpen, conflicted: link.conflicted, draft: link.state == .draft, checks: $0.item.ci) }
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            Button(action: open) {
                // The same 10 pt inset, 20 pt icon column and 10 pt gap as the panel's other rows, so the title lines
                // up under theirs.
                HStack(alignment: .top, spacing: 10) {
                    PullRequestStateIcon(glyph: glyph).frame(width: 20).padding(.top, 1)
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        Text(link.title ?? link.repository)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.paper)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: NookTheme.Spacing.xs) {
                            Text(verbatim: "#\(link.number)").font(NookTheme.mono(11)).foregroundStyle(NookTheme.textTertiary)
                            if let item = listed?.item, let outcome = item.checkOutcome, !link.conflicted, link.state != .draft {
                                CheckOutcomeGlyph(outcome: outcome).help(tr("agents.pulls.status." + outcome.rawValue))
                            }
                            if watching {
                                Image(icon: "eye")
                                    .font(NookTheme.font(10, .medium))
                                    .foregroundStyle(NookTheme.textTertiary)
                                    .help(tr("agents.pr.linked.watching"))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.nookPlain)
            if let action, let listed { actionButton(action, listed: listed).padding(.top, NookTheme.Spacing.xxs) }
        }
        .padding(.leading, 10)
        .padding(.trailing, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .hoverRowFill(radius: NookTheme.Radius.card)
        .help(link.url)
        .hoverCard(arrowEdge: .leading) {
            HoverCard(title: link.title ?? "#\(link.number)") {
                if let head = link.headBranch, let base = link.baseBranch {
                    HoverCardRow(symbol: "arrow.triangle.branch", text: base + " ← " + head)
                }
                if let item = listed?.item, let additions = item.additions, let deletions = item.deletions {
                    PullRequestLineCounts(additions: additions, deletions: deletions)
                }
            }
        }
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { armed = false }
        }
    }

    private func actionButton(_ action: PullRequestRowAction, listed: (account: String, item: PullRequestItem)) -> some View {
        let title: String = switch action {
        case .resolve: tr("agents.pr.row.resolve")
        case .ready: tr("agents.pr.row.ready")
        case .fix: tr("agents.pr.row.fix")
        case .merge: armed ? tr("agents.pr.confirmMerge") : tr("agents.pr.merge")
        }
        let tint = action == .resolve || action == .fix ? NookTheme.coral : NookTheme.textSecondary
        return Button {
            perform(action, listed: listed)
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                if running { ProgressView().controlSize(.mini) }
                Text(title)
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 22)
            .background(NookTheme.shape(NookTheme.Radius.control).strokeBorder(armed ? NookTheme.amber : NookTheme.line2))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
        }
        .buttonStyle(.nookPlain)
        .disabled(running)
        .fixedSize()
    }

    private func perform(_ action: PullRequestRowAction, listed: (account: String, item: PullRequestItem)) {
        let target = SessionContextTarget(run: runID, directory: directory)
        switch action {
        case .resolve:
            ComposerInbox.shared.add(SessionPrompts.resolveConflicts(ref), to: target)
        case .fix:
            run {
                guard let token = GitHubPullRequestDetail.token(accountID: listed.account) else { throw NookError(tr("agents.pr.noToken")) }
                let detail = try await GitHubPullRequestDetail.loadForMerge(repo: listed.item.repo, number: listed.item.number, token: token)
                ComposerInbox.shared.add(SessionPrompts.fixChecks(detail.sessionRef, failing: detail.failingCheckNames), to: target)
            }
        case .ready:
            run { try await PullRequestQuickRunner.run(.ready, item: listed.item, accountID: listed.account, app: app) }
        case .merge:
            guard armed else {
                armed = true
                return
            }
            armed = false
            run { try await PullRequestQuickRunner.run(.merge, item: listed.item, accountID: listed.account, app: app) }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        running = true
        Task {
            do {
                try await work()
                await PullRequestStore.shared.refresh(force: true)
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pulls.quick.failed", "#\(link.number)"))
            }
            running = false
        }
    }
}
