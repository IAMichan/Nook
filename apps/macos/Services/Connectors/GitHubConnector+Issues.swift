import SwiftUI
import os

extension GitHubConnector {
    private static func issueSchema(_ properties: [String: [String: Any]], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }

    var issueTools: [ToolSpec] {
        [
            ToolSpec(
                name: "github_search",
                description: "Searches issues and pull requests on GitHub using a GitHub query, most recently updated first, with status, labels, and links. Example queries: \"launch repo:IAMichan/nook\", \"is:issue is:open label:bug\", \"involves:@me deadline\". Use this to find requirements, decisions, or outstanding work in issues.",
                schema: Self.issueSchema([
                    "query": ["type": "string", "description": "GitHub search query (same syntax as on github.com)."],
                    "type": ["type": "string", "enum": ["issue", "pr", "all"], "description": "Issues only, PRs only, or both (default)."] as [String: Any]
                ], required: ["query"]),
                kind: .read,
                summarize: { input in "Search GitHub: \((input["query"] as? String) ?? "")" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let query = ((input["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !query.isEmpty else { throw NookError("Search query is missing.") }
                    return try await self.searchIssues(query, type: (input["type"] as? String) ?? "all", input: input)
                }
            ),
            ToolSpec(
                name: "github_issue_details",
                description: "Reads a single issue (or the discussion on a pull request): title, status, labels, description, and recent comments.",
                schema: GitHubPR.schema(),
                kind: .read,
                summarize: { input in "Read GitHub: \(GitHubPR.ref(input))" },
                tag: { _ in ("", .neutral) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    return try await self.issueDetails(repo: target.repo, number: target.number, input: input)
                }
            ),
            ToolSpec(
                name: "github_create_issue",
                description: "Creates a new issue in a repository. Write a clear title and description (Markdown). Labels are optional, comma-separated, and must already exist in the repository.",
                schema: Self.issueSchema([
                    "repo": ["type": "string", "description": "Repository as owner/name."],
                    "title": ["type": "string", "description": "Issue title."],
                    "body": ["type": "string", "description": "Description (Markdown)."],
                    "labels": ["type": "string", "description": "Labels, comma-separated. Optional."]
                ], required: ["repo", "title"]),
                kind: .action,
                summarize: { input in
                    "GitHub: issue in \((input["repo"] as? String) ?? "?") · \(CloudHelp.short((input["title"] as? String) ?? "", 60))"
                },
                tag: { _ in ("Create", .caution) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let repo = ((input["repo"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard ActionGate.isRepository(repo) else { throw NookError("The repository must be owner/name.") }
                    guard let title = GitHubPR.text(input, "title") else { throw NookError("Title is missing.") }
                    var payload: [String: Any] = ["title": title]
                    if let body = GitHubPR.text(input, "body") { payload["body"] = body }
                    let labels = Self.labels(input)
                    if !labels.isEmpty { payload["labels"] = labels }
                    let result = try await self.send("POST", "/repos/\(repo)/issues", body: payload, input: input)
                    let number = CloudHelp.int(result["number"]).map { "#\($0)" } ?? ""
                    let url = (result["html_url"] as? String).map { " · \($0)" } ?? ""
                    return "Issue created: \(repo)\(number)\(url)"
                }
            ),
            ToolSpec(
                name: "github_comment_issue",
                description: "Posts a comment on an issue (or the discussion of a pull request).",
                schema: GitHubPR.schema(["body": ["type": "string", "description": "The comment text."]], required: ["body"]),
                kind: .action,
                summarize: { input in "GitHub: comment on \(GitHubPR.ref(input)) · " + CloudHelp.short(GitHubPR.text(input, "body") ?? "", 50) },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    guard let body = GitHubPR.text(input, "body") else { throw NookError("Comment text is missing.") }
                    let result = try await self.send("POST", "/repos/\(target.repo)/issues/\(target.number)/comments", body: ["body": body], input: input)
                    return "Comment posted on \(target.repo)#\(target.number)" + ((result["html_url"] as? String).map { " · \($0)" } ?? "")
                }
            ),
            ToolSpec(
                name: "github_update_issue",
                description: "Updates an issue: close or reopen, change title, or add labels. Only provided fields are updated.",
                schema: GitHubPR.schema([
                    "state": ["type": "string", "enum": ["open", "closed"], "description": "open or closed. Optional."] as [String: Any],
                    "title": ["type": "string", "description": "New title. Optional."],
                    "labels": ["type": "string", "description": "Labels to add, comma-separated. Optional."]
                ]),
                kind: .action,
                summarize: { input in
                    var parts: [String] = []
                    if let state = GitHubPR.text(input, "state") { parts.append(state == "closed" ? "close" : "reopen") }
                    if let title = GitHubPR.text(input, "title") { parts.append("title \"\(CloudHelp.short(title, 40))\"") }
                    if let labels = GitHubPR.text(input, "labels") { parts.append("labels \(labels)") }
                    return "GitHub: \(GitHubPR.ref(input)) " + (parts.isEmpty ? "update" : parts.joined(separator: ", "))
                },
                tag: { input in GitHubPR.text(input, "state") == "closed" ? ("Close", .caution) : ("Update", .caution) },
                run: { [weak self] input in
                    guard let self else { throw CloudHelp.notSetUp("GitHub") }
                    let target = try GitHubPR.target(input)
                    var payload: [String: Any] = [:]
                    if let state = GitHubPR.text(input, "state") {
                        guard ["open", "closed"].contains(state) else { throw NookError("Status must be open or closed.") }
                        payload["state"] = state
                    }
                    if let title = GitHubPR.text(input, "title") { payload["title"] = title }
                    if !payload.isEmpty {
                        _ = try await self.send("PATCH", "/repos/\(target.repo)/issues/\(target.number)", body: payload, input: input)
                    }
                    let labels = Self.labels(input)
                    if !labels.isEmpty {
                        _ = try await self.send("POST", "/repos/\(target.repo)/issues/\(target.number)/labels", body: ["labels": labels], input: input)
                    }
                    guard !payload.isEmpty || !labels.isEmpty else { throw NookError("There is nothing to update.") }
                    return "Updated: \(target.repo)#\(target.number)"
                }
            )
        ]
    }

    fileprivate static func labels(_ input: [String: Any]) -> [String] {
        (GitHubPR.text(input, "labels") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func readHeaders(_ input: [String: Any]) throws -> [String: String] {
        let token = try credentials(input).token
        return [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }

    fileprivate func searchIssues(_ query: String, type: String, input: [String: Any]) async throws -> String {
        var q = query
        if type == "issue", !q.contains("is:issue") { q += " is:issue" }
        if type == "pr", !q.contains("is:pr") { q += " is:pr" }
        let url = try CloudHelp.url("https://api.github.com", "/search/issues", query: [
            ("q", q), ("sort", "updated"), ("order", "desc"), ("per_page", "15")
        ])
        let root = CloudHelp.object(try await ConnectorHTTP.json(url, headers: try readHeaders(input)))
        let items = CloudHelp.list(root["items"])
        if items.isEmpty { return "No issues or pull requests found for \"\(query)\"." }
        var lines = ["\(CloudHelp.int(root["total_count"]) ?? items.count) results, \(items.count) most recently updated:"]
        var refs: [String] = []
        for item in items {
            let repoURL = (item["repository_url"] as? String) ?? ""
            let repo = repoURL.replacingOccurrences(of: "https://api.github.com/repos/", with: "")
            let number = CloudHelp.int(item["number"]) ?? 0
            let kind = item["pull_request"] != nil ? "PR" : "issue"
            let labels = CloudHelp.list(item["labels"]).compactMap { $0["name"] as? String }
            let title = (item["title"] as? String) ?? "Untitled"
            var line = "- \(repo)#\(number) [\(kind), \((item["state"] as? String) ?? "?")] '\(title)'"
            if !labels.isEmpty { line += " · labels: \(labels.joined(separator: ", "))" }
            if let updated = CloudHelp.date(item["updated_at"]) { line += " · updated \(NookDates.short(updated))" }
            if let author = CloudHelp.object(item["user"])["login"] as? String { line += " · by @\(author)" }
            lines.append(line)
            refs.append(ReferenceParser.line(title: "\(repo)#\(number) \(title)", url: CloudHelp.link(item["html_url"] as? String)?.absoluteString,
                                             detail: "\(kind) · \((item["state"] as? String) ?? "")"))
        }
        return (lines + refs).joined(separator: "\n")
    }

    fileprivate func issueDetails(repo: String, number: Int, input: [String: Any]) async throws -> String {
        let auth = try readHeaders(input)
        let base = "https://api.github.com/repos/\(repo)/issues/\(number)"
        let issue = CloudHelp.object(try await ConnectorHTTP.json(try CloudHelp.url(base), headers: auth))
        let comments = CloudHelp.list(try? await ConnectorHTTP.json(try CloudHelp.url(base, "/comments", query: [("per_page", "30")]), headers: auth))
        let title = (issue["title"] as? String) ?? "Untitled"
        let labels = CloudHelp.list(issue["labels"]).compactMap { $0["name"] as? String }
        var out = ["\(repo)#\(number) '\(title)' by @\((CloudHelp.object(issue["user"])["login"] as? String) ?? "?")"]
        var facts = ["status: \((issue["state"] as? String) ?? "?")"]
        if !labels.isEmpty { facts.append("labels: \(labels.joined(separator: ", "))") }
        if let created = CloudHelp.date(issue["created_at"]) { facts.append("opened \(NookDates.short(created))") }
        if let updated = CloudHelp.date(issue["updated_at"]) { facts.append("updated \(NookDates.short(updated))") }
        let assignees = CloudHelp.list(issue["assignees"]).compactMap { $0["login"] as? String }
        if !assignees.isEmpty { facts.append("assigned to: \(assignees.map { "@\($0)" }.joined(separator: ", "))") }
        out.append(facts.joined(separator: " · "))
        if let body = (issue["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            out.append("")
            out.append("Description:")
            out.append(String(body.prefix(4000)))
        }
        if !comments.isEmpty {
            out.append("")
            out.append("Comments (last \(min(comments.count, 15))):")
            for comment in comments.suffix(15) {
                let who = (CloudHelp.object(comment["user"])["login"] as? String) ?? "?"
                let when = CloudHelp.date(comment["created_at"]).map { NookDates.short($0) } ?? ""
                out.append("- @\(who) \(when): " + CloudHelp.short((comment["body"] as? String) ?? "", 600))
            }
        }
        out.append(ReferenceParser.line(title: "\(repo)#\(number) \(title)", url: CloudHelp.link(issue["html_url"] as? String)?.absoluteString,
                                        detail: (issue["state"] as? String) ?? ""))
        return out.joined(separator: "\n")
    }
}
