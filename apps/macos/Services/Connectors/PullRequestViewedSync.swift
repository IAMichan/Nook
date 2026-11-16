import Foundation

/// Keeps the "Viewed" marks of a pull request's files (`PullRequestViewedFiles`) and the forge's own checkbox in step,
/// for the Code tab and the phone alike. A read takes the forge's state (it wins, `reconcile`); a toggle shows at once,
/// is written through after your click and logged; a toggle the forge does not take (offline, no access) stays on this
/// Mac and is sent again after the next read. A forge without a viewed state of its own (`features.viewedFiles` off:
/// GitLab, Gitea, Forgejo, Bitbucket, Azure DevOps, GitCafe; see docs/INTEGRATIONS.md) keeps the marks here only.
@MainActor
enum PullRequestViewedSync {
    /// The forge's state after a read, into `marks` (saved when it changed). Toggles that wait are written again.
    static func adopt(_ detail: PullRequestDetail, accountID: String, marks: inout PullRequestViewedFiles,
                      onSynced: @escaping (PullRequestViewedFiles) -> Void = { _ in }) {
        guard detail.activityLoaded, detail.features.viewedFiles, let remote = detail.viewedOnForge else { return }
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        let before = marks
        let retry = marks.reconcile(remote, files: detail.files, in: key)
        if marks != before { marks.save() }
        for (path, viewed) in retry {
            Task { await write(viewed, path: path, detail: detail, accountID: accountID, onSynced: onSynced) }
        }
    }

    /// Your click on a file's mark: shown and saved at once, then sent to the forge where it keeps one.
    static func toggle(_ viewed: Bool, file: PullRequestFile, detail: PullRequestDetail, accountID: String,
                       marks: inout PullRequestViewedFiles, onSynced: @escaping (PullRequestViewedFiles) -> Void = { _ in }) {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        marks.setViewed(viewed, file: file, in: key)
        guard detail.features.viewedFiles else {
            marks.save()
            return
        }
        marks.setUnsynced(viewed, path: file.path, in: key)
        marks.save()
        Task { await write(viewed, path: file.path, detail: detail, accountID: accountID, onSynced: onSynced) }
    }

    /// Sends one mark; once the forge took it, it no longer waits. A failure leaves it waiting, quietly: the mark is
    /// still yours on this Mac, and the next read tries again.
    @discardableResult
    static func write(_ viewed: Bool, path: String, detail: PullRequestDetail, accountID: String,
                      onSynced: @escaping (PullRequestViewedFiles) -> Void = { _ in }) async -> Bool {
        let key = PullRequestViewedFiles.key(repo: detail.repo, number: detail.number)
        let args = "\(detail.repo)#\(detail.number) \(path) \(viewed ? "viewed" : "not viewed")"
        do {
            if let forge = PullRequestForges.client(account: accountID, path: detail.repo) {
                guard forge.features.viewedFiles else { return false }
                try await forge.setViewed(viewed, path: path, number: detail.number, detail: detail)
            } else {
                guard let token = GitHubPullRequestDetail.token(accountID: accountID) else { return false }
                try await GitHubPullRequestDetail.setFileViewed(viewed, path: path, nodeID: detail.nodeID, token: token)
            }
        } catch {
            AppModel.shared.store.audit(tool: "pr_file_viewed", args: args, result: "error: " + error.localizedDescription)
            return false
        }
        AppModel.shared.store.audit(tool: "pr_file_viewed", args: args, result: "ok")
        var marks = PullRequestViewedFiles.load()
        marks.markSynced(viewed, path: path, in: key)
        marks.save()
        onSynced(marks)
        return true
    }
}
