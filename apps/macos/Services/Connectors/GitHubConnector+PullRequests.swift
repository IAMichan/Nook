import SwiftUI
import os

/// Input for PR tools: which repo and which pull request. Outside the main actor so tool summaries can use it.
enum GitHubPR {
    static let repoPattern = "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"

    static func target(_ input: [String: Any]) throws -> (repo: String, number: Int) {
        let repo = ((input["repo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ActionGate.isRepository(repo) else {
            throw NookError("The repository must be owner/name, for example IAMichan/nook.")
        }
        guard let number = CloudHelp.int(input["number"]), number > 0 else {
            throw NookError("The pull request number is missing.")
        }
        return (repo, number)
    }

    /// "IAMichan/nook#23", for use in the plan.
    static func ref(_ input: [String: Any]) -> String {
        guard let parsed = try? GitHubPR.target(input) else { return "pull request" }
        return "\(parsed.repo)#\(parsed.number)"
    }

    static func text(_ input: [String: Any], _ key: String) -> String? {
        let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func schema(_ extra: [String: [String: Any]] = [:], required: [String] = []) -> [String: Any] {
        var properties: [String: [String: Any]] = [
            "repo": ["type": "string", "description": "Repository as owner/name, for example IAMichan/nook."],
            "number": ["type": "integer", "description": "Pull request number."]
        ]
        for (key, value) in extra { properties[key] = value }
        return ["type": "object", "properties": properties, "required": ["repo", "number"] + required]
    }
}

extension GitHubConnector {
    /// Reads run immediately; anything modifying GitHub goes through the user as a plan first.
    var pullRequestTools: [ToolSpec] {
        [
            ToolSpec(
                name: "github_pr_details",
                description: "Reads a single pull request completely: title, description, author, status, CI, existing reviews, and changed files with their diff. ALWAYS use this first when the user wants to review, approve, or merge a PR, and actually read the diff before rendering a verdict.",
                schema: GitHubPR.schema(),
                kind: .read,
                summarize: { input in "Read GitHub: \(GitHubPR.ref(input))" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    return try await self.pullRequestDetails(repo: target.repo, number: target.number, input: input)
                }
            ),
            ToolSpec(
                name: "github_review_pr",
                description: "Submits a review on a pull request: approve (APPROVE), request changes (REQUEST_CHANGES), or comment only (COMMENT). Inspect the diff with github_pr_details first. A comment body is required for REQUEST_CHANGES and COMMENT. You cannot approve your own pull request.",
                schema: GitHubPR.schema([
                    "event": ["type": "string", "enum": ["APPROVE", "REQUEST_CHANGES", "COMMENT"], "description": "The review action."],
                    "body": ["type": "string", "description": "The review text. Required for REQUEST_CHANGES and COMMENT."]
                ], required: ["event"]),
                kind: .action,
                summarize: { input in
                    let ref = GitHubPR.ref(input)
                    let note = GitHubPR.text(input, "body").map { " · " + CloudHelp.short($0, 50) } ?? ""
                    switch ((input["event"] as? String) ?? "").uppercased() {
                    case "APPROVE": return "GitHub: approve \(ref)" + note
                    case "REQUEST_CHANGES": return "GitHub: request changes on \(ref)" + note
                    default: return "GitHub: review on \(ref)" + note
                    }
                },
                tag: { input in
                    ((input["event"] as? String) ?? "").uppercased() == "REQUEST_CHANGES" ? ("Blocks", .caution) : ("", .good)
                },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    let event = ((input["event"] as? String) ?? "").uppercased()
                    guard ["APPROVE", "REQUEST_CHANGES", "COMMENT"].contains(event) else {
                        throw NookError("The review action must be APPROVE, REQUEST_CHANGES, or COMMENT.")
                    }
                    let body = GitHubPR.text(input, "body")
                    if event != "APPROVE" && body == nil { throw NookError("A comment body is required for this review action.") }
                    var payload: [String: Any] = ["event": event]
                    if let body = body { payload["body"] = body }
                    _ = try await self.send("POST", "/repos/\(target.repo)/pulls/\(target.number)/reviews", body: payload, input: input)
                    switch event {
                    case "APPROVE": return "Approved: \(target.repo)#\(target.number)"
                    case "REQUEST_CHANGES": return "Requested changes on: \(target.repo)#\(target.number)"
                    default: return "Review submitted on \(target.repo)#\(target.number)"
                    }
                }
            ),
            ToolSpec(
                name: "github_comment_pr",
                description: "Posts a regular comment on a pull request, without a review verdict.",
                schema: GitHubPR.schema([
                    "body": ["type": "string", "description": "The comment text."]
                ], required: ["body"]),
                kind: .action,
                summarize: { input in
                    "GitHub: comment on \(GitHubPR.ref(input)) · " + CloudHelp.short(GitHubPR.text(input, "body") ?? "", 50)
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    guard let body = GitHubPR.text(input, "body") else { throw NookError("Comment text is missing.") }
                    _ = try await self.send("POST", "/repos/\(target.repo)/issues/\(target.number)/comments", body: ["body": body], input: input)
                    return "Comment posted on \(target.repo)#\(target.number)"
                }
            ),
            ToolSpec(
                name: "github_merge_pr",
                description: "Merges a pull request. This is difficult to undo: only use when the user clearly asks, and check with github_pr_details first whether CI is green and the PR is not a draft. Choose the method requested by the user; without one, the repository's default (merge when its settings and rulesets allow it). To merge several pull requests at once, use github_merge_prs instead.",
                schema: GitHubPR.schema([
                    "method": ["type": "string", "enum": ["merge", "squash", "rebase"], "description": "Merge method. Defaults to the first one the repository allows (merge when allowed)."]
                ]),
                kind: .action,
                summarize: { input in
                    let method = (GitHubPR.text(input, "method") ?? "merge").lowercased()
                    return "GitHub: merge \(GitHubPR.ref(input)) (\(method))"
                },
                tag: { _ in ("Merge", .caution) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    let requested = GitHubPR.text(input, "method")?.lowercased()
                    if let requested, PullRequestMergeMethod(rawValue: requested) == nil {
                        throw NookError("The method must be merge, squash, or rebase.")
                    }
                    // Without a method: the first one the repository and its rulesets allow (merge when allowed), so a
                    // repository that only allows squash does not answer "Merge commits are not allowed".
                    var method = requested ?? "merge"
                    if requested == nil, let token = try? self.credentials(input).token,
                       let detail = try? await GitHubPullRequestDetail.loadForMerge(repo: target.repo, number: target.number, token: token),
                       let chosen = PullRequestQuickAction.mergeMethod(preferred: .merge, allowed: detail.methods) {
                        method = chosen.rawValue
                    }
                    let result = try await self.send("PUT", "/repos/\(target.repo)/pulls/\(target.number)/merge",
                                                     body: ["merge_method": method], input: input)
                    if (result["merged"] as? Bool) == false {
                        throw NookError((result["message"] as? String) ?? "GitHub did not merge the pull request.")
                    }
                    return "Merged (\(method)): \(target.repo)#\(target.number)"
                }
            ),
            ToolSpec(
                name: "github_merge_prs",
                description: "Merges several pull requests in one action, for 'merge all my PRs' or 'merge these PRs'. First list the pull requests the user means with github_overview (their open PRs) or github_search (for example \"is:pr is:open repo:owner/name\"), then pass every one of them here; no need to read each with github_pr_details. Right before merging, Nook checks each pull request itself and skips the ones that are a draft, closed, conflicted, or whose CI is failing, and reports why. CI that is still running does not stop a merge: approving the plan is the user's choice to merge now, so the report notes it instead. Choose the method requested by the user; without one, the repository's default (merge when allowed).",
                schema: [
                    "type": "object",
                    "properties": [
                        "pulls": ["type": "string", "description": "The pull requests, comma-separated, each as owner/name#number, for example \"IAMichan/nook#12, IAMichan/nook#14\"."],
                        "method": ["type": "string", "enum": ["merge", "squash", "rebase"], "description": "Merge method. Optional."] as [String: Any]
                    ] as [String: Any],
                    "required": ["pulls"]
                ],
                kind: .action,
                summarize: { input in
                    PullRequestBatchMerge.summary(input["pulls"], method: GitHubPR.text(input, "method")?.lowercased() ?? "repository default")
                },
                tag: { _ in ("Merge", .caution) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    return try await self.mergePullRequests(input)
                }
            ),
            ToolSpec(
                name: "github_close_pr",
                description: "Closes a pull request without merging. Only use when explicitly requested by the user.",
                schema: GitHubPR.schema(),
                kind: .action,
                summarize: { input in "GitHub: close \(GitHubPR.ref(input))" },
                tag: { _ in ("Close", .caution) },
                run: { [weak self] input in
                    guard let self = self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    _ = try await self.send("PATCH", "/repos/\(target.repo)/pulls/\(target.number)", body: ["state": "closed"], input: input)
                    return "Closed: \(target.repo)#\(target.number)"
                }
            )
        ]
    }

    // MARK: Writing

    /// Merges the approved pull requests one by one. Each is read again first and merged at the head that was checked, so
    /// nothing pushed in between gets merged unseen; what is not ready is skipped and the rest still goes ahead.
    fileprivate func mergePullRequests(_ input: [String: Any]) async throws -> String {
        let problems = PullRequestBatchMerge.problems(input["pulls"])
        guard problems.isEmpty else { throw NookError(problems.joined(separator: " ")) }
        let requested = GitHubPR.text(input, "method").map { $0.lowercased() }
        let method = requested.flatMap(PullRequestMergeMethod.init(rawValue:))
        if requested != nil, method == nil { throw NookError("The method must be merge, squash, or rebase.") }
        let token = try credentials(input).token
        var outcomes: [(PullRequestBatchMerge.Target, PullRequestBatchMerge.Outcome)] = []
        for target in PullRequestBatchMerge.targets(input["pulls"]).targets {
            do {
                let detail = try await GitHubPullRequestDetail.loadForMerge(repo: target.repo, number: target.number, token: token)
                if let reason = PullRequestBatchMerge.skipReason(detail) {
                    outcomes.append((target, .skipped(reason)))
                    continue
                }
                guard let chosen = PullRequestBatchMerge.method(requested: method, allowed: detail.methods) else {
                    outcomes.append((target, .skipped("\(requested ?? "merge") not allowed in this repository")))
                    continue
                }
                _ = try await GitHubPullRequestDetail.merge(repo: target.repo, number: target.number, method: chosen,
                                                            sha: detail.headSHA, token: token)
                outcomes.append((target, .merged(PullRequestBatchMerge.mergedLabel(chosen, detail))))
            } catch {
                outcomes.append((target, .failed(error.localizedDescription)))
            }
        }
        let report = PullRequestBatchMerge.report(outcomes)
        // Nothing merged at all: the step failed, with every reason, so the plan does not show it as done.
        guard outcomes.contains(where: { if case .merged = $0.1 { return true }; return false }) else { throw NookError(report) }
        return report
    }

    /// Performs a write action on GitHub and forwards GitHub's error message so Nook can explain why an action failed.
    func send(_ method: String, _ path: String, body: [String: Any], input: [String: Any]) async throws -> [String: Any] {
        let token = try credentials(input).token
        let url = try CloudHelp.url("https://api.github.com" + path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        for (key, value) in headers(token) { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ConnectorHTTP.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let message = (object["message"] as? String) ?? "GitHub returned an error (\(status))."
            switch status {
            case 401:
                throw NookError("GitHub rejected the connection (401). Reconnect in Settings › Connectors.")
            case 403, 404:
                throw NookError("GitHub did not permit this (\(status)): \(message) Does the connection have write access to pull requests? Otherwise reconnect using 'Connect with GitHub'.")
            default:
                throw NookError("GitHub: \(message)")
            }
        }
        return object
    }

    // MARK: Reading

    /// The PR with all context needed to review it. Truncated so a large diff does not flood the conversation.
    fileprivate func pullRequestDetails(repo: String, number: Int, input: [String: Any]) async throws -> String {
        let auth = headers(try credentials(input).token)
        let base = "https://api.github.com/repos/\(repo)/pulls/\(number)"
        let pull = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url(base), headers: auth))
        let files = CloudHelp.list(try await ConnectorHTTP.json(try CloudHelp.url(base, "/files", query: [("per_page", "30")]), headers: auth))
        var reviews: [[String: Any]] = []
        if let raw = try? await ConnectorHTTP.json(try CloudHelp.url(base, "/reviews", query: [("per_page", "30")]), headers: auth) {
            reviews = CloudHelp.list(raw)
        }
        let ci = await ciState(repo: repo, number: number, auth: auth)

        let author = (CloudHelp.object(pull["user"])["login"] as? String) ?? "?"
        let head = CloudHelp.object(pull["head"])
        let baseRef = CloudHelp.object(pull["base"])
        let merged = (pull["merged"] as? Bool) ?? false
        let state = merged ? "merged" : ((pull["state"] as? String) == "open" ? "open" : "closed")

        var out = ["\(repo)#\(number) '\((pull["title"] as? String) ?? "Untitled")' by @\(author)"]
        var facts = ["status: \(state)"]
        if (pull["draft"] as? Bool) == true { facts.append("draft") }
        if let mergeable = pull["mergeable"] as? Bool {
            facts.append(mergeable ? "no conflicts" : "conflicts")
        }
        if let mergeState = pull["mergeable_state"] as? String, mergeState != "unknown" { facts.append("mergeable_state: \(mergeState)") }
        let label = ciLabel(ci)
        if !label.isEmpty { facts.append(label) }
        out.append(facts.joined(separator: " · "))
        let fromRef = (head["ref"] as? String) ?? "?"
        let toRef = (baseRef["ref"] as? String) ?? "?"
        let added = CloudHelp.int(pull["additions"]) ?? 0
        let removed = CloudHelp.int(pull["deletions"]) ?? 0
        let changed = CloudHelp.int(pull["changed_files"]) ?? files.count
        let fileCount = CloudHelp.plural(changed, "file", "files")
        out.append("From \(fromRef) to \(toRef) · +\(added) −\(removed) in \(fileCount)")
        if let url = pull["html_url"] as? String { out.append(url) }

        if let body = (pull["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            out.append("")
            out.append("Description:")
            out.append(String(body.prefix(1500)))
        }

        if !reviews.isEmpty {
            out.append("")
            out.append("Reviews:")
            for review in reviews.suffix(10) {
                let who = (CloudHelp.object(review["user"])["login"] as? String) ?? "?"
                var line = "- @\(who): \((review["state"] as? String) ?? "?")"
                if let text = (review["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    line += " · " + CloudHelp.short(text, 160)
                }
                out.append(line)
            }
        }

        out.append("")
        out.append("Changed files:")
        var budget = 12000
        for file in files {
            let name = (file["filename"] as? String) ?? "?"
            var block = "### \(name) (\((file["status"] as? String) ?? "modified"), +\(CloudHelp.int(file["additions"]) ?? 0) −\(CloudHelp.int(file["deletions"]) ?? 0))"
            if let patch = file["patch"] as? String, budget > 0 {
                let cut = String(patch.prefix(min(1500, budget)))
                budget -= cut.count
                block += "\n" + cut + (cut.count < patch.count ? "\n… (diff truncated)" : "")
            } else if file["patch"] == nil {
                block += "\n(no diff available: binary or too large)"
            } else {
                block += "\n(diff omitted for brevity)"
            }
            out.append(block)
        }
        if (CloudHelp.int(pull["changed_files"]) ?? 0) > files.count {
            out.append("… and more files (only the first \(files.count) were fetched)")
        }
        return out.joined(separator: "\n")
    }
}
