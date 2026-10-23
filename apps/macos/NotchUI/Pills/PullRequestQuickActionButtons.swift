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
            Task { @MainActor in self?.held = held }
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
            .task(id: armed) {
                // An armed action waits a few seconds for its second click, then lets go.
                guard armed != nil else { return }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if !Task.isCancelled { armed = nil }
            }
        }
    }

    private func button(_ action: PullRequestQuickAction) -> some View {
        let confirming = armed == action
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
        .help(tr("agents.pulls.quick.help"))
    }

    private func run(_ action: PullRequestQuickAction) {
        running = action
        Task {
            do {
                try await PullRequestQuickRunner.run(action, item: item, accountID: accountID, app: app)
                ToastCenter.shared.success(tr("agents.pulls.quick.done." + action.rawValue, "#\(item.number)"))
                await PullRequestStore.shared.refresh(force: true)
            } catch {
                ToastCenter.shared.error(error, title: tr("agents.pulls.quick.failed", "#\(item.number)"))
            }
            running = nil
        }
    }

    static func symbol(_ action: PullRequestQuickAction) -> String {
        switch action {
        case .close: return "xmark.circle"
        case .merge: return NookSymbol.merge
        case .ready: return "eye"
        case .reopen: return "arrow.uturn.backward.circle"
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
            try await GitHubPullRequestDetail.perform(request, repo: item.repo, number: item.number, token: token)
            app.store.audit(tool: request.auditTool, args: args, result: "ok")
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
