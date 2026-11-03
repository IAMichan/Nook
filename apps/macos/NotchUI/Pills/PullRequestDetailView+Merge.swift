import AppKit
import SwiftUI

/// Merging the pull request and its stack: the page's main action at the top right, what may hold it back, and
/// merging the stack up to here.
extension PullRequestDetailView {
    // MARK: Stack

    /// The pull requests to merge to land this one: from the bottom of the stack up to here.
    var stackToMerge: [PullRequestItem] {
        guard let index = stack.firstIndex(where: { $0.id == item.id }) else { return [] }
        return Array(stack[...index])
    }

    /// The stack this pull request stands in, bottom first: a click opens another one of it, and the last line merges
    /// the stack up to here.
    var stackMenu: some View {
        let index = (stack.firstIndex { $0.id == item.id } ?? 0) + 1
        return Menu {
            Section(tr("agents.pulls.stack.title", stack.count)) {
                ForEach(Array(stack.enumerated()), id: \.element.id) { position, member in
                    Button {
                        if member.id != item.id { onOpenPullRequest?(member) }
                    } label: {
                        let mark = member.id == item.id ? "✓ " : ""
                        Text(mark + "\(position + 1). #\(member.number) \(member.title)")
                    }
                    .disabled(onOpenPullRequest == nil && member.id != item.id)
                }
            }
            if stackToMerge.count > 1 {
                Divider()
                Button(tr("agents.pulls.stack.merge", stackToMerge.count)) { confirmStackMerge = true }
                    .disabled(mergingStack)
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                PullRequestStateIcon(glyph: .stack, tinted: false)
                Text("\(index)/\(stack.count)").font(NookTheme.TextStyle.caption).monospacedDigit()
            }
            .foregroundStyle(NookTheme.textSecondary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.pulls.stack.position", index, stack.count))
    }

    /// "Merge #1, #2 and #3 from the bottom up?" with its second click, or the progress while it runs.
    var stackMergeBar: some View {
        let numbers = stackToMerge.map { "#\($0.number)" }.joined(separator: ", ")
        return Group {
            if mergingStack {
                HStack(spacing: NookTheme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text(tr("agents.pulls.stack.merging", numbers)).foregroundStyle(NookTheme.textSecondary)
                }
            } else {
                AdaptiveActionRow {
                    HStack(spacing: NookTheme.Spacing.md) {
                        PullRequestStateIcon(glyph: .merged)
                        Text(tr("agents.pulls.stack.confirm", numbers)).foregroundStyle(NookTheme.paper)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } actions: {
                    SmallGhostButton(title: tr("button.cancel")) { confirmStackMerge = false }
                    SmallPrimaryButton(title: tr("agents.pulls.stack.mergeConfirm")) { mergeStack() }
                }
            }
        }
        .font(NookTheme.TextStyle.body)
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
    }

    func mergeStack() {
        let targets = stackToMerge
        confirmStackMerge = false
        mergingStack = true
        model.paused = true
        Task {
            defer { model.paused = false }
            do {
                let merged = try await PullRequestQuickRunner.mergeStack(targets, accountID: accountID, app: app)
                ToastCenter.shared.success(tr("agents.pulls.stack.merged", merged))
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pulls.stack.failed"))
            }
            mergingStack = false
            await model.refresh(activity: true)
            await PullRequestStore.shared.refresh(force: true)
        }
    }

    // MARK: Merging

    /// The page's main action at the top right: merge an open pull request, mark a draft ready, or say
    /// what it is (merged, closed, in conflict) when there is nothing to do.
    @ViewBuilder
    func primaryAction(_ detail: PullRequestDetail) -> some View {
        switch detail.state {
        case .merged, .closed:
            PullRequestStateBadge(glyph: glyph)
        case .draft:
            if !detail.nodeID.isEmpty, detail.canPush != false {
                SmallPrimaryButton(title: tr("agents.pr.action.ready"), systemName: PullRequestIcon.symbol(.open)) {
                    actions.close()
                    actions.pending = .markReady(nodeID: detail.nodeID)
                }
                .disabled(actions.sending)
            } else {
                PullRequestStateBadge(glyph: .draft)
            }
        case .open:
            if detail.conflicted {
                PullRequestStateBadge(glyph: .conflict).help(tr("agents.pr.note.conflict"))
            } else if detail.canPush != false && !detail.methods.isEmpty {
                mergeButton(detail)
            }
        }
    }

    /// Merge with its method beside it. The first click arms it, the second merges; beside it, what GitHub may still hold
    /// it back on (branch protection, a branch that is behind, failing checks), named in a few words.
    func mergeButton(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if let note = detail.mergeNote, detail.canMerge {
                mergeBlocker(note, detail: detail)
            }
            if merging { ProgressView().controlSize(.small) }
            SmallPrimaryButton(title: merging ? tr("agents.pr.merging") : armedMerge ? tr("agents.pr.confirmMerge") : tr("agents.pr.merge"),
                               systemName: armedMerge ? "checkmark" : PullRequestIcon.symbol(.merged)) {
                if armedMerge {
                    armedMerge = false
                    merge()
                } else {
                    armMerge()
                }
            }
            .disabled(!detail.canMerge || merging)
            .help(armedMerge ? confirmMessage : tr(method.titleKey))
            ComposerDropdown(width: 240) {
                Image(systemName: "chevron.down")
                    .font(NookTheme.font(9, .bold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: 18, height: 28)
                    .contentShape(Rectangle())
            } content: {
                DropdownHeader(title: tr("agents.pr.mergeMethod.title"))
                ForEach(detail.methods) { option in
                    DropdownRow(title: tr(option.titleKey), chosen: option == method) {
                        methodRaw = option.rawValue
                    }
                }
            }
            .disabled(merging)
            .help(tr("agents.pr.mergeMethod.title"))
        }
    }

    /// What may still hold the merge back, in its own mark and a few words ("Branch protection", "Behind main",
    /// "Checks failing"); a click shows GitHub's whole reason.
    func mergeBlocker(_ note: String, detail: PullRequestDetail) -> some View {
        let reason = String(note.split(separator: ".").last ?? "")
        let look: (symbol: String, color: Color, label: String) = switch reason {
        case "blocked": (PullRequestIcon.blocked, PullRequestIcon.blockerTint, tr("agents.pr.blocker.blocked"))
        case "behind": (PullRequestIcon.behind, PullRequestIcon.blockerTint, tr("agents.pr.blocker.behind", detail.baseBranch))
        case "unstable": (PullRequestIcon.symbol(PullRequestCheck.Outcome.failing), PullRequestIcon.tint(PullRequestCheck.Outcome.failing),
                          tr("agents.pr.blocker.unstable"))
        case "checksRunning": (PullRequestIcon.symbol(PullRequestCheck.Outcome.pending), PullRequestIcon.tint(PullRequestCheck.Outcome.pending),
                               tr("agents.pr.blocker.checksRunning"))
        case "checking": (PullRequestIcon.symbol(PullRequestCheck.Outcome.pending), PullRequestIcon.tint(PullRequestCheck.Outcome.pending),
                          tr("agents.pr.blocker.checking"))
        default: ("info.circle", NookTheme.textTertiary, tr(note))
        }
        return Button {
            showBlocker.toggle()
        } label: {
            Image(systemName: look.symbol)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(look.color)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(look.label + " · " + tr(note))
        .accessibilityLabel(look.label)
        .popover(isPresented: $showBlocker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(look.label).font(NookTheme.TextStyle.strong).foregroundStyle(look.color)
                Text(tr(note))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                // Updating a branch that is behind is on the Summary's Status line and in the ⋯ menu, not here too.
            }
            .padding(NookTheme.Spacing.lg)
            .frame(width: 280, alignment: .leading)
        }
    }

    func armMerge() {
        let token = UUID()
        armToken = token
        withAnimation(NookTheme.hover) { armedMerge = true }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if armToken == token { withAnimation(NookTheme.hover) { armedMerge = false } }
        }
    }

    var confirmMessage: String {
        var text = tr("agents.pr.confirmMessage", detail?.headBranch ?? "", tr(method.titleKey))
        if let detail, detail.checkSummary != .passing, !detail.checks.isEmpty { text += "\n" + tr("agents.pr.confirmChecks") }
        return text
    }

    /// Only after the confirmation: merges the head that is shown, and writes the outcome to the action log.
    func merge() {
        guard let detail, detail.canMerge, !merging else { return }
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else {
            ToastCenter.shared.error(tr("agents.pr.noToken"))
            return
        }
        let method = self.method
        let args = "\(detail.id) · \(method.rawValue) · \(detail.headBranch) → \(detail.baseBranch)"
        merging = true
        model.paused = true
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
                    ToastCenter.shared.error(error, title: tr("agents.pr.mergeFailed"))
                }
            }
        }
    }

    /// Shows the merge at once, here, in the list and on the agent rows, without waiting for GitHub's next answers.
    func settle() {
        merging = false
        model.markMerged()
        ToastCenter.shared.success(tr("agents.pr.state.merged"))
    }
}
