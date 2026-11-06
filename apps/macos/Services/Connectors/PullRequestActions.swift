import Foundation

/// What you can do to a pull request from its page, besides merging it: review
/// it (approve, request changes, comment), write in its conversation, close or reopen it, edit its title and
/// description, ask people for a review, bring its branch up to date with the base, add or remove a label, mark a draft
/// ready for review or turn it back into a draft, and point it at another base branch (when the pull request under it in a
/// stack was merged), answer on a thread, resolve it, edit a comment, delete the head branch, open a revert, allow
/// maintainers' edits, and turn auto-merge on or off. Each is one GitHub call (REST, or GraphQL for what only it offers),
/// asked after your own click, and written to the action log. Foundation only, so
/// the requests are tested on their own.
/// What GitHub's answer to an action says the pull request is now. Applied at once, in every place that shows it, so no
/// list has to be read again to learn what the answer already said. Nil fields are what this answer does not tell.
struct PullRequestActionReply: Equatable, Sendable {
    var state: PullRequestDetail.State?
    var title: String?
    var body: String?
    var baseBranch: String?
    /// The link of what the action made: the pull request a revert opened.
    var made: String?

    func apply(to detail: inout PullRequestDetail) {
        if let state { detail.state = state }
        if let title { detail.title = title }
        if let body { detail.body = body }
        if let baseBranch { detail.baseBranch = baseBranch }
    }

    /// As a session's link knows it.
    var linkState: PullRequestState? {
        switch state {
        case .open: return .open
        case .draft: return .draft
        case .merged: return .merged
        case .closed: return .closed
        case nil: return nil
        }
    }
}

enum PullRequestAction: Equatable, Sendable {
    enum Verdict: String, CaseIterable, Sendable {
        case comment, approve, requestChanges

        /// GitHub's `event` for a review.
        var event: String {
            switch self {
            case .comment: return "COMMENT"
            case .approve: return "APPROVE"
            case .requestChanges: return "REQUEST_CHANGES"
            }
        }

        /// GitHub wants words with a comment or a request for changes; an approval may come without.
        var needsBody: Bool { self != .approve }
    }

    case review(Verdict, body: String)
    case comment(String)
    case close
    case reopen
    case edit(title: String, body: String)
    case requestReviewers([String])
    /// Merges the base into the branch, only when the branch is still at `headSHA`.
    case updateBranch(headSHA: String)
    case addLabels([String])
    case removeLabel(String)
    /// A draft becomes ready for review. Only GitHub's GraphQL API can do this, by the pull request's node id.
    case markReady(nodeID: String)
    /// An open pull request goes back to draft. GraphQL only too.
    case markDraft(nodeID: String)
    /// Merges into another branch from now on.
    case changeBase(String)
    /// Lets the workflow run of a contributor start; GitHub holds those until someone with write access approves.
    case approveWorkflow(runID: Int)
    /// A review with comments on lines, written on the Code tab and sent together.
    case reviewWithComments(Verdict, body: String, commit: String, comments: [LineComment])
    /// An answer on a thread on a line, by the id of the thread's first comment.
    case reply(to: Int, body: String)
    /// A thread on a line done with, or opened again. GraphQL only.
    case setThreadResolved(threadID: String, resolved: Bool)
    /// Your own comment rewritten; `lineComment` says which list it is in.
    case editComment(id: Int, lineComment: Bool, body: String)
    /// Rebases the branch on its base, only when it is still at `headSHA`. GraphQL only.
    case rebaseBranch(nodeID: String, headSHA: String)
    /// Deletes the merged or closed branch from the repository it lives in, which is a fork's for a fork.
    case deleteBranch(repository: String, branch: String)
    /// Opens a pull request that undoes this merged one. GraphQL only.
    case revert(nodeID: String)
    /// Whether the base repository's maintainers may push to this fork's branch.
    case setMaintainerEdits(Bool)
    /// GitHub merges by itself once the checks and reviews allow it. GraphQL only.
    case enableAutoMerge(nodeID: String, method: PullRequestMergeMethod)
    case disableAutoMerge(nodeID: String)

    /// One comment on a line of a review: `side` is GitHub's RIGHT (the new file) or LEFT (a removed line).
    struct LineComment: Equatable, Sendable {
        var path: String
        var line: Int
        var side: String
        var body: String
        /// The first line of a comment on several lines.
        var startLine: Int? = nil
        var startSide: String? = nil
    }

