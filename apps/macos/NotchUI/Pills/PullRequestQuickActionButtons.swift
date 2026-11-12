import AppKit
import SwiftUI

/// Whether Shift is held, for the quick actions on pull request rows. One local monitor for the app, started on first use.
@MainActor
final class ShiftKeyMonitor: ObservableObject {
    static let shared = ShiftKeyMonitor()
    @Published private(set) var held = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let held = flags.contains(.shift) && !flags.contains(.command) && !flags.contains(.option) && !flags.contains(.control)
            // Only a change: every ⌘ or ⌥ press drew every pull request row again.
            Task { @MainActor in if self?.held != held { self?.held = held } }
            return event
        }
    }
}

/// The quick actions at the end of a pull request's row, shown while you hold Shift: close, merge, ready for review or
/// reopen. The first click arms one (its button asks "Confirm …?"), the second sends it; an armed button disarms itself
/// after a few seconds. Merges go through `PullRequestQuickMerges`, one at a time, together with the ones the selection
/// bar sends. Every action goes to GitHub with the account the row is listed under and into the action log.
struct PullRequestQuickActionButtons: View {
    @EnvironmentObject private var app: AppModel
    let item: PullRequestItem
    let accountID: String
    @ObservedObject private var shift = ShiftKeyMonitor.shared
    @ObservedObject private var sweep = PullRequestCloseSweep.shared
    @ObservedObject private var tracker = PullRequestCloseSweep.shared.tracker
    @ObservedObject private var merges = PullRequestQuickMerges.shared
    @State private var armed: PullRequestQuickAction?
    @State private var running: PullRequestQuickAction?
    @State private var hovered: PullRequestQuickAction?

    var body: some View {
        let actions = PullRequestQuickAction.actions(for: item)
        let merging = merges.queue.phase(item.id)
        if !actions.isEmpty && (shift.held || armed != nil || running != nil || merging != nil) {
            HStack(spacing: NookTheme.Spacing.xs) {
                // A row in the merge queue shows only how its merge goes.
                ForEach(merging == nil ? actions : [.merge]) { action in
                    button(action)
                }
            }
            .padding(.trailing, NookTheme.Spacing.sm)
            .transition(.opacity)
            .sweepRow(tracker, id: item.id)
            .onAppear { sweep.rows[item.id] = PullRequestCloseSweep.Row(item: item, account: accountID) }
            .onDisappear { sweep.rows[item.id] = nil }
            .task(id: armed) {
                // An armed action waits a few seconds for its second click, then lets go.
                guard armed != nil else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { armed = nil }
            }
        }
    }

