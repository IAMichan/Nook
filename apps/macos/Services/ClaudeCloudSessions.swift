import Foundation

/// A Claude Code session that runs in Anthropic's cloud: started in the Claude app (desktop or phone) or on claude.ai/code.
/// It has no process and no transcript on this Mac, so Nook only knows it from the account's session list.
struct CloudSession: Equatable {
    enum Status: Equatable {
        case running
        /// Waiting for an answer or an approval.
        case needsYou
        case idle
        case failed
        case archived
    }

    var id: String
    var title: String
    var status: Status
    /// Where it was started: "desktop_app", "web", "mobile_app", …; empty when the list does not say.
    var origin: String
    /// The repository it works in, as "owner/repo"; empty when it has none.
    var repository: String
    var branch: String
    var model: String
    var created: Date
    var updated: Date

    /// Where the session opens in the browser or the Claude app.
    var url: String { "https://claude.ai/code/\(id)" }

    var isActive: Bool { status == .running || status == .needsYou }
}

/// Why an account's cloud sessions could not be read, so the list can say so instead of staying silently empty.
enum CloudSessionProblem: Error, Equatable, Sendable {
    /// No Claude subscription login from Claude Code on this Mac.
    case notSignedIn
    /// The login ran out; Claude Code renews it the next time it runs.
    case loginExpired
    /// Anthropic refused the request (HTTP status).
    case refused(Int)
    /// No answer: offline or timed out.
    case unreachable
}

enum ClaudeCloudSessions {
    /// The session list endpoint Claude Code itself uses for `--teleport` and remote sessions.
    static let endpoint = URL(string: "https://api.anthropic.com/v1/sessions")!
    static let beta = "ccr-byoc-2025-07-29"
    /// Who is signed in, with their organization; Claude Code falls back to it when its account file has no organization.
    static let profileEndpoint = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// The organization in a profile response (`{"organization": {"uuid": …}}`).
    static func organization(fromProfile data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let org = (object["organization"] as? [String: Any])?["uuid"] as? String, !org.isEmpty else { return nil }
        return org
    }

    /// The sessions in a list response (`{"data": [...]}`), newest first. Archived sessions are left out.
    static func parse(_ data: Data) -> [CloudSession] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let object = (root as? [String: Any]) ?? [:]
        let items = (object["data"] as? [[String: Any]]) ?? (object["sessions"] as? [[String: Any]]) ?? (root as? [[String: Any]]) ?? []
        return items.compactMap(session).filter { $0.status != .archived }.sorted { $0.updated > $1.updated }
    }

    static func session(_ item: [String: Any]) -> CloudSession? {
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }
        let context = (item["session_context"] as? [String: Any]) ?? [:]
        let created = date(item["created_at"]) ?? .distantPast
        return CloudSession(
            id: id,
            title: ((item["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            status: status(item["session_status"] as? String ?? item["status"] as? String ?? ""),
            origin: (item["origin"] as? String) ?? "",
            repository: repository(context["sources"]),
            branch: branch(context["outcomes"]),
            model: (context["model"] as? String) ?? "",
            created: created,
            updated: date(item["updated_at"]) ?? created
        )
    }

    /// "running", "requires_action", or the long form "SESSION_STATUS_RUNNING".
    static func status(_ raw: String) -> CloudSession.Status {
        var value = raw.lowercased()
        if value.hasPrefix("session_status_") { value.removeFirst("session_status_".count) }
        switch value {
        case "running", "pending", "starting": return .running
        case "requires_action", "waiting", "blocked": return .needsYou
        case "failed", "error": return .failed
        case "archived", "deleted": return .archived
        default: return .idle
        }
    }

    /// The first git repository among the sources, as "owner/repo". The source is either `{"type": "git_repository",
    /// "url": …}` or `{"git_repository": {"url": …}}`.
    private static func repository(_ raw: Any?) -> String {
        for source in (raw as? [[String: Any]]) ?? [] {
            let url = ((source["git_repository"] as? [String: Any])?["url"] as? String)
                ?? (source["type"] as? String == "git_repository" ? source["url"] as? String : nil)
            guard let url, !url.isEmpty else { continue }
            var path = URL(string: url)?.path ?? url
            if path.hasSuffix(".git") { path.removeLast(4) }
            return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return ""
    }

    private static func branch(_ raw: Any?) -> String {
        for outcome in (raw as? [[String: Any]]) ?? [] {
            let repo = (outcome["git_repository"] as? [String: Any]) ?? outcome
            let info = (repo["git_info"] as? [String: Any]) ?? [:]
            if let branch = (info["branches"] as? [String])?.first, !branch.isEmpty { return branch }
        }
        return ""
    }

    private static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        return NookDates.isoFractional.date(from: text) ?? NookDates.isoPlain.date(from: text)
    }

    /// The organization the session list belongs to, from Claude Code's own account file.
    static func organizationID(configHome: URL, isDefault: Bool) -> String? {
        var candidates = [configHome.appendingPathComponent(".claude.json"), configHome.appendingPathComponent(".config.json")]
        if isDefault && ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] == nil {
            candidates.insert(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"), at: 0)
        }
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let oauth = root["oauthAccount"] as? [String: Any],
                  let org = oauth["organizationUuid"] as? String, !org.isEmpty else { continue }
            return org
        }
        return nil
    }
}
