import Foundation

/// What you can do to a pull request from its page, besides merging it: review
/// it (approve, request changes, comment), write in its conversation, close or reopen it, edit its title and
/// description, ask people for a review, bring its branch up to date with the base, add or remove a label, mark a draft
/// ready for review, and point it at another base branch (when the pull request under it in a stack was merged). Each is
/// one GitHub call (REST, or GraphQL for marking ready), asked after your own click, and written to the action log. Foundation only, so
/// the requests are tested on their own.
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
    /// Merges into another branch from now on.
    case changeBase(String)

    static let markReadyMutation =
        "mutation NookMarkReady($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"

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
        case .changeBase(let branch):
            let name = branch.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return Request(method: "PATCH", path: pull, body: ["base": name])
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
        case .changeBase: return "github_change_base"
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
        case .changeBase(let branch): return "\(target) base: \(branch)"
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
