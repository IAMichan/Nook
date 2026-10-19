import Foundation

// GitLab's REST API (v4) for merge requests, as pure request building and response parsing. A merge request is what the
// rest of Nook calls a pull request (`PullRequestLink`). Foundation only; the connector does the networking.

enum GitLabAPI {
    /// Only https is ever used with a token: a PAT sent over http would be readable on the network.
    static func apiBase(_ repo: RemoteRepository) -> String? {
        guard repo.host == .gitlab, repo.webOrigin.hasPrefix("https://") else { return nil }
        return repo.webOrigin + "/api/v4"
    }

    /// The project id in a path is the namespace/path with every slash encoded: "group%2Fsub%2Fproject".
    static func projectID(_ repo: RemoteRepository) -> String {
        repo.path.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? repo.path
    }

    static func listURL(repo: RemoteRepository, sourceBranch: String, state: String = "all", perPage: Int = 10) -> URL? {
        guard let base = apiBase(repo),
              var components = URLComponents(string: "\(base)/projects/\(projectID(repo))/merge_requests") else { return nil }
        // URLComponents would re-encode the %2F of the project id as %252F, so the path is set raw.
        components.percentEncodedPath = "/api/v4/projects/\(projectID(repo))/merge_requests"
        components.queryItems = [URLQueryItem(name: "source_branch", value: sourceBranch), URLQueryItem(name: "state", value: state),
                                 URLQueryItem(name: "per_page", value: String(perPage)), URLQueryItem(name: "order_by", value: "updated_at")]
        return components.url
    }

    static func createURL(repo: RemoteRepository) -> URL? {
        guard let base = apiBase(repo) else { return nil }
        return URL(string: "\(base)/projects/\(projectID(repo))/merge_requests")
    }

    /// GitLab has no draft flag on create: a draft is a title that starts with "Draft:".
    static func createBody(title: String, description: String, source: String, target: String, draft: Bool) -> [String: Any] {
        var clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft, !clean.lowercased().hasPrefix("draft:") { clean = "Draft: " + clean }
        return ["title": clean, "description": description, "source_branch": source, "target_branch": target,
                "remove_source_branch": false]
    }

    static func state(_ item: [String: Any]) -> PullRequestState {
        switch (item["state"] as? String)?.lowercased() {
        case "merged": return .merged
        case "closed", "locked": return .closed
        default: return (item["draft"] as? Bool) == true || (item["work_in_progress"] as? Bool) == true ? .draft : .open
        }
    }

    static func parseList(_ data: Data, repository: RemoteRepository, sourceBranch: String) -> [PullRequestLink]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        return list.compactMap { item in
            guard let number = item["iid"] as? Int, let url = item["web_url"] as? String else { return nil }
            let stamp = item["updated_at"] as? String
            return PullRequestLink(host: .gitlab, repository: repository.displayName, number: number, url: url,
                                   title: item["title"] as? String, state: state(item),
                                   updatedAt: stamp.flatMap { iso.date(from: $0) ?? plain.date(from: $0) },
                                   baseBranch: item["target_branch"] as? String, headBranch: sourceBranch)
        }
    }

    static func parseCreated(_ data: Data) -> URL? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["web_url"].flatMap { $0 as? String }.flatMap(URL.init(string:))
    }

    /// GitLab answers errors as {"message": "…"} or {"message": {"field": ["…"]}} or {"error": "…"}.
    static func errorMessage(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let text = object["message"] as? String { return text }
        if let text = object["error"] as? String { return text }
        if let fields = object["message"] as? [String: Any] {
            let parts = fields.sorted { $0.key < $1.key }.map { key, value -> String in
                let detail = (value as? [String])?.joined(separator: ", ") ?? "\(value)"
                return "\(key) \(detail)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
        return nil
    }
}