    private func button(_ action: PullRequestQuickAction) -> some View {
        let confirming = armed == action || (action == .close && sweep.isSwept(item.id))
        let phase = action == .merge ? merges.queue.phase(item.id) : nil
        let look = Self.look(action, confirming: confirming, phase: phase, hovering: hovered == action)
        return Button {
            if confirming {
                armed = nil
                if action == .merge {
                    merges.add(item, accountID: accountID, app: app)
                } else {
                    run(action)
                }
            } else {
                armed = action
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                if running == action || phase == .merging {
                    ProgressView().controlSize(.mini)
                } else if phase == .waiting {
                    NookSymbol("clock", size: 11)
                } else if phase == .autoMerge {
                    NookSymbol("bolt", size: 11)
                } else {
                    NookSymbol(Self.symbol(action), size: 11)
                }
                Text(Self.title(action, confirming: confirming, phase: phase)).lineLimit(1).fixedSize()
            }
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(look.text)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 22)
            .roundedBackground(look.fill, radius: NookTheme.Radius.control)
            .overlay(NookTheme.shape(NookTheme.Radius.control).strokeBorder(look.stroke))
            .contentShape(NookTheme.shape(NookTheme.Radius.control))
            .animation(NookTheme.hover, value: hovered == action)
        }
        .buttonStyle(.nookPlain)
        .disabled(running != nil || merges.queue.phase(item.id) != nil)
        .onHover { inside in
            if inside { hovered = action } else if hovered == action { hovered = nil }
        }
        .help(tr(action == .close ? "agents.pulls.quick.sweepHelp" : "agents.pulls.quick.help"))
        // Close, dragged up or down over other rows, takes those along.
        .sweeps(tracker, from: item.id, enabled: action == .close) { ids in sweep.finish(ids) }
    }

    /// How a quick action is drawn, in Nook's own buttons: Merge is the main action (filled with the accent, soft white
    /// by default), Close is red (a soft red, filled once it asks to confirm), Ready and Reopen are outline buttons that
    /// fill with the accent when armed. A merge in the queue reads as its state: waiting quietly in outline, busy at
    /// GitHub as a dimmed main button, merged in the merged violet, handed to auto-merge in amber.
    struct Look {
        let text: Color
        let fill: Color
        let stroke: Color
    }

    static func look(_ action: PullRequestQuickAction, confirming: Bool,
                     phase: PullRequestQuickMergeQueue.Phase?, hovering: Bool) -> Look {
        switch phase {
        case .waiting:
            return Look(text: NookTheme.textSecondary, fill: NookTheme.outlineFill, stroke: NookTheme.outlineStroke)
        case .merging:
            return Look(text: NookTheme.onPrimary, fill: NookTheme.primary.opacity(0.7), stroke: .clear)
        case .merged:
            return Look(text: NookTheme.violet, fill: NookTheme.violet.opacity(0.14), stroke: NookTheme.violet.opacity(0.35))
        case .autoMerge:
            return Look(text: NookTheme.amber, fill: NookTheme.amber.opacity(0.12), stroke: NookTheme.amber.opacity(0.35))
        case nil:
            break
        }
        switch action {
        case .close:
            if confirming { return Look(text: .white, fill: NookTheme.coral.opacity(hovering ? 1 : 0.9), stroke: .clear) }
            return Look(text: NookTheme.coral, fill: NookTheme.coral.opacity(hovering ? 0.2 : 0.12),
                        stroke: NookTheme.coral.opacity(0.35))
        case .merge:
            return Look(text: NookTheme.onPrimary, fill: hovering ? NookTheme.primaryHover : NookTheme.primary, stroke: .clear)
        case .ready, .reopen:
            if confirming {
                return Look(text: NookTheme.onPrimary, fill: hovering ? NookTheme.primaryHover : NookTheme.primary, stroke: .clear)
            }
            return Look(text: hovering ? NookTheme.paper : NookTheme.textSecondary, fill: NookTheme.outlineFill,
                        stroke: NookTheme.outlineStroke)
        }
    }

    private func run(_ action: PullRequestQuickAction) {
        running = action
        Task {
            do {
                try await PullRequestQuickRunner.run(action, item: item, accountID: accountID, app: app)
                ToastCenter.shared.success(tr("agents.pulls.quick.done." + action.rawValue, "#\(item.number)"))
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pulls.quick.failed", "#\(item.number)"))
            }
            running = nil
        }
    }

    private static func title(_ action: PullRequestQuickAction, confirming: Bool, phase: PullRequestQuickMergeQueue.Phase?) -> String {
        switch phase {
        case .waiting: return tr("agents.pulls.quick.queued")
        case .merging: return tr("agents.pulls.quick.merging")
        case .merged: return tr("agents.pulls.quick.merged")
        case .autoMerge: return tr("agents.pulls.quick.autoMergeOn")
        case nil: break
        }
        if confirming { return tr("agents.pulls.quick.confirm." + action.rawValue) }
        return tr("agents.pulls.quick." + action.rawValue)
    }

    static func symbol(_ action: PullRequestQuickAction) -> String {
        switch action {
        // Each shows the mark of the state it leads to.
        case .close: return PullRequestIcon.symbol(.closed)
        case .merge: return PullRequestIcon.symbol(.merged)
        case .ready: return PullRequestIcon.symbol(.open)
        case .reopen: return PullRequestIcon.symbol(.open)
        }
    }
}

/// The merges of the Pull request rows and of the selection bar: the queue's rules are in `PullRequestQuickMergeQueue`;
/// this sends them to GitHub one at a time, says how it went once the queue is empty, and reads the list again then.
@MainActor
final class PullRequestQuickMerges: ObservableObject {
    static let shared = PullRequestQuickMerges()

    @Published private(set) var queue = PullRequestQuickMergeQueue()
    private var requests: [String: (item: PullRequestItem, account: String)] = [:]
    private var working = false

    private init() {}

    /// Queues a merge, already confirmed, and starts sending when nothing is.
    func add(_ item: PullRequestItem, accountID: String, app: AppModel) {
        guard queue.add(item.id) else { return }
        requests[item.id] = (item, accountID)
        work(app: app)
    }

    private func work(app: AppModel) {
        guard !working else { return }
        working = true
        Task {
            while true {
                while let id = queue.next() {
                    guard let request = requests[id] else {
                        queue.finish(success: false)
                        continue
                    }
                    do {
                        switch try await PullRequestQuickRunner.quickMerge(request.item, accountID: request.account, app: app) {
                        case .merged: queue.finish(success: true)
                        case .autoMerge: queue.finishAutoMerge()
                        }
                    } catch {
                        queue.finish(success: false)
                        ToastCenter.shared.error(error, title: tr("agents.pulls.quick.failed", "#\(request.item.number)"))
                    }
                }
                // Read the list again before the rows let go of "Merged", so they do not flash Merge for a moment.
                if queue.changed { await PullRequestStore.shared.refresh(force: true) }
                // A merge clicked while the list was read goes in this same run.
                if queue.isIdle { break }
            }
            working = false
            if let result = queue.drain() {
                let merged = result.merged.compactMap { requests[$0].map { "#\($0.item.number)" } }
                if !merged.isEmpty {
                    ToastCenter.shared.success(merged.count == 1 ? tr("agents.pulls.quick.done.merge", merged[0])
                                                                 : tr("agents.pulls.stack.merged", merged.count))
                }
                let waiting = result.autoMerged.compactMap { requests[$0].map { "#\($0.item.number)" } }
                if !waiting.isEmpty {
                    ToastCenter.shared.success(waiting.count == 1 ? tr("agents.pulls.quick.done.autoMerge", waiting[0])
                                                                  : tr("agents.pulls.quick.done.autoMergeMany", waiting.count))
                }
            }
            requests = [:]
        }
    }
}

