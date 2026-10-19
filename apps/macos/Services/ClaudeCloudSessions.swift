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

    // MARK: Conversation

    /// The events of one session: its conversation as Claude Code's stream messages, oldest first.
    static func eventsEndpoint(_ id: String, after: String? = nil) -> URL {
        var components = URLComponents(url: endpoint.appendingPathComponent(id).appendingPathComponent("events"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
        return components.url!
    }

    /// One page of an events response (`{"data": [...], "has_more": …, "last_id": …}`).
    static func eventPage(_ data: Data) -> (events: [[String: Any]], hasMore: Bool, lastID: String?)? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let events = object["data"] as? [[String: Any]] else { return nil }
        return (events, (object["has_more"] as? Bool) == true, object["last_id"] as? String)
    }

    /// The conversation in a session's events, read like a Claude Code transcript on this Mac. An event is either a
    /// stream message (`{"type": "assistant", "message": …}`) or one wrapped under its kind
    /// (`{"assistant": {"uuid": …, "internal_anthropic_catchall": {"message": …}}}`).
    static func conversation(_ events: [[String: Any]]) -> [AgentChatMessage] {
        var seen = Set<String>()
        var lines: [(date: Date?, line: [String: Any])] = []
        for event in events {
            guard let line = transcriptLine(event) else { continue }
            if let uuid = line["uuid"] as? String, !seen.insert(uuid).inserted { continue }
            lines.append((AgentTranscript.date(line["timestamp"]), line))
        }
        // Oldest first, also when a page came newest first; events without a time keep their place.
        if lines.allSatisfy({ $0.date != nil }) {
            lines = lines.enumerated().sorted { ($0.element.date!, $0.offset) < ($1.element.date!, $1.offset) }.map(\.element)
        }
        var data = Data()
        for (_, line) in lines {
            guard let json = try? JSONSerialization.data(withJSONObject: line) else { continue }
            data.append(json)
            data.append(0x0A)
        }
        return AgentTranscript.jsonl(data)
    }

    private static func transcriptLine(_ event: [String: Any]) -> [String: Any]? {
        var kind = event["type"] as? String ?? ""
        var body = event
        if kind != "user" && kind != "assistant" {
            guard let wrapped = (event["user"] ?? event["assistant"]) as? [String: Any] else { return nil }
            kind = event["user"] != nil ? "user" : "assistant"
            body = wrapped
            if let inner = wrapped["internal_anthropic_catchall"] as? [String: Any] {
                body = inner.merging(wrapped) { kept, _ in kept }
            }
        }
        guard let message = body["message"] as? [String: Any] else { return nil }
        var line: [String: Any] = ["type": kind, "message": message]
        if let uuid = body["uuid"] as? String { line["uuid"] = uuid }
        if let time = (body["timestamp"] as? String) ?? (event["created_at"] as? String) { line["timestamp"] = time }
        // A subagent's work (it answers a step of the main conversation) stays out, like sidechains in a transcript.
        if let parent = body["parent_tool_use_id"] as? String, !parent.isEmpty { line["isSidechain"] = true }
        return line
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
