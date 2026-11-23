import Foundation

/// A pull request's state, checks, reviews and comments through GraphQL, where the REST read
/// (`GitHubPullRequests.snapshot`) takes five requests, and several pull requests in one request
/// (`GitHubSnapshotBatcher`), as t3code reads its pull requests. GraphQL has an hourly limit of its own
/// (`ForgeRateBudget.prefersGraphQL`). Foundation only, so tests can use it.
enum GitHubPullRequestSnapshotQuery {
    /// What one pull request's snapshot reads, shared by the single query and the batched one.
    static let fragment = """
    fragment nookSnapshot on PullRequest {
      title state merged isDraft mergeable mergeStateStatus baseRefName
      autoMergeRequest { enabledAt }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { name status conclusion startedAt databaseId }
        ... on StatusContext { context state }
      } } } } } }
      reviews(last: 100) { nodes { state body author { __typename login } } }
      comments(last: 100) { nodes { body createdAt author { __typename login } } }
      reviewThreads(last: 50) { nodes { path comments(last: 20) { nodes { body createdAt author { __typename login } } } } }
    }
    """

    static let query = """
    query NookPullRequestSnapshot($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { pullRequest(number: $number) { ...nookSnapshot } }
    }
    """ + "\n" + fragment

    /// At most this many pull requests in one request: GitHub charges a batch by the connections it reads (about half a
    /// point per pull request here), and one slow repository should not hold up a long list.
    static let batchLimit = 20

    /// One request for several pull requests (`owner/repo`, number): each under its own alias (`p0`, `p1` …) with its own
    /// variables, so a missing or hidden one fails only its own slice, as t3code batches its pull request reads. Nil
    /// when none of them names an owner.
    static func batchBody(_ items: [(repo: String, number: Int)]) -> Data? {
        var declarations: [String] = []
        var fields: [String] = []
        var variables: [String: Any] = [:]
        for (index, item) in items.enumerated() {
            let parts = item.repo.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            declarations.append("$o\(index): String!, $n\(index): String!, $k\(index): Int!")
            fields.append("  p\(index): repository(owner: $o\(index), name: $n\(index)) { pullRequest(number: $k\(index)) { ...nookSnapshot } }")
            variables["o\(index)"] = parts[0]
            variables["n\(index)"] = parts[1]
            variables["k\(index)"] = item.number
        }
        guard !fields.isEmpty else { return nil }
        let text = "query NookPullRequestSnapshots(\(declarations.joined(separator: ", "))) {\n\(fields.joined(separator: "\n"))\n}\n" + fragment
        return try? JSONSerialization.data(withJSONObject: ["query": text, "variables": variables])
    }

    /// Each batched pull request's snapshot by its place in the batch; nil where GitHub had none (missing, or hidden from
    /// this account), so another account can try that one.
    static func parseBatch(_ root: [String: Any], count: Int) -> [PullRequestSnapshot?] {
        let data = root["data"] as? [String: Any]
        return (0..<count).map { index in
            guard let pull = (data?["p\(index)"] as? [String: Any])?["pullRequest"] as? [String: Any] else { return nil }
            return parse(pull: pull)
        }
    }

    /// The request body for `owner/repo` and the pull request's number; nil for a repository name without an owner.
    static func body(repo: String, number: Int) -> Data? {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let variables: [String: Any] = ["owner": parts[0], "name": parts[1], "number": number]
        return try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    }

    /// The single query's answer.
    static func parse(_ root: [String: Any]) -> PullRequestSnapshot? {
        guard let data = root["data"] as? [String: Any],
              let pull = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any] else { return nil }
        return parse(pull: pull)
    }

    /// Only the newest run of each check counts, as in the REST read (`PullRequestDetailParser.latestRuns`): a workflow
    /// that runs again on the same commit (an edited description, a re-run) leaves its old failure in the rollup, and
    /// GitHub's rollup still counts it. Newest by start time (ISO 8601, so the text sorts), then by id. Commit statuses
    /// already come once per context, with their latest state.
    static func latestRuns(_ contexts: [[String: Any]]) -> [[String: Any]] {
        func order(_ run: [String: Any]) -> (String, Int) {
            ((run["startedAt"] as? String) ?? "", (run["databaseId"] as? NSNumber)?.intValue ?? 0)
        }
        var newest: [String: Int] = [:]
        var result: [[String: Any]] = []
        for context in contexts {
            guard context["__typename"] as? String == "CheckRun" else { result.append(context); continue }
            let name = (context["name"] as? String) ?? "?"
            if let index = newest[name] {
                if order(context) > order(result[index]) { result[index] = context }
            } else {
                newest[name] = result.count
                result.append(context)
            }
        }
        return result
    }

    /// The snapshot in the same words the REST read gives, so a watch sees no news when the way in changes.
    static func parse(pull: [String: Any]) -> PullRequestSnapshot {
        let merged = (pull["merged"] as? Bool) ?? false
        let state = merged ? "merged" : ((pull["state"] as? String) == "OPEN" ? "open" : "closed")

        // Check runs (failed: the conclusions the REST read counts) and the older commit statuses.
        let commit = ((((pull["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last)?["commit"] as? [String: Any])
        let rollup = commit?["statusCheckRollup"] as? [String: Any]
        let contexts = latestRuns(((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? [])
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
