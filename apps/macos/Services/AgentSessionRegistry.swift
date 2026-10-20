import Foundation

/// One agent conversation as Nook sees it, whichever way it learned about it.
///
/// Four sources know about agent sessions: hooks (live status and approvals), the process list (running, not linked),
/// transcripts (finished conversations) and the sessions Nook runs itself. They used to be four separate lists, so one
/// conversation could appear twice and two processes in one folder collapsed into one row. `AgentSessionRegistry.merge`
/// turns them into one list in which every conversation appears once.
struct AgentSessionRecord: Identifiable, Equatable {
    /// Richer sources win when the same conversation is known from several.
    enum Source: Int, Comparable {
        case transcript = 0, process, hook, nook
        static func < (a: Source, b: Source) -> Bool { a.rawValue < b.rawValue }
    }

    enum Phase: Equatable {
        /// Waiting for an answer or an approval from the user.
        case needsYou
        case working
        case idle
        case failed
        case finished
    }

    /// Where the row belongs in the list.
    enum Section: Int {
        case needsYou = 0, active, inNook, earlier
    }

    var id: String
    var sources: Set<Source>
    /// The agent's name as the rest of the app uses it ("Claude Code", "Codex").
    var agent: String
    /// The account directory (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`); empty for the default account.
    var accountHome: String
    /// The agent's own conversation id; empty when only a process is known.
    var conversationID: String
    var pid: Int32?
    var cwd: String
    var title: String
    var phase: Phase
    var updated: Date

    var leading: Source { sources.max() ?? .transcript }
    /// Is the conversation going on right now (as opposed to a record of one that ended)?
    var isLive: Bool {
        sources.contains(.hook) || sources.contains(.process) || (sources.contains(.nook) && phase != .finished)
    }

    var section: Section {
        if phase == .needsYou || phase == .failed && isLive { return .needsYou }
        if isLive && phase == .working { return .active }
        if sources.contains(.nook) && phase != .finished { return .inNook }
        if isLive { return .active }
        return .earlier
    }

    /// The key two records share when they are the same conversation.
    var conversationKey: String? {
        conversationID.isEmpty ? nil : "\(agent)|\(accountHome)|\(conversationID)"
    }
}

enum AgentSessionRegistry {
    /// Every conversation once. Records with the same conversation are folded together (the richest source leads, the
    /// others only add what it lacks); process-only rows stay unless a hooked or Nook-run session already covers them,
    /// and then only as many as it covers, so two processes in one folder remain two rows.
    static func merge(_ records: [AgentSessionRecord]) -> [AgentSessionRecord] {
        var byConversation: [String: AgentSessionRecord] = [:]
        var order: [String] = []
        var processes: [AgentSessionRecord] = []
        for record in records {
            if let key = record.conversationKey {
                if let existing = byConversation[key] {
                    byConversation[key] = fold(existing, record)
                } else {
                    byConversation[key] = record
                    order.append(key)
                }
            } else if record.sources == [.process] {
                processes.append(record)
            } else {
                // Known only by id (a hook that sent no conversation id): keep it as its own row.
                byConversation[record.id] = record
                order.append(record.id)
            }
        }
        let merged = order.compactMap { byConversation[$0] }

        // A process is already shown when a live hooked/Nook session works in the same folder with the same agent:
        // each such session covers one process.
        var covered: [String: Int] = [:]
        for record in merged where record.isLive && (record.sources.contains(.hook) || record.sources.contains(.nook)) {
            covered["\(record.agent)|\(record.cwd)", default: 0] += 1
        }
        var remaining: [AgentSessionRecord] = []
        for process in processes.sorted(by: { ($0.pid ?? 0) < ($1.pid ?? 0) }) {
            let key = "\(process.agent)|\(process.cwd)"
            if let count = covered[key], count > 0 {
                covered[key] = count - 1
            } else {
                remaining.append(process)
            }
        }
        return (merged + remaining).sorted { a, b in
            if a.section != b.section { return a.section.rawValue < b.section.rawValue }
            return a.updated > b.updated
        }
    }

    private static func fold(_ a: AgentSessionRecord, _ b: AgentSessionRecord) -> AgentSessionRecord {
        let (lead, other) = a.leading >= b.leading ? (a, b) : (b, a)
        var result = lead
        result.sources = a.sources.union(b.sources)
        if result.title.isEmpty { result.title = other.title }
        if result.cwd.isEmpty { result.cwd = other.cwd }
        if result.pid == nil { result.pid = other.pid }
        result.updated = max(a.updated, b.updated)
        return result
    }
}

/// Reading the environment of a process from `ps -E` output.
enum AgentProcessEnvironment {
    /// The value of `name=` in a `ps -E` line. The value may contain spaces ("/Users/x/My Projects/.claude"):
    /// it runs up to the next `SOME_NAME=` or the end of the line.
    static func value(of name: String, in line: String) -> String? {
        let pattern = "(^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "="
        guard let marker = line.range(of: pattern, options: .regularExpression) else { return nil }
        let rest = line[marker.upperBound...]
        var end = rest.endIndex
        if let next = rest.range(of: #"\s[A-Z][A-Z0-9_]*="#, options: .regularExpression) { end = next.lowerBound }
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Processes Nook started itself (headless sessions, the Claude Code brain) carry these in their environment.
    /// They are not other people's sessions and must not be listed, or ended.
    static func isNookOwned(_ line: String) -> Bool {
        value(of: "NOOK_RUN_ID", in: line) != nil || value(of: "NOOK_INTERNAL", in: line) != nil
    }
}
