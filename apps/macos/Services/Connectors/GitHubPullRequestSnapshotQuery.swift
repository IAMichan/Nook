import Foundation

/// A pull request's state, checks, reviews and comments in one GraphQL request, where the REST read
/// (`GitHubPullRequests.snapshot`) takes five. GraphQL has an hourly limit of its own, so once REST runs low the badges
/// and watched pull requests keep going on this one (`ForgeRateBudget.prefersGraphQL`), as t3code reads its pull
/// requests. Foundation only, so tests can use it.
enum GitHubPullRequestSnapshotQuery {
    static let query = """
    query NookPullRequestSnapshot($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          title state merged isDraft mergeable mergeStateStatus baseRefName
          autoMergeRequest { enabledAt }
          commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
            __typename
            ... on CheckRun { name status conclusion }
            ... on StatusContext { context state }
          } } } } } }
          reviews(last: 100) { nodes { state body author { __typename login } } }
          comments(last: 100) { nodes { body createdAt author { __typename login } } }
          reviewThreads(last: 50) { nodes { path comments(last: 20) { nodes { body createdAt author { __typename login } } } } }
        }
      }
    }
    """

    /// The request body for `owner/repo` and the pull request's number; nil for a repository name without an owner.
    static func body(repo: String, number: Int) -> Data? {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let variables: [String: Any] = ["owner": parts[0], "name": parts[1], "number": number]
        return try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// The snapshot in the same words the REST read gives, so a watch sees no news when the way in changes. Nil when
    /// GitHub did not answer with the pull request.
    static func parse(_ root: [String: Any]) -> PullRequestSnapshot? {
        guard let data = root["data"] as? [String: Any],
              let pull = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else { return nil }
        let merged = (pull["merged"] as? Bool) ?? false
        let state = merged ? "merged" : ((pull["state"] as? String) == "OPEN" ? "open" : "closed")

        // Check runs (failed: the conclusions the REST read counts) and the older commit statuses.
        let commit = ((((pull["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last)?["commit"] as? [String: Any])
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        var failed: [String] = []
        var pending = false
        for context in contexts {
            if context["__typename"] as? String == "StatusContext" {
                let value = ((context["state"] as? String) ?? "").uppercased()
                if ["FAILURE", "ERROR"].contains(value) { failed.append((context["context"] as? String) ?? "?") }
                if ["PENDING", "EXPECTED"].contains(value) { pending = true }
            } else {
                if ((context["status"] as? String) ?? "").uppercased() != "COMPLETED" { pending = true }
                let conclusion = ((context["conclusion"] as? String) ?? "").uppercased()
                if ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED"].contains(conclusion) {
                    failed.append((context["name"] as? String) ?? "?")
                }
            }
        }
        let checks = !failed.isEmpty ? "failure" : pending ? "pending" : contexts.isEmpty ? "" : "success"

        func nodes(_ value: Any?) -> [[String: Any]] { ((value as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [] }
        // REST names an app "name[bot]", GraphQL only "name": the REST spelling, so a comment is the same note either way.
        func author(_ item: [String: Any]) -> String {
            guard let who = item["author"] as? [String: Any], let login = who["login"] as? String else { return "?" }
            return who["__typename"] as? String == "Bot" && !login.hasSuffix("[bot]") ? login + "[bot]" : login
        }
        let reviews = nodes(pull["reviews"])
            .filter { ($0["state"] as? String) != "PENDING" }
            .map { PullRequestSnapshot.Note(author: author($0), verdict: ($0["state"] as? String) ?? "", text: ($0["body"] as? String) ?? "") }
        var dated: [(at: String, note: PullRequestSnapshot.Note)] = nodes(pull["comments"]).map {
            (($0["createdAt"] as? String) ?? "", .init(author: author($0), verdict: "", text: ($0["body"] as? String) ?? ""))
        }
        for thread in nodes(pull["reviewThreads"]) {
            let path = thread["path"] as? String
            for comment in nodes(thread["comments"]) {
                let text = (comment["body"] as? String) ?? ""
                dated.append(((comment["createdAt"] as? String) ?? "",
                              .init(author: author(comment), verdict: "", text: path.map { $0 + ": " + text } ?? text)))
            }
        }
        let comments = dated.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element.note)

        let mergeable = ((pull["mergeable"] as? String) ?? "UNKNOWN").uppercased()
        let mergeState = ((pull["mergeStateStatus"] as? String) ?? "UNKNOWN").lowercased()
        return PullRequestSnapshot(state: state, checks: checks, failedChecks: failed, reviews: reviews, comments: comments,
                                   draft: (pull["isDraft"] as? Bool) ?? false,
                                   conflicted: mergeable == "CONFLICTING" || mergeState == "dirty",
                                   merge: PullRequestMergeFacts(state: mergeState,
                                                                autoMerge: pull["autoMergeRequest"] is [String: Any],
                                                                baseBranch: (pull["baseRefName"] as? String) ?? ""),
                                   mergeabilityKnown: mergeable != "UNKNOWN" || mergeState == "dirty",
                                   checksKnown: commit != nil, title: pull["title"] as? String)
    }
}
