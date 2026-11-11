import AppKit
import SwiftUI

/// Merging the pull request and its stack: the page's main action at the top right, what may hold it back, and
/// merging the stack up to here.
extension PullRequestDetailView {
    // MARK: Stack

    /// The pull requests to merge to land this one: from the bottom of the stack up to here.
    var stackToMerge: [PullRequestItem] {
        let open = nativeStack == nil ? stack : shownStack.filter { $0.state == .open }
        guard let index = open.firstIndex(where: { $0.id == item.id }) else { return [] }
        return Array(open[...index])
    }

    /// The stack the menu lists: GitHub's own when it keeps one, else the one the branches make.
    var shownStack: [PullRequestItem] { nativeStack?.items(repo: item.repo, like: item) ?? stackHistory }

    /// The stack this pull request stands in, bottom first, with the ones that merged: a click opens another one of it,
    /// and the last line merges the stack up to here.
    var stackMenu: some View {
        let index = (shownStack.firstIndex { $0.id == item.id } ?? 0) + 1
        return Menu {
            Section(tr("agents.pulls.stack.title", shownStack.count)) {
                ForEach(Array(shownStack.enumerated()), id: \.element.id) { position, member in
                    Button {
                        if member.id != item.id { onOpenPullRequest?(member) }
                    } label: {
                        let mark = member.id == item.id ? "✓ " : ""
                        let state = member.state == .merged ? " · " + tr("agents.pr.state.merged") : ""
                        Text(mark + "\(position + 1). #\(member.number) \(member.title)" + state)
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
                Text("\(index)/\(shownStack.count)").font(NookTheme.TextStyle.caption).monospacedDigit()
            }
            .foregroundStyle(NookTheme.textSecondary)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(tr("agents.pulls.stack.position", index, shownStack.count))
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
                let merged: Int
                if let layer = nativeStack?.layers.first(where: { $0.number == item.number }), let token = GitHubPullRequestDetail.token(accountID: accountID) {
                    // GitHub lands the layers below this one by itself.
                    try await GitHubPullRequestDetail.mergeNativeStack(repo: item.repo, number: item.number, sha: layer.headSHA, method: method, token: token)
                    app.store.audit(tool: "github_merge_pr", args: "\(item.id) stack · \(method.rawValue)", result: "merged")
                    merged = targets.count
                } else {
                    merged = try await PullRequestQuickRunner.mergeStack(targets, accountID: accountID, app: app)
                }
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

    /// The merge bar at the top right: whether it can be merged, and beside it what there is to do about that (merge,
    /// let GitHub merge when the checks are done, mark a draft ready, hand a conflict to the session beside it).
    func primaryAction(_ detail: PullRequestDetail) -> some View {
        let acts = hasMergeAction(detail)
        return HStack(spacing: NookTheme.Spacing.sm) {
            mergeStatus(detail)
            if acts { mergeAction(detail) }
        }
        .padding(.leading, NookTheme.Spacing.md)
        .padding(.trailing, acts ? NookTheme.Spacing.xxs : NookTheme.Spacing.md)
        .frame(height: 28)
        .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.graphite))
        .layoutPriority(1)
    }

    private func hasMergeAction(_ detail: PullRequestDetail) -> Bool {
        switch detail.state {
        case .merged, .closed: return false
        case .draft: return !detail.nodeID.isEmpty && detail.canPush != false
        case .open:
            if detail.conflicted { return sessionContext != nil }
            // An admin keeps Merge beside a waiting auto-merge, to merge now instead of waiting for it.
            return (detail.autoMerge == nil || detail.canBypass) && detail.canPush != false && !detail.methods.isEmpty
        }
    }

    @ViewBuilder
    private func mergeAction(_ detail: PullRequestDetail) -> some View {
        if detail.state == .draft {
            SmallPrimaryButton(title: tr("agents.pr.action.ready"), systemName: PullRequestIcon.symbol(.open), compact: true) {
                actions.close()
                actions.pending = .markReady(nodeID: detail.nodeID)
            }
            .disabled(actions.sending)
        } else if detail.conflicted, let sessionContext {
            SmallPrimaryButton(title: tr("session.context.resolve"), systemName: PullRequestIcon.symbol(.conflict), compact: true) {
                ComposerInbox.shared.add(SessionPrompts.resolveConflicts(detail.sessionRef), to: sessionContext)
            }
            .help(tr("agents.pr.note.conflict"))
        } else if !detail.canBypass, detail.features.autoMerge, detail.autoMergeAllowed, detail.mergeable != nil, detail.checkSummary == .pending || detail.mergeState == "blocked", !detail.nodeID.isEmpty {
            // While the checks or reviews still hold it back, the main action is to let GitHub merge when they are done. An
            // admin gets Merge instead, which goes past them; auto-merge stays in the ⋯ menu.
            SmallPrimaryButton(title: tr("agents.pr.action.enableAutoMerge"), systemName: "bolt", compact: true) {
                actions.close()
                actions.pending = .enableAutoMerge(nodeID: detail.nodeID, method: method)
            }
            .disabled(actions.sending)
        } else {
            mergeButton(detail)
        }
    }

    /// Merge with its method beside it. The first click arms it, the second merges.
    func mergeButton(_ detail: PullRequestDetail) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            if merging { ProgressView().controlSize(.small) }
            SmallPrimaryButton(title: merging ? tr("agents.pr.merging") : armedMerge ? tr("agents.pr.confirmMerge")
                                   : detail.bypassesRules ? tr("agents.pr.mergeAdmin") : tr("agents.pr.merge"),
                               systemName: armedMerge ? "checkmark" : PullRequestIcon.symbol(.merged), compact: true) {
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
                Image(icon: "chevron.down")
                    .font(NookTheme.font(9, .bold))
                    .foregroundStyle(NookTheme.onPrimary)
                    .frame(width: 24, height: 24)
                    // The same fill as Merge beside it, so the pair reads as one split button.
                    .roundedBackground(NookTheme.primary, radius: NookTheme.Radius.control)
                    .opacity(merging ? 0.45 : 1)
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

    /// The merge status in its mark and a few words; a word that has a longer reason shows it on a click. In a bar too
    /// narrow for the word, the mark stays.
    func mergeStatus(_ detail: PullRequestDetail) -> some View {
        let status = detail.mergeStatus
        let note = detail.canPush == false && detail.isOpen ? "agents.pr.note.noAccess" : status.noteKey
        let method = detail.autoMerge?.method.map { tr($0.titleKey) }
        return Button {
            showBlocker.toggle()
        } label: {
            ViewThatFits(in: .horizontal) {
                PullRequestMergeStatusLabel(status: status)
                PullRequestMergeStatusLabel(status: status, markOnly: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(note != nil)
        .help(note.map { status.word + " · " + tr($0) } ?? method ?? "")
        .popover(isPresented: $showBlocker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                Text(status.word).font(NookTheme.TextStyle.strong).foregroundStyle(PullRequestIcon.tint(status: status))
                Text(tr(note ?? ""))
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
        if let detail, detail.bypassesRules { text += "\n" + tr("agents.pr.confirmBypass") }
        return text
    }

    /// Only after the confirmation: merges the head that is shown, and writes the outcome to the action log.
    func merge() {
        guard let detail, detail.canMerge, !merging else { return }
        let forge = forge
        guard let token = forge != nil ? "" : GitHubPullRequestDetail.token(accountID: accountID) else {
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
                let sha: String
                if let forge {
                    sha = try await forge.merge(number: detail.number, method: method, sha: detail.headSHA)
                } else {
                    sha = try await GitHubPullRequestDetail.merge(repo: detail.repo, number: detail.number, method: method,
                                                                  sha: detail.headSHA, token: token)
                }
                app.store.audit(tool: "github_merge_pr", args: args, result: "merged" + (sha.isEmpty ? "" : " " + String(sha.prefix(7))))
                settle()
                await model.refresh(activity: true)
                await PullRequestStore.shared.refresh(force: true)
            } catch {
                app.store.audit(tool: "github_merge_pr", args: args, result: "error: " + error.localizedDescription)
                merging = false
                // The answer can get lost (a timeout) after GitHub merged after all: look before calling it failed. Also
                // waits out a poll that runs, so new commits show and the next Merge sends the new head.
                await model.reload()
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
