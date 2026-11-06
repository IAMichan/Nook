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
/// after a few seconds. Every action goes to GitHub with the account the row is listed under and into the action log.
struct PullRequestQuickActionButtons: View {
    @EnvironmentObject private var app: AppModel
    let item: PullRequestItem
    let accountID: String
    @ObservedObject private var shift = ShiftKeyMonitor.shared
    @ObservedObject private var sweep = PullRequestCloseSweep.shared
    @State private var armed: PullRequestQuickAction?
    @State private var running: PullRequestQuickAction?

    var body: some View {
        let actions = PullRequestQuickAction.actions(for: item)
        if !actions.isEmpty && (shift.held || armed != nil || running != nil) {
            HStack(spacing: NookTheme.Spacing.xs) {
                ForEach(actions) { action in
                    button(action)
                }
            }
            .padding(.trailing, NookTheme.Spacing.sm)
            .transition(.opacity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                sweep.rows[item.id] = PullRequestCloseSweep.Row(frame: frame, item: item, account: accountID)
            }
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
        let confirming = armed == action || (action == .close && sweep.swept.contains(item.id))
        let tint = confirming ? (action == .close ? NookTheme.coral : NookTheme.amber) : NookTheme.textSecondary
        return Button {
            if confirming {
                armed = nil
                run(action)
            } else {
                armed = action
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xxs) {
                if running == action {
                    ProgressView().controlSize(.mini)
                } else {
                    NookSymbol(Self.symbol(action), size: 11)
                }
                Text(confirming ? tr("agents.pulls.quick.confirm." + action.rawValue) : tr("agents.pulls.quick." + action.rawValue))
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: 22)
            .background(Capsule().strokeBorder(confirming ? tint : NookTheme.line2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(running != nil)
        .help(tr(action == .close ? "agents.pulls.quick.sweepHelp" : "agents.pulls.quick.help"))
        // Close, dragged over other rows, takes those along.
        .simultaneousGesture(action == .close ? DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in sweep.drag(from: item.id, at: value.location) }
            .onEnded { _ in sweep.finish() } : nil)
    }

    private func run(_ action: PullRequestQuickAction) {
        running = action
        Task {
            do {
                try await PullRequestQuickRunner.run(action, item: item, accountID: accountID, app: app)
                ToastCenter.shared.success(tr("agents.pulls.quick.done." + action.rawValue, "#\(item.number)"))
                // A merge changes other rows too (a stack, what conflicts): the rest was in GitHub's answer.
                if action == .merge { await PullRequestStore.shared.refresh(force: true) }
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pulls.quick.failed", "#\(item.number)"))
            }
            running = nil
        }
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

/// Sends a quick action, or a stack merge, and writes it to the action log.
@MainActor
enum PullRequestQuickRunner {
    static func run(_ action: PullRequestQuickAction, item: PullRequestItem, accountID: String, app: AppModel) async throws {
        guard let token = GitHubPullRequestDetail.token(accountID: accountID) else { throw NookError(tr("agents.pr.noToken")) }
        if action == .merge {
            try await merge(repo: item.repo, number: item.number, token: token, app: app)
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

    /// Merges one pull request at the head GitHub reports right now, after checking it can go: open, not a draft, no
    /// conflict, write access and no failing checks. Returns the base branch it went into.
    @discardableResult
    static func merge(repo: String, number: Int, token: String, app: AppModel) async throws -> String {
        let detail = try await GitHubPullRequestDetail.loadForMerge(repo: repo, number: number, token: token)
        if let reason = blocker(detail) { throw NookError(tr(reason, "#\(number)")) }
        let preferred = PullRequestMergeMethod(rawValue: UserDefaults.standard.string(forKey: "agents.pr.mergeMethod") ?? "") ?? .merge
        guard let method = PullRequestQuickAction.mergeMethod(preferred: preferred, allowed: detail.methods) else {
            throw NookError(tr("agents.pulls.quick.noMethod", "#\(number)"))
        }
        let args = "\(detail.id) · \(method.rawValue) · \(detail.headBranch) → \(detail.baseBranch)"
        do {
            let sha = try await GitHubPullRequestDetail.merge(repo: repo, number: number, method: method, sha: detail.headSHA, token: token)
            app.store.audit(tool: "github_merge_pr", args: args, result: "merged" + (sha.isEmpty ? "" : " " + String(sha.prefix(7))))
            return detail.baseBranch
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
                target = try await merge(repo: item.repo, number: item.number, token: token, app: app)
                merged += 1
            } catch {
                throw NookError(tr("agents.pulls.stack.stopped", merged, stack.count, error.localizedDescription))
            }
        }
        return merged
    }
}

/// Closing several pull requests in one drag: Close on one row, dragged over the others. The rows swept over light up,
/// and a bar over the list asks before anything goes to GitHub.
@MainActor
final class PullRequestCloseSweep: ObservableObject {
    static let shared = PullRequestCloseSweep()

    struct Row {
        let frame: CGRect
        let item: PullRequestItem
        let account: String
    }

    /// The rows showing their quick actions now, by id: only those can be swept over. Not published: every scroll sets it.
    var rows: [String: Row] = [:]
    @Published private(set) var swept: [String] = []
    @Published private(set) var confirming: [Row] = []
    @Published private(set) var closing = false

    func drag(from origin: String, at point: CGPoint) {
        var next = swept
        if next.isEmpty { next = [origin] }
        if let row = rows.first(where: { point.y >= $0.value.frame.minY - 12 && point.y <= $0.value.frame.maxY + 12 })?.key,
           !next.contains(row) {
            next.append(row)
        }
        if next != swept { swept = next }
    }

    func finish() {
        // One row is the button's own click.
        confirming = swept.count > 1 ? swept.compactMap { rows[$0] } : []
        if confirming.isEmpty { swept = [] }
    }

    func cancel() {
        confirming = []
        swept = []
    }

    func close(app: AppModel) {
        let rows = confirming
        closing = true
        Task {
            var failed = 0
            for row in rows {
                do {
                    try await PullRequestQuickRunner.run(.close, item: row.item, accountID: row.account, app: app)
                } catch {
                    failed += 1
                }
            }
            closing = false
            cancel()
            if failed > 0 {
                ToastCenter.shared.error(NookError(tr("agents.pulls.sweep.failed", failed)))
            } else {
                ToastCenter.shared.success(tr("agents.pulls.sweep.done", rows.count))
            }
            await PullRequestStore.shared.refresh(force: true)
        }
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
