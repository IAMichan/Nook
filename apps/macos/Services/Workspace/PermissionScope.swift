import Foundation

/// What "Always" would allow, as words, before you press it (the scope preview on a permission request), and the rules
/// already granted for a project (the list of granted rules).
///
/// Each agent says it differently: Claude Code sends `permission_suggestions` (rules with a destination: this project's
/// local settings, the project's shared settings, the user's settings, or only this session); Codex and the ACP agents
/// offer a plain "session" or "always" choice and say nothing about which command it covers. The switch over
/// `Reach` is exhaustive on purpose: a new kind of answer has to say what it covers.
enum PermissionScope {
    /// How far an "always" reaches.
    enum Reach: String, Equatable {
        /// This project, only on this Mac (`.claude/settings.local.json`).
        case project
        /// Everyone who uses the project (`.claude/settings.json`, checked in).
        case sharedProject
        /// Every project of the user.
        case user
        /// Until the session ends.
        case session
        /// The agent remembers it, and does not say where.
        case agentDecides
    }

    struct Rule: Equatable {
        /// `Bash(git status:*)`, `Edit`, a tool name when the agent names no pattern. Empty when the agent names none.
        let text: String
        let reach: Reach
    }

    /// The rules a request's suggestions would add. Empty when the agent offers no "always".
    static func rules(from suggestions: Any?) -> [Rule] {
        guard let list = suggestions as? [Any] else { return [] }
        var out: [Rule] = []
        for item in list {
            if let word = item as? String {
                // Codex and ACP agents: "session" or "always".
                out.append(Rule(text: "", reach: word == "session" ? .session : .agentDecides))
            } else if let entry = item as? [String: Any] {
                let reach = reach(destination: entry["destination"] as? String)
                guard let rules = entry["rules"] as? [[String: Any]] else { continue }
                for rule in rules {
                    guard let tool = rule["toolName"] as? String else { continue }
                    let content = (rule["ruleContent"] as? String) ?? ""
                    out.append(Rule(text: content.isEmpty ? tool : "\(tool)(\(content))", reach: reach))
                }
            }
        }
        return out
    }

    static func reach(destination: String?) -> Reach {
        switch destination {
        case "localSettings": return .project
        case "projectSettings": return .sharedProject
        case "userSettings": return .user
        case "session", "cliArg": return .session
        default: return .agentDecides
        }
    }

    static func word(_ reach: Reach) -> String {
        switch reach {
        case .project: return tr("approval.scope.project")
        case .sharedProject: return tr("approval.scope.shared")
        case .user: return tr("approval.scope.user")
        case .session: return tr("approval.scope.session")
        case .agentDecides: return tr("approval.scope.agent")
        }
    }

    /// One line for under the buttons: "Always allows Bash(git status:*) · this project". Nil when nothing is offered.
    static func preview(_ rules: [Rule]) -> String? {
        guard let first = rules.first else { return nil }
        let named = rules.map(\.text).filter { !$0.isEmpty }
        let shown = named.prefix(3).joined(separator: ", ") + (named.count > 3 ? " +\(named.count - 3)" : "")
        return named.isEmpty ? word(first.reach) : tr("approval.scope.line", shown, word(first.reach))
    }
}

/// The rules granted for a project, read from the agent's own settings files. Only Claude Code keeps them where Nook can
/// read them; Codex's and the ACP agents' answers live in their own apps and are not listed (docs/INTEGRATIONS.md).
enum GrantedRules {
    struct Entry: Equatable, Identifiable {
        let rule: String
        let reach: PermissionScope.Reach
        let file: String
        var id: String { file + "|" + rule }
    }

    /// The `permissions.allow` lists of the project's local and shared settings and of the user's settings.
    static func read(directory: String, home: String = NSHomeDirectory()) -> [Entry] {
        let files: [(String, PermissionScope.Reach)] = [
            (directory + "/.claude/settings.local.json", .project),
            (directory + "/.claude/settings.json", .sharedProject),
            (home + "/.claude/settings.json", .user),
        ]
        var out: [Entry] = []
        for (path, reach) in files {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            out += entries(json: data, reach: reach, file: path)
        }
        return out
    }

    static func entries(json: Data, reach: PermissionScope.Reach, file: String) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let permissions = root["permissions"] as? [String: Any],
              let allow = permissions["allow"] as? [String] else { return [] }
        return allow.map { Entry(rule: $0, reach: reach, file: file) }
    }

    /// The file's JSON without the rule, for writing it back (revoking a grant). Other keys stay as they are.
    static func removing(rule: String, from json: Data) -> Data? {
        guard var root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              var permissions = root["permissions"] as? [String: Any],
              var allow = permissions["allow"] as? [String], allow.contains(rule) else { return nil }
        allow.removeAll { $0 == rule }
        permissions["allow"] = allow
        root["permissions"] = permissions
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