/// Sends a quick action, or a stack merge, and writes it to the action log.
@MainActor
enum PullRequestQuickRunner {
    static func run(_ action: PullRequestQuickAction, item: PullRequestItem, accountID: String, app: AppModel) async throws {
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else { throw NookError(tr("agents.pr.noToken")) }
        if action == .merge {
            _ = try await quickMerge(item, accountID: accountID, app: app)
            return
        }
        guard let request = action.action(for: item) else { return }
        let args = request.auditArgs(repo: item.repo, number: item.number)
        do {
            let reply = try await GitHubPullRequestDetail.perform(request, repo: item.repo, number: item.number, token: token)
            app.store.audit(tool: request.auditTool, args: args, result: "ok")
            if let reply {
                PullRequestStore.shared.apply(reply, to: item.id)
                if let state = reply.linkState { PullRequestSync.shared.mark(repository: item.repo, number: item.number, state: state) }
            } else {
                await PullRequestStore.shared.refresh(force: true)
            }
        } catch {
            app.store.audit(tool: request.auditTool, args: args, result: "error: " + error.localizedDescription)
            throw error
        }
    }

    enum MergeOutcome: Equatable {
        /// Merged into this base branch.
        case merged(base: String)
        /// Checks or reviews still hold it back and this account may not go past them: GitHub merges it once they are done.
        case autoMerge
    }

    /// A merge from a row or the selection bar: an admin who may bypass the rules merges at once, as on the pull
    /// request's page; anyone else gets auto-merge while checks run or a review is missing, instead of an error.
    static func quickMerge(_ item: PullRequestItem, accountID: String, app: AppModel) async throws -> MergeOutcome {
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else { throw NookError(tr("agents.pr.noToken")) }
        return try await merge(repo: item.repo, number: item.number, token: token, app: app, autoMerge: true)
    }

    /// Merges one pull request at the head GitHub reports right now, after checking it can go: open, not a draft, no
    /// conflict, write access and no failing checks. With `autoMerge`, one that must wait (`waitsForAutoMerge`) gets
    /// auto-merge instead; a stack passes false, since the next one needs this one merged before it can be retargeted.
    static func merge(repo: String, number: Int, token: String, app: AppModel, autoMerge: Bool) async throws -> MergeOutcome {
        let detail = try await GitHubPullRequestDetail.loadForMerge(repo: repo, number: number, token: token)
        if let reason = blocker(detail) { throw NookError(tr(reason, "#\(number)")) }
        let preferred = PullRequestMergeMethod(rawValue: UserDefaults.standard.string(forKey: "agents.pr.mergeMethod") ?? "") ?? .merge
        guard let method = PullRequestQuickAction.mergeMethod(preferred: preferred, allowed: detail.methods) else {
            throw NookError(tr("agents.pulls.quick.noMethod", "#\(number)"))
        }
        if autoMerge, detail.waitsForAutoMerge {
            // Already on: nothing to send, it merges by itself.
            if detail.autoMerge != nil { return .autoMerge }
            let request = PullRequestAction.enableAutoMerge(nodeID: detail.nodeID, method: method)
            let args = request.auditArgs(repo: repo, number: number)
            do {
                try await GitHubPullRequestDetail.perform(request, repo: repo, number: number, token: token)
                app.store.audit(tool: request.auditTool, args: args, result: "ok")
                return .autoMerge
            } catch {
                app.store.audit(tool: request.auditTool, args: args, result: "error: " + error.localizedDescription)
                throw error
            }
        }
        let args = "\(detail.id) · \(method.rawValue) · \(detail.headBranch) → \(detail.baseBranch)"
        do {
            let sha = try await GitHubPullRequestDetail.merge(repo: repo, number: number, method: method, sha: detail.headSHA, token: token)
            app.store.audit(tool: "github_merge_pr", args: args, result: "merged" + (sha.isEmpty ? "" : " " + String(sha.prefix(7))))
            return .merged(base: detail.baseBranch)
        } catch {
            app.store.audit(tool: "github_merge_pr", args: args, result: "error: " + error.localizedDescription)
            throw error
        }
    }