    static let setThreadResolvedMutation = "mutation NookThread($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }"
    static let setThreadOpenMutation = "mutation NookThread($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { isResolved } } }"
    static let rebaseBranchMutation = """
    mutation NookRebase($id: ID!, $head: GitObjectID) {
      updatePullRequestBranch(input: {pullRequestId: $id, expectedHeadOid: $head, updateMethod: REBASE}) { pullRequest { id } }
    }
    """
    static let revertMutation = """
    mutation NookRevert($id: ID!) { revertPullRequest(input: {pullRequestId: $id}) { revertPullRequest { url } } }
    """
    static let enableAutoMergeMutation = """
    mutation NookAutoMerge($id: ID!, $method: PullRequestMergeMethod!) {
      enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: $method}) { pullRequest { id } }
    }
    """
    static let disableAutoMergeMutation = "mutation NookNoAutoMerge($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { id } } }"

    static let markReadyMutation =
        "mutation NookMarkReady($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"
    static let markDraftMutation =
        "mutation NookMarkDraft($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"

    struct Request: Equatable {
        var method: String
        var path: String
        var body: [String: AnyHashable]?
    }

    /// Nil when the action cannot be sent as it is (an empty comment, a review that needs words, no reviewers).
    func request(repo: String, number: Int) -> Request? {
        let pull = "/repos/\(repo)/pulls/\(number)"
        let issue = "/repos/\(repo)/issues/\(number)"
        switch self {
        case .review(let verdict, let body):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if verdict.needsBody && text.isEmpty { return nil }
            var payload: [String: AnyHashable] = ["event": verdict.event]
            if !text.isEmpty { payload["body"] = text }
            return Request(method: "POST", path: pull + "/reviews", body: payload)
        case .comment(let body):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Request(method: "POST", path: issue + "/comments", body: ["body": text])
        case .close:
            return Request(method: "PATCH", path: pull, body: ["state": "closed"])
        case .reopen:
            return Request(method: "PATCH", path: pull, body: ["state": "open"])
        case .edit(let title, let body):
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { return nil }
            return Request(method: "PATCH", path: pull, body: ["title": cleanTitle, "body": body])
        case .requestReviewers(let people):
            let logins = Self.logins(people)
            guard !logins.isEmpty else { return nil }
            return Request(method: "POST", path: pull + "/requested_reviewers", body: ["reviewers": logins])
        case .updateBranch(let sha):
            return Request(method: "PUT", path: pull + "/update-branch", body: sha.isEmpty ? [:] : ["expected_head_sha": sha])
        case .addLabels(let labels):
            let names = labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return nil }
            return Request(method: "POST", path: issue + "/labels", body: ["labels": names])
        case .removeLabel(let label):
            let name = label.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) else { return nil }
            return Request(method: "DELETE", path: issue + "/labels/" + escaped, body: nil)
        case .markReady(let nodeID):
            guard !nodeID.isEmpty else { return nil }
            return Request(method: "POST", path: "/graphql", body: ["query": Self.markReadyMutation, "variables": ["id": nodeID] as [String: String]])
        case .markDraft(let nodeID):
            guard !nodeID.isEmpty else { return nil }
            return Request(method: "POST", path: "/graphql", body: ["query": Self.markDraftMutation, "variables": ["id": nodeID] as [String: String]])
        case .changeBase(let branch):
            let name = branch.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return Request(method: "PATCH", path: pull, body: ["base": name])
        case .approveWorkflow(let runID):
            return Request(method: "POST", path: "/repos/\(repo)/actions/runs/\(runID)/approve", body: nil)
        case .reviewWithComments(let verdict, let body, let commit, let comments):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            // The comments are the words a review needs: an approval or a remark with only those is fine.
            guard !comments.isEmpty else { return PullRequestAction.review(verdict, body: body).request(repo: repo, number: number) }
            var payload: [String: AnyHashable] = ["event": verdict.event]
            if !text.isEmpty { payload["body"] = text }
            if !commit.isEmpty { payload["commit_id"] = commit }
            let lines: [AnyHashable] = comments.map { (comment: LineComment) -> AnyHashable in
                var line: [String: AnyHashable] = ["path": comment.path, "line": comment.line, "side": comment.side, "body": comment.body]
                if let start = comment.startLine, start != comment.line {
                    line["start_line"] = start
                    line["start_side"] = comment.startSide ?? comment.side
                }
                return line
            }
            payload["comments"] = lines
            return Request(method: "POST", path: pull + "/reviews", body: payload)
        case .reply(let id, let body):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Request(method: "POST", path: pull + "/comments/\(id)/replies", body: ["body": text])
        case .setThreadResolved(let threadID, let resolved):
            guard !threadID.isEmpty else { return nil }
            return Self.graphQL(resolved ? Self.setThreadResolvedMutation : Self.setThreadOpenMutation, ["id": threadID])
        case .editComment(let id, let lineComment, let body):
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Request(method: "PATCH", path: "/repos/\(repo)/\(lineComment ? "pulls" : "issues")/comments/\(id)", body: ["body": text])
        case .rebaseBranch(let nodeID, let headSHA):
            guard !nodeID.isEmpty else { return nil }
            return Self.graphQL(Self.rebaseBranchMutation, headSHA.isEmpty ? ["id": nodeID] : ["id": nodeID, "head": headSHA])
        case .deleteBranch(let repository, let branch):
            guard !repository.isEmpty, !branch.isEmpty,
                  let escaped = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            return Request(method: "DELETE", path: "/repos/\(repository)/git/refs/heads/" + escaped, body: nil)
        case .revert(let nodeID):
            guard !nodeID.isEmpty else { return nil }
            return Self.graphQL(Self.revertMutation, ["id": nodeID])
        case .setMaintainerEdits(let allowed):
            return Request(method: "PATCH", path: pull, body: ["maintainer_can_modify": allowed])
        case .enableAutoMerge(let nodeID, let method):
            guard !nodeID.isEmpty else { return nil }
            return Self.graphQL(Self.enableAutoMergeMutation, ["id": nodeID, "method": method.rawValue.uppercased()])
        case .disableAutoMerge(let nodeID):
            guard !nodeID.isEmpty else { return nil }
            return Self.graphQL(Self.disableAutoMergeMutation, ["id": nodeID])
        }
    }

    private static func graphQL(_ query: String, _ variables: [String: String]) -> Request {
        Request(method: "POST", path: "/graphql", body: ["query": query, "variables": variables])
    }

    /// The link of the pull request a revert opened, from GitHub's answer; nil for every other answer.
    static func revertURL(_ object: [String: Any]) -> String? {
        let data = (object["data"] as? [String: Any])?["revertPullRequest"] as? [String: Any]
        return (data?["revertPullRequest"] as? [String: Any])?["url"] as? String
    }

    /// What GitHub's answer says the pull request is now. Nil for an action whose answer does not say (a comment, a review,
    /// labels): the pull request is read for those.
    func reply(_ object: [String: Any]) -> PullRequestActionReply? {
        switch self {
        case .close, .reopen, .edit, .changeBase:
            // Each of these is a PATCH of the pull request, answered with all of it.
            guard let state = object["state"] as? String else { return nil }
            let merged = (object["merged"] as? Bool) == true || (object["merged_at"] as? String) != nil
            return PullRequestActionReply(state: merged ? .merged : state != "open" ? .closed : (object["draft"] as? Bool) == true ? .draft : .open,
                                          title: object["title"] as? String,
                                          body: object["body"] as? String,
                                          baseBranch: (object["base"] as? [String: Any])?["ref"] as? String)
        case .markReady: return PullRequestActionReply(state: .open)
        case .markDraft: return PullRequestActionReply(state: .draft)
        case .review, .comment, .requestReviewers, .updateBranch, .addLabels, .removeLabel, .approveWorkflow,
             .reviewWithComments, .reply, .setThreadResolved, .editComment, .rebaseBranch, .deleteBranch, .revert,
             .setMaintainerEdits, .enableAutoMerge, .disableAutoMerge:
            return nil
        }
    }

    /// Whether the list has to be read again for this: a page shows the rest in its row (`PullRequestStore.update`), but
    /// what the reviews decided comes only with the list.
    var needsListRead: Bool {
        switch self {
        case .review, .reviewWithComments: return true
        default: return false
        }
    }

    /// The tool name in the action log, the same names as the brain's GitHub tools.
    var auditTool: String {
        switch self {
        case .review: return "github_review_pr"
        case .comment: return "github_comment_pr"
        case .close: return "github_close_pr"
        case .reopen: return "github_reopen_pr"
        case .edit: return "github_edit_pr"
        case .requestReviewers: return "github_request_reviewers"
        case .updateBranch: return "github_update_branch"
        case .addLabels, .removeLabel: return "github_labels"
        case .markReady: return "github_ready_pr"
        case .markDraft: return "github_draft_pr"
        case .changeBase: return "github_change_base"
        case .approveWorkflow: return "github_approve_workflow"
        case .reviewWithComments: return "github_review_pr"
        case .reply: return "github_comment_pr"
        case .setThreadResolved: return "github_resolve_thread"
        case .editComment: return "github_edit_comment"
        case .rebaseBranch: return "github_update_branch"
        case .deleteBranch: return "github_delete_branch"
        case .revert: return "github_revert_pr"
        case .setMaintainerEdits: return "github_edit_pr"
        case .enableAutoMerge, .disableAutoMerge: return "github_auto_merge"
        }
    }

    /// What the action log keeps of it: short, without the full text you wrote.
    func auditArgs(repo: String, number: Int) -> String {
        let target = "\(repo)#\(number)"
        switch self {
        case .review(let verdict, _): return "\(target) \(verdict.event)"
        case .comment(let body): return "\(target) comment (\(body.count) characters)"
        case .close: return "\(target) close"
        case .reopen: return "\(target) reopen"
        case .edit(let title, _): return "\(target) title: \(String(title.prefix(80)))"
        case .requestReviewers(let people): return "\(target) reviewers: \(Self.logins(people).joined(separator: ", "))"
        case .updateBranch: return "\(target) update branch"
        case .addLabels(let labels): return "\(target) + \(labels.joined(separator: ", "))"
        case .removeLabel(let label): return "\(target) − \(label)"
        case .markReady: return "\(target) ready for review"
        case .markDraft: return "\(target) convert to draft"
        case .changeBase(let branch): return "\(target) base: \(branch)"
        case .approveWorkflow(let runID): return "\(target) approve workflow run \(runID)"
        case .reviewWithComments(let verdict, _, _, let comments): return "\(target) \(verdict.event) with \(comments.count) line comments"
        case .reply(let id, let body): return "\(target) reply to \(id) (\(body.count) characters)"
        case .setThreadResolved(_, let resolved): return "\(target) thread \(resolved ? "resolved" : "reopened")"
        case .editComment(let id, _, let body): return "\(target) edit comment \(id) (\(body.count) characters)"
        case .rebaseBranch: return "\(target) rebase branch"
        case .deleteBranch(let repository, let branch): return "\(repository) delete \(branch)"
        case .revert: return "\(target) revert"
        case .setMaintainerEdits(let allowed): return "\(target) maintainer edits \(allowed ? "on" : "off")"
        case .enableAutoMerge(_, let method): return "\(target) auto-merge \(method.rawValue)"
        case .disableAutoMerge: return "\(target) auto-merge off"
        }
    }

    /// "@anna, bob" → ["anna", "bob"]: GitHub logins, without @, duplicates or anything that is not a login.
    static func logins(_ people: [String]) -> [String] {
        var seen = Set<String>()
        return people
            .flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }
            .map { String($0.drop { $0 == "@" }) }
            .filter { login in
                !login.isEmpty && login.count <= 39 && login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
                    && seen.insert(login.lowercased()).inserted
            }
    }

    /// The first error in a GraphQL answer, which GitHub sends with status 200; nil when there is none.
    static func graphQLError(_ object: [String: Any]) -> String? {
        guard let errors = object["errors"] as? [[String: Any]], !errors.isEmpty else { return nil }
        let message = errors.compactMap { $0["message"] as? String }.first ?? "unknown error"
        return "GitHub: " + message
    }

    /// GitHub's answer to a refused action, in words.
    static func error(status: Int, object: [String: Any]) -> String {
        let message = (object["message"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let details = ((object["errors"] as? [Any]) ?? []).compactMap { item -> String? in
            if let text = item as? String { return text }
            return (item as? [String: Any])?["message"] as? String
        }
        let reason = ([message] + details).filter { !$0.isEmpty }.joined(separator: " ")
        switch status {
        case 401: return "GitHub rejected the connection (401). Reconnect in Settings › Connections."
        case 403: return "GitHub did not permit this (403)." + (reason.isEmpty ? "" : " " + reason)
        case 404: return "GitHub could not find the pull request, or this account has no access to it (404)."
        case 409: return "The branch changed since you opened it (409). Look at the new commits and try again."
        case 422: return "GitHub refused this (422)." + (reason.isEmpty ? "" : " " + reason)
        default: return reason.isEmpty ? "GitHub returned an error (\(status))." : "GitHub: " + reason
        }
    }
}
