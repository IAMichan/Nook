import Foundation

// A turn the API refused because the agent's version is too old for the model: "API Error: 400 Claude Code 2.1.100 does
// not support this model; version 2.1.200 or newer is required. Run claude update." Usually the update is the answer, and
// the failed turn offers it. But behind a custom endpoint (ANTHROPIC_BASE_URL pointing at a gateway or proxy) the version
// the API saw may not be the one that runs: the gateway rewrote it. When the installed version already meets the
// requirement, Nook says so instead of sending you to an update that changes nothing. Foundation only, so it is tested on
// its own (`AgentVersionRejectionTests`).

enum AgentVersionRejection {
    /// What the error said: the version the API saw and the one it requires, where it names them.
    struct Rejection: Equatable, Sendable {
        var reported: String?
        var required: String?
    }

    enum Verdict: Equatable, Sendable {
        /// The agent is too old: update it.
        case update(required: String?)
        /// The installed agent meets the requirement, so the custom endpoint `host` sent or checked another version.
        case endpointRewrote(host: String, reported: String, installed: String)
    }

    private static let claudePattern = try? NSRegularExpression(
        pattern: #"Claude Code (\d+(?:\.\d+)+) does not support this model; version (\d+(?:\.\d+)+) or newer is required"#)

    /// How the other agents say it, lowercased: Codex's "The 'gpt-5.5' model requires a newer version of Codex. Please
    /// upgrade to the latest app or CLI", and the same wording from Gemini CLI and gateways in front of other agents.
    static let phrases = [
        "requires a newer version of", "upgrade to the latest app or cli", "please upgrade to the latest version",
        "client version is too old", "this version of the cli is no longer supported",
    ]

    static func parse(_ text: String?) -> Rejection? {
        guard let text, !text.isEmpty else { return nil }
        if let regex = claudePattern,
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let reported = Range(match.range(at: 1), in: text), let required = Range(match.range(at: 2), in: text) {
            return Rejection(reported: String(text[reported]), required: String(text[required]))
        }
        let lower = text.lowercased()
        return phrases.contains(where: lower.contains) ? Rejection(reported: nil, required: nil) : nil
    }

    /// An update, unless a custom endpoint is in between and the installed version already meets the requirement.
    static func verdict(_ rejection: Rejection, installed: String?, endpointHost: String?) -> Verdict {
        if let host = endpointHost, let installed, let have = CLIVersion(installed),
           let needed = rejection.required.flatMap(CLIVersion.init), have >= needed {
            return .endpointRewrote(host: host, reported: rejection.reported ?? "?", installed: installed)
        }
        return .update(required: rejection.required)
    }

    // MARK: Custom endpoints

    /// The variables an agent reads its API endpoint from, and the hosts of its own API (not a custom endpoint).
    static func endpointVariables(_ provider: RunProvider) -> (names: [String], official: [String]) {
        switch provider {
        case .claude: return (["ANTHROPIC_BASE_URL"], ["api.anthropic.com"])
        case .codex: return (["OPENAI_BASE_URL"], ["api.openai.com", "chatgpt.com"])
        case .gemini: return (["GOOGLE_GEMINI_BASE_URL"], ["generativelanguage.googleapis.com"])
        // These pick their endpoint in their own config (or have none to pick): no variable says it.
        case .antigravity, .opencode, .cursor, .grok, .pi, .acp: return ([], [])
        }
    }

    /// The host of `baseURL` when it is an http(s) address other than the agent's own API.
    static func customHost(_ baseURL: String?, official: [String]) -> String? {
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty, !official.contains(host) else { return nil }
        return host
    }

    /// The custom endpoint an agent talks to: the first of `environments` (strongest first: the account's own variables,
    /// the agent's settings files, Nook's environment) that sets one of its variables decides.
    static func endpointHost(_ provider: RunProvider, environments: [[String: String]]) -> String? {
        let (names, official) = endpointVariables(provider)
        for environment in environments {
            for name in names {
                guard let value = environment[name], !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                return customHost(value, official: official)
            }
        }
        return nil
    }

    /// The `env` block of Claude Code's settings files, merged strongest first.
    static func settingsEnvironment(_ files: [URL]) -> [String: String] {
        var merged: [String: String] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = object["env"] as? [String: Any] else { continue }
            for (key, value) in env where merged[key] == nil {
                if let text = value as? String { merged[key] = text }
            }
        }
        return merged
    }
}