    /// Why a pull request cannot be merged now, as a `tr` key that takes its number; nil when it can.
    static func blocker(_ detail: PullRequestDetail) -> String? {
        switch detail.state {
        case .merged: return "agents.pulls.quick.blocked.merged"
        case .closed: return "agents.pulls.quick.blocked.closed"
        case .draft: return "agents.pulls.quick.blocked.draft"
        case .open: break
        }
        if detail.canPush == false { return "agents.pulls.quick.blocked.access" }
        if detail.conflicted { return "agents.pulls.quick.blocked.conflict" }
        if detail.checkSummary == .failing { return "agents.pulls.quick.blocked.checks" }
        return nil
    }

    /// Merges a stack from the bottom up to and including the last of `stack`. After each merge the next pull request is
    /// pointed at the branch the merged one went into, so it lands on the trunk and not on a branch that is done. Stops
    /// at the first one that cannot go, and says how far it got.
    static func mergeStack(_ stack: [PullRequestItem], accountID: String, app: AppModel) async throws -> Int {
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else { throw NookError(tr("agents.pr.noToken")) }
        var merged = 0
        var target: String?
        for item in stack {
            do {
                if let target {
                    let retarget = PullRequestAction.changeBase(target)
                    let args = retarget.auditArgs(repo: item.repo, number: item.number)
                    do {
                        try await GitHubPullRequestDetail.perform(retarget, repo: item.repo, number: item.number, token: token)
                        app.store.audit(tool: retarget.auditTool, args: args, result: "ok")
                    } catch {
                        app.store.audit(tool: retarget.auditTool, args: args, result: "error: " + error.localizedDescription)
                        throw error
                    }
                    // GitHub works out whether it can merge again after a new base; give it a moment.
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                if case .merged(let base) = try await merge(repo: item.repo, number: item.number, token: token, app: app, autoMerge: false) {
                    target = base
                }
                merged += 1
            } catch {
                throw NookError(tr("agents.pulls.stack.stopped", merged, stack.count, error.localizedDescription))
            }
        }
        return merged
    }
}

/// Closing several pull requests in one drag: Close on one row, dragged up or down over the others (`RowSweep`, the same
/// sweep as Settle in the Agents list). The rows swept over light up, and a bar over the list asks before anything goes
/// to GitHub.
@MainActor
final class PullRequestCloseSweep: ObservableObject {
    static let shared = PullRequestCloseSweep()

    struct Row {
        let item: PullRequestItem
        let account: String
    }

    /// The drag itself; the rows showing their quick actions now are the ones it can take.
    let tracker = RowSweep<String>()
    /// Those rows' requests, by id. Not published: every scroll sets it.
    var rows: [String: Row] = [:]
    @Published private(set) var confirming: [Row] = []
    @Published private(set) var closing = false

    /// Whether a request is swept now or waits in the bar.
    func isSwept(_ id: String) -> Bool {
        tracker.swept.contains(id) || confirming.contains { $0.item.id == id }
    }

    /// The drag ended over these rows: the bar asks to close them.
    func finish(_ ids: [String]) {
        confirming = ids.compactMap { rows[$0] }
    }

    func cancel() {
        confirming = []
    }

    func close(app: AppModel) {
        let rows = confirming
        closing = true
        Task {
            await Self.close(rows.map { PullRequestOpenRequest(account: $0.account, item: $0.item) }, app: app)
            closing = false
            cancel()
        }
    }

    /// Closes pull requests one after the other, says how it went, and reads the list again.
    static func close(_ requests: [PullRequestOpenRequest], app: AppModel) async {
        var failed = 0
        for request in requests {
            do {
                try await PullRequestQuickRunner.run(.close, item: request.item, accountID: request.account, app: app)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            ToastCenter.shared.error(NookError(tr("agents.pulls.sweep.failed", failed)))
        } else {
            ToastCenter.shared.success(tr("agents.pulls.sweep.done", requests.count))
        }
        await PullRequestStore.shared.refresh(force: true)
    }
}

/// "Close 4 pull requests?" over a list, after a sweep.
struct PullRequestCloseSweepBar: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var sweep = PullRequestCloseSweep.shared

    var body: some View {
        if !sweep.confirming.isEmpty {
            AdaptiveActionRow {
                Text(tr("agents.pulls.sweep.confirm", sweep.confirming.count))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
            } actions: {
                if sweep.closing { ProgressView().controlSize(.small) }
                SmallGhostButton(title: tr("button.cancel")) { sweep.cancel() }
                SmallPrimaryButton(title: tr("agents.pr.action.confirm")) { sweep.close(app: app) }
            }
            .padding(NookTheme.Spacing.md)
            .panelCard()
        }
    }
}
