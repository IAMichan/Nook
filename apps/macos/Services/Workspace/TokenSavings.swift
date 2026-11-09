import Foundation

// What Nook does so coding agents spend fewer tokens without losing quality. Foundation only, so the rules are tested
// on their own (`TokenSavingsTests`).
//
// - Idle compaction: a long conversation that sits idle is summarized shortly before the agent's prompt cache
//   expires. Afterwards the next message reads a short summary. Otherwise it would write the whole history to the
//   cache again at the full write price.
// - Tool search: Claude Code loads MCP tool schemas only when they are needed, also on models with a large window,
//   where its `auto` setting sends every schema with every request.
//
// Not used: Claude Code's `--exclude-dynamic-system-prompt-sections`. Measured on 2026-11-07 with Claude Code 2.1.318 in
// two worktrees of this repository, it wrote 7.4K tokens to the cache where the default wrote 6.6K: the version already
// keeps those parts out of the shared prompt.

/// How long the agent's prompt cache stays warm after its last request, as the agent reported it.
struct PromptCacheWindow: Codable, Equatable, Sendable {
    /// When the cache of the last request runs out.
    var expiresAt: Date
    /// The cache lifetime the agent reported (Claude: 1 hour on a subscription, 5 minutes on an API key).
    var ttl: TimeInterval
    /// The turn that set this window compacted the conversation (by hand, by Nook, or by the agent itself).
    var afterCompaction = false
}

enum PromptCache {
    /// The cache lifetime of a Claude request from its `usage.cache_creation`, or nil when it wrote nothing to the cache.
    /// A request served fully from the cache reports no lifetime but refreshes the cache with the lifetime it had.
    static func claudeTTL(_ usage: [String: Any]) -> TimeInterval? {
        guard let creation = usage["cache_creation"] as? [String: Any] else { return nil }
        func tokens(_ key: String) -> Double { (creation[key] as? NSNumber)?.doubleValue ?? 0 }
        if tokens("ephemeral_1h_input_tokens") > 0 { return 3_600 }
        if tokens("ephemeral_5m_input_tokens") > 0 { return 300 }
        return nil
    }
}

/// Settings › Sessions: an idle Claude session over `minimumContextTokens` is summarized (`/compact`) shortly before
/// its prompt cache expires, while its history is still cheap to read.
enum IdleCompaction {
    static let settingKey = "ws.idleCompaction"
    /// Below this a cold reread costs little, so summarizing mostly loses context for a small saving. It matches the
    /// threshold Claude Code itself uses before it offers to compact an old session.
    static let minimumContextTokens = 200_000
    /// How long before the cache expires the summary starts: enough to resume the session and send it while warm.
    static let lead: TimeInterval = 120

    /// What decides whether, and when, a session is summarized. Everything that holds it back is a reason to wait for you.
    struct Candidate: Equatable, Sendable {
        /// The agent reports how long its prompt cache lives (`ProviderCapabilities.reportsPromptCacheLifetime`).
        var agentReportsCacheLifetime: Bool
        var status: RunStatus
        var archived: Bool
        var settled: Bool
        var snoozedUntil: Date?
        var contextTokens: Int?
        var cache: PromptCacheWindow?
        /// Approvals or questions wait, messages are queued, background work will report into the next turn, or a
        /// handoff or rollback waits for your next message.
        var holdsForYou: Bool
        var isRemote: Bool
    }

    /// When to send the summary, or nil when this session should not get one.
    static func fireDate(_ candidate: Candidate, now: Date) -> Date? {
        guard candidate.agentReportsCacheLifetime, candidate.status == .completed, !candidate.archived, !candidate.settled,
              !candidate.holdsForYou, (candidate.contextTokens ?? 0) >= minimumContextTokens,
              let cache = candidate.cache, !cache.afterCompaction, cache.expiresAt > now else { return nil }
        if let snoozed = candidate.snoozedUntil, snoozed > now { return nil }
        // A session on another machine waits for you: its agent and its cache live there.
        if candidate.isRemote { return nil }
        // A short-lived cache (5 minutes) leaves little room; start at least halfway through it.
        let start = cache.expiresAt.addingTimeInterval(-min(lead, cache.ttl / 2))
        return max(start, now)
    }
}

/// Claude Code's `ENABLE_TOOL_SEARCH`. With `auto` (its default) it sends every MCP tool schema in full while they fit in a
/// share of the context window, which they do on 1M models: every request then carries them all, and t3code measured
/// about ten times the cache writes per session. Nook turns tool search on, unless you set something else yourself.
enum ClaudeToolSearch {
    /// The value Nook sets, or nil to leave yours: `auto` and `auto:N` (0 < N < 100) become `true`. `auto:0` already
    /// means on, `auto:100` off, and `true` or `false` are a choice of yours.
    static func override(userValue: String?) -> String? {
        guard let raw = userValue?.trimmingCharacters(in: .whitespaces) else { return "true" }
        if raw == "auto" { return "true" }
        guard raw.hasPrefix("auto:") else { return nil }
        // Claude Code treats an unreadable auto:N as auto.
        guard let percent = Int(raw.dropFirst("auto:".count).trimmingCharacters(in: .whitespaces)) else { return "true" }
        return percent > 0 && percent < 100 ? "true" : nil
    }

    /// The settings files Claude Code reads `env` from, strongest first: the project's local and shared settings, then
    /// the account's own (`CLAUDE_CONFIG_DIR`, else ~/.claude).
    static func settingsFiles(workingDirectory: String, configDirectory: String?) -> [URL] {
        let folder = URL(fileURLWithPath: workingDirectory, isDirectory: true).appendingPathComponent(".claude")
        let config = configDirectory.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return [folder.appendingPathComponent("settings.local.json"), folder.appendingPathComponent("settings.json"),
                config.appendingPathComponent("settings.json")]
    }

    /// The first `env.ENABLE_TOOL_SEARCH` in these files, or nil when none sets it.
    static func userValue(in files: [URL]) -> String? {
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = (object["env"] as? [String: Any])?["ENABLE_TOOL_SEARCH"] else { continue }
            if let text = value as? String { return text }
            if let flag = value as? Bool { return flag ? "true" : "false" }
        }
        return nil
    }
}
