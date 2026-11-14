import SwiftUI
import AppKit

/// The row under the box (where it works and the branch it starts from) and the notice under it.
extension NewSessionComposer {
    // MARK: Below the box

    var belowBox: some View {
        ComposerTray(edge: .bottom) { belowBoxRow }
    }

    private var belowBoxRow: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let remoteMachine {
                // On another machine: its folder, or a new worktree there (~/.nook/worktrees); git runs there over ssh.
                ComposerPill(symbol: "network", dot: nil, text: tr("ws.remote.via", remoteMachine.host), showsChevron: false)
                    .composerTip(tr("ws.remote.limits"))
                isolationDropdown(worktreeAllowed: true, reason: "")
                Spacer(minLength: 8)
                if config.isolation == .worktree {
                    Image(icon: "arrow.triangle.branch").font(NookTheme.font(10.5)).foregroundStyle(NookTheme.textTertiary)
                    TextField("", text: $config.baseBranch, prompt: Text(tr("ws.remote.baseCurrent")))
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.detail)
                        .frame(minWidth: 90, maxWidth: 150)
                        .composerTip(tr("ws.remote.baseHelp"))
                }
            } else {
                // A folder that is no git repository has no branch or worktree to choose.
                if project == nil || project?.repoRoot != nil {
                    isolationDropdown(worktreeAllowed: worktreeAllowed, reason: worktreeBlockedReason)
                }

                Spacer(minLength: 8)

                if config.isolation == .worktree, let branches = project?.branches, !branches.isEmpty {
                    ComposerDropdown(width: 280) {
                        // A long branch name is cut short, so the row stays inside a narrow tab.
                        ComposerPill(symbol: "arrow.triangle.branch", dot: nil, text: tr("compose.from", config.baseBranch))
                            .frame(maxWidth: 220)
                    } content: {
                        BranchPicker(branches: sortedBranches(branches), selected: config.baseBranch) { config.baseBranch = $0 }
                    }
                    .composerTip(tr("compose.from.help"))
                } else if let branch = project?.currentBranch {
                    ComposerPill(symbol: "arrow.triangle.branch", dot: nil, text: branch, showsChevron: false)
                        .frame(maxWidth: 220)
                        .composerTip(tr("compose.currentBranch.help"))
                }
            }
        }
    }

    /// Where the agent works: the folder as it is, or a new worktree.
    private func isolationDropdown(worktreeAllowed: Bool, reason: String) -> some View {
        ComposerDropdown(width: 300) {
            ComposerPill(symbol: config.isolation == .worktree ? "square.stack.3d.up" : "folder", dot: nil,
                 text: config.isolation == .worktree ? tr("compose.newWorktree") : tr("compose.currentCheckout"))
        } content: {
            DropdownHeader(title: tr("compose.whereWorks"))
            DropdownRow(symbol: "folder", title: tr("compose.currentCheckout"), detail: tr("compose.currentCheckoutDetail"),
                        chosen: config.isolation == .folder) {
                config.isolation = .folder
                remember()
            }
            DropdownRow(symbol: "square.stack.3d.up", title: tr("compose.newWorktree"), detail: tr("ws.new.worktreeExplain"),
                        chosen: config.isolation == .worktree, disabledReason: worktreeAllowed ? nil : reason) {
                config.isolation = .worktree
                remember()
            }
        }
        .composerTip(worktreeAllowed ? tr("ws.new.worktreeExplain") : reason)
    }

    /// One line, only when something needs saying: why you cannot start yet, or what went wrong.
    @ViewBuilder
    var notice: some View {
        if let link = promptLinks.pendingCheckout, let pull = link.pullRequest {
            // A pull request link no session works on: the checkout waits for you, as it runs the project's setup.
            PanelNoticeBar(title: tr("promptLink.pr.title", "\(pull.repository)#\(pull.number)"),
                           detail: tr("promptLink.pr.detail"), symbol: PullRequestIcon.generic, tone: NookTheme.amber) {
                if checkingOut {
                    ProgressView().controlSize(.small)
                } else {
                    NookNoticeActions(primary: NookNoticeAction(tr("promptLink.pr.checkout")) { checkOutLinkedPullRequest(link, pull) },
                                      secondary: NookNoticeAction(tr("button.cancel")) { promptLinks.pendingCheckout = nil })
                }
            }
            .padding(.horizontal, NookTheme.Spacing.md)
        } else if let error {
            InlineErrorText(error)
                .padding(.horizontal, NookTheme.Spacing.md)
        } else if let linkNotice {
            Text(linkNotice)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.amber)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
        } else if let remoteMachine {
            // On another machine the agent uses that machine's own login; what needs this Mac stays off.
            Text(tr("ws.remote.notice", remoteMachine.name))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NookTheme.Spacing.md)
        } else if config.provider == .antigravity, antigravity.installed == nil {
            AntigravitySetupRow().padding(.horizontal, NookTheme.Spacing.md)
        } else if let profile = app.profiles.profile(id: config.profileID), app.history.profileAccounts[profile.id] == nil {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("ws.new.accountNotLoggedIn")).foregroundStyle(NookTheme.amber)
                SmallGhostButton(title: tr("agents.login")) { app.connect(profile) }
            }
            .font(NookTheme.TextStyle.detail)
            .padding(.horizontal, NookTheme.Spacing.md)
        } else if !sharing.isEmpty, config.isolation == .folder {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(tr("ws.new.sharedWarning", sharing.map(\.title).joined(separator: ", ")))
                    .foregroundStyle(NookTheme.amber)
                    .lineLimit(2)
                Toggle(tr("ws.new.sharedAllow"), isOn: $allowShared).toggleStyle(.checkbox)
            }
            .font(NookTheme.TextStyle.detail)
            .padding(.horizontal, NookTheme.Spacing.md)
        } else if let reason = blockingReason, project != nil, hasTask {
            Text(reason)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.horizontal, NookTheme.Spacing.md)
        }
    }
}
