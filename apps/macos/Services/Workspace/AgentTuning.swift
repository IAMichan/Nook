import Foundation

// Settings › Sessions › Tokens: what in your own setup of each coding agent goes with every request without being used,
// and the setting that turns it off. Nook only reads the agents' files; it changes none of them. Where Nook can, it applies
// a suggestion to the sessions it starts itself (Claude Code, through `--settings`); every suggestion also gives the
// exact setting for your own configuration. Foundation only, tested in `AgentTuningTests`.
//
// Measured on 2026-11-07 with Claude Code 2.1.318 on this project: five unused plugins took 5,345 tokens off every
// request, and leaving out unused claude.ai connectors took another 2,957.

/// One suggestion for one agent.
struct TuningAdvice: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable, CaseIterable {
        /// Plugins whose skills and agents are listed in every request, unused for `AgentTuning.unusedDays`.
        case unusedPlugins
        /// Cloud connectors (claude.ai) loaded into every session, none used.
        case cloudConnectors
        /// MCP servers whose tools load into every session, unused for `AgentTuning.unusedDays`.
        case unusedServers
        /// MCP servers whose tools load into every session; the agent keeps no record of their use.
        case servers
        /// A personal instruction file that goes with every session and has grown long.
        case longInstructions
        /// The agent no longer summarizes a full conversation by itself.
        case autoCompactOff
    }

    var provider: RunProvider
    var kind: Kind
    /// What the suggestion is about: plugin ids, server or connector names, a file.
    var items: [String]
    /// Of the same kind, the ones in use that stay (a connector you use).
    var kept: [String] = []
    /// Characters this adds to every request, when Nook can tell.
    var characters: Int? = nil
    /// Where the setting goes: a file, or a page.
    var location: String
    /// The setting to put there, ready to paste; nil when it is a step in the agent's own settings.
    var snippet: String? = nil
    /// Nook can apply it to the sessions it starts itself (`AgentTuning.Applied`).
    var appliesInNook = false

    var id: String { provider.rawValue + "." + kind.rawValue + "." + items.joined(separator: ",") }
    /// About this many tokens per request (four characters to a token).
    var tokens: Int? { characters.map { max(1, $0 / 4) } }
}

enum AgentTuning {
    /// Not used for this long counts as unused.
    static let unusedDays = 30
    /// A personal instruction file past this many characters is worth a look.
    static let longInstructions = 8_000

    // MARK: Applied in Nook

    /// Which suggestions you applied to the sessions Nook starts, with what they cover then.
    struct Applied: Codable, Equatable, Sendable {
        /// Claude Code plugins left out (`enabledPlugins` false).
        var claudePlugins: [String] = []
        /// Claude Code without claude.ai connectors (`disableClaudeAiConnectors`).
        var claudeNoConnectors = false

        static let key = "agents.tuning.applied"

        static func load(_ defaults: UserDefaults = .standard) -> Applied {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Applied.self, from: $0) } ?? Applied()
        }

        func save(_ defaults: UserDefaults = .standard) {
            defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
        }

        /// What Claude Code's `--settings` gets for it.
        var claudeSettings: [String: Any] {
            var settings: [String: Any] = [:]
            if !claudePlugins.isEmpty { settings["enabledPlugins"] = Dictionary(uniqueKeysWithValues: claudePlugins.map { ($0, false) }) }
            if claudeNoConnectors { settings["disableClaudeAiConnectors"] = true }
            return settings
        }

        func isApplied(_ advice: TuningAdvice) -> Bool {
            switch advice.kind {
            case .unusedPlugins: return !advice.items.isEmpty && Set(advice.items).isSubset(of: claudePlugins)
            case .cloudConnectors: return claudeNoConnectors
            case .unusedServers, .servers, .longInstructions, .autoCompactOff: return false
            }
        }

        mutating func set(_ advice: TuningAdvice, on: Bool) {
            switch advice.kind {
            case .unusedPlugins:
                claudePlugins.removeAll { advice.items.contains($0) }
                if on { claudePlugins += advice.items }
            case .cloudConnectors: claudeNoConnectors = on
            case .unusedServers, .servers, .longInstructions, .autoCompactOff: break
            }
        }
    }

    /// `advice` plus a row for what you applied and no suggestion covers any more, so it can be undone.
    static func withApplied(_ advice: [TuningAdvice], applied: Applied, settingsFile: String) -> [TuningAdvice] {
        var rows = advice
        let suggested = Set(advice.filter { $0.kind == .unusedPlugins }.flatMap(\.items))
        let leftover = applied.claudePlugins.filter { !suggested.contains($0) }
        if !leftover.isEmpty {
            rows.append(TuningAdvice(provider: .claude, kind: .unusedPlugins, items: leftover, location: settingsFile, appliesInNook: true))
        }
        if applied.claudeNoConnectors, !advice.contains(where: { $0.kind == .cloudConnectors && $0.appliesInNook }) {
            rows.removeAll { $0.kind == .cloudConnectors }
            rows.append(TuningAdvice(provider: .claude, kind: .cloudConnectors, items: [], location: settingsFile, appliesInNook: true))
        }
        return rows
    }

    // MARK: Reading the agents

    /// Every suggestion for the agents set up in this home folder, from their files and (for Claude Code) the tools its
    /// transcripts of the last `unusedDays` called. Slow on a big history (it reads those transcripts): run it off the
    /// main thread.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser, now: Date = Date()) -> [TuningAdvice] {
        var advice: [TuningAdvice] = []
        for provider in RunProvider.allCases {
            switch provider {
            case .claude: advice += claude(home: home, now: now)
            case .codex: advice += codex(home: home)
            case .gemini: advice += gemini(home: home)
            case .opencode: advice += opencode(home: home)
            case .cursor: advice += jsonServers(.cursor, file: home.appendingPathComponent(".cursor/mcp.json"))
            case .antigravity:
                advice += jsonServers(.antigravity, file: home.appendingPathComponent(".gemini/antigravity/mcp_config.json"))
            // Grok and the ACP agents you add keep no configuration file Nook knows (docs/INTEGRATIONS.md).
            case .grok, .pi, .acp: break
            }
        }
        return advice
    }

    // MARK: Claude Code

    static func claude(home: URL, now: Date) -> [TuningAdvice] {
        let state = json(home.appendingPathComponent(".claude.json")) ?? [:]
        let settingsFile = home.appendingPathComponent(".claude/settings.json")
        let settings = json(settingsFile) ?? [:]
        let since = now.addingTimeInterval(-Double(unusedDays) * 86_400)
        let usedServers = TranscriptToolUse.servers(in: home.appendingPathComponent(".claude/projects"), since: since)
        var advice: [TuningAdvice] = []

        // Plugins: the ones loaded now, minus those you used lately.
        let plugins = ClaudePlugins.loaded(home: home, settings: settings)
        let unused = plugins.filter {
            !ClaudePlugins.used($0.id, usage: state["pluginUsage"] as? [String: Any], skills: state["skillUsage"] as? [String: Any], since: since)
        }
        if !unused.isEmpty {
            let ids = unused.map(\.id).sorted()
            advice.append(TuningAdvice(provider: .claude, kind: .unusedPlugins, items: ids,
                                       characters: unused.reduce(0) { $0 + $1.characters }, location: settingsFile.path,
                                       snippet: jsonSnippet(["enabledPlugins": Dictionary(uniqueKeysWithValues: ids.map { ($0, false) })]),
                                       appliesInNook: true))
        }

        // claude.ai connectors: one switch for all of them, so only when none is used.
        let connectors = (state["claudeAiMcpEverConnected"] as? [String]) ?? []
        if !connectors.isEmpty, (settings["disableClaudeAiConnectors"] as? Bool) != true {
            let used = connectors.filter { usedServers[TranscriptToolUse.serverKey(connector: $0)] != nil }
            let idle = connectors.filter { !used.contains($0) }
            if !idle.isEmpty {
                advice.append(used.isEmpty
                    ? TuningAdvice(provider: .claude, kind: .cloudConnectors, items: idle, location: settingsFile.path,
                                   snippet: jsonSnippet(["disableClaudeAiConnectors": true]), appliesInNook: true)
                    : TuningAdvice(provider: .claude, kind: .cloudConnectors, items: idle, kept: used,
                                   location: "https://claude.ai/settings/connectors"))
            }
        }

        // Your own MCP servers for every project.
        let servers = ((state["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted()
        let idleServers = servers.filter { usedServers[$0] == nil }
        if !idleServers.isEmpty {
            advice.append(TuningAdvice(provider: .claude, kind: .unusedServers, items: idleServers,
                                       location: home.appendingPathComponent(".claude.json").path,
                                       snippet: idleServers.map { "claude mcp remove \($0) -s user" }.joined(separator: "\n")))
        }

        if (state["autoCompactEnabled"] as? Bool) == false {
            advice.append(TuningAdvice(provider: .claude, kind: .autoCompactOff, items: [],
                                       location: home.appendingPathComponent(".claude.json").path,
                                       snippet: jsonSnippet(["autoCompactEnabled": true])))
        }
        advice += instructions(.claude, file: home.appendingPathComponent(".claude/CLAUDE.md"))
        return advice
    }

    // MARK: Codex

    static func codex(home: URL) -> [TuningAdvice] {
        let file = home.appendingPathComponent(".codex/config.toml")
        var advice: [TuningAdvice] = []
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let on = CodexConfig.enabledServers(text)
            if !on.isEmpty {
                advice.append(TuningAdvice(provider: .codex, kind: .servers, items: on, location: file.path,
                                           snippet: CodexConfig.disableSnippet(on)))
            }
        }
        return advice + instructions(.codex, file: home.appendingPathComponent(".codex/AGENTS.md"))
    }

    // MARK: Gemini CLI

    static func gemini(home: URL) -> [TuningAdvice] {
        let file = home.appendingPathComponent(".gemini/settings.json")
        var advice: [TuningAdvice] = []
        if let settings = json(file) {
            let excluded = Set(((settings["mcp"] as? [String: Any])?["excluded"] as? [String]) ?? [])
            let on = ((settings["mcpServers"] as? [String: Any]) ?? [:]).keys.filter { !excluded.contains($0) }.sorted()
            if !on.isEmpty {
                advice.append(TuningAdvice(provider: .gemini, kind: .servers, items: on, location: file.path,
                                           snippet: jsonSnippet(["mcp": ["excluded": excluded.sorted() + on]])))
            }
        }
        return advice + instructions(.gemini, file: home.appendingPathComponent(".gemini/GEMINI.md"))
    }

    // MARK: OpenCode

    static func opencode(home: URL) -> [TuningAdvice] {
        let folder = home.appendingPathComponent(".config/opencode")
        var advice: [TuningAdvice] = []
        for name in ["opencode.json", "opencode.jsonc"] {
            let file = folder.appendingPathComponent(name)
            guard let text = try? String(contentsOf: file, encoding: .utf8), let config = jsonObject(JSONC.strip(text)) else { continue }
            let servers = (config["mcp"] as? [String: Any]) ?? [:]
            let on = servers.filter { (($0.value as? [String: Any])?["enabled"] as? Bool) != false }.keys.sorted()
            if !on.isEmpty {
                advice.append(TuningAdvice(provider: .opencode, kind: .servers, items: on, location: file.path,
                                           snippet: jsonSnippet(["mcp": Dictionary(uniqueKeysWithValues: on.map { ($0, ["enabled": false]) })])))
            }
            break
        }
        return advice + instructions(.opencode, file: folder.appendingPathComponent("AGENTS.md"))
    }

    // MARK: Shared

    /// MCP servers in an `mcpServers` file that the agent turns off in its own settings (Cursor, Antigravity).
    static func jsonServers(_ provider: RunProvider, file: URL) -> [TuningAdvice] {
        let on = ((json(file)?["mcpServers"] as? [String: Any]) ?? [:]).filter {
            (($0.value as? [String: Any])?["disabled"] as? Bool) != true
        }.keys.sorted()
        return on.isEmpty ? [] : [TuningAdvice(provider: provider, kind: .servers, items: on, location: file.path)]
    }

    static func instructions(_ provider: RunProvider, file: URL) -> [TuningAdvice] {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.count > longInstructions else { return [] }
        return [TuningAdvice(provider: provider, kind: .longInstructions, items: [file.path], characters: text.count,
                             location: file.path)]
    }

    static func json(_ file: URL) -> [String: Any]? {
        (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func jsonSnippet(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Claude Code plugins

enum ClaudePlugins {
    struct Plugin: Equatable, Sendable {
        /// `name@marketplace`, as `enabledPlugins` and `pluginUsage` name it (`@inline` for plugins synced from claude.ai).
        var id: String
        /// What its skills and agents add to the listings in every request.
        var characters: Int
    }

    /// The plugins Claude Code loads: those synced from your claude.ai account, and those you installed and left on.
    static func loaded(home: URL, settings: [String: Any]) -> [Plugin] {
        let pluginsFolder = home.appendingPathComponent(".claude/plugins")
        let enabled = (settings["enabledPlugins"] as? [String: Any]) ?? [:]
        var plugins: [Plugin] = []
        // Synced: ~/.claude/plugins/synced/<account>/<name or name~variant>/, listed in its manifest.json.
        let synced = pluginsFolder.appendingPathComponent("synced")
        for account in (try? FileManager.default.contentsOfDirectory(at: synced, includingPropertiesForKeys: nil)) ?? []
        where !account.lastPathComponent.hasPrefix(".") {
            let names = ((AgentTuning.json(account.appendingPathComponent("manifest.json"))?["plugins"] as? [[String: Any]]) ?? [])
                .compactMap { $0["name"] as? String }
            let folders = (try? FileManager.default.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? []
            for name in names {
                let id = name + "@inline"
                guard (enabled[id] as? Bool) != false,
                      let folder = folders.first(where: { $0.lastPathComponent == name || $0.lastPathComponent.hasPrefix(name + "~") })
                else { continue }
                plugins.append(Plugin(id: id, characters: listingCharacters(folder, plugin: name)))
            }
        }
        // Installed from a marketplace: on only when `enabledPlugins` says so.
        let installed = (AgentTuning.json(pluginsFolder.appendingPathComponent("installed_plugins.json"))?["plugins"] as? [String: Any]) ?? [:]
        for (id, entries) in installed where (enabled[id] as? Bool) == true {
            guard let path = (entries as? [[String: Any]])?.first?["installPath"] as? String else { continue }
            let name = String(id.prefix { $0 != "@" })
            plugins.append(Plugin(id: id, characters: listingCharacters(URL(fileURLWithPath: path), plugin: name)))
        }
        // One plugin can be synced through more than one account folder: count it once.
        var seen = Set<String>()
        return plugins.sorted { $0.id < $1.id }.filter { seen.insert($0.id).inserted }
    }

    /// Used within the period: the plugin itself (`pluginUsage`, also its synced twin) or one of its skills (`skillUsage`).
    static func used(_ id: String, usage: [String: Any]?, skills: [String: Any]?, since: Date) -> Bool {
        let name = String(id.prefix { $0 != "@" })
        func recent(_ entry: Any?) -> Bool {
            guard let entry = entry as? [String: Any], ((entry["usageCount"] as? NSNumber)?.intValue ?? 0) > 0,
                  let last = (entry["lastUsedAt"] as? NSNumber)?.doubleValue else { return false }
            return Date(timeIntervalSince1970: last / 1000) >= since
        }
        for (key, entry) in usage ?? [:] where key == id || key == name + "@synced" || key == name + "@inline" {
            if recent(entry) { return true }
        }
        for (key, entry) in skills ?? [:] where key == name || key.hasPrefix(name + ":") {
            if recent(entry) { return true }
        }
        return false
    }

    /// The lines its skills and agents add to Claude Code's listings: `- plugin:name: description`.
    static func listingCharacters(_ folder: URL, plugin: String) -> Int {
        var total = 0
        for (sub, file) in [("skills", "SKILL.md"), ("agents", nil)] as [(String, String?)] {
            let base = folder.appendingPathComponent(sub)
            for entry in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] {
                let url = file.map { entry.appendingPathComponent($0) } ?? entry
                guard url.pathExtension == "md", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let front = Frontmatter.fields(text)
                total += plugin.count + (front["name"]?.count ?? 0) + (front["description"]?.count ?? 0) + 6
            }
        }
        return total
    }
}

/// The `key: value` lines between a Markdown file's opening `---` lines.
enum Frontmatter {
    static func fields(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[String(line[..<colon])] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return fields
    }
}

// MARK: - Tool use in transcripts

/// Which MCP servers Claude Code actually called, from its transcripts (`~/.claude/projects/*/*.jsonl`). Only a tool
/// call counts (`"type":"tool_use"`), not the tool lists every request carries.
enum TranscriptToolUse {
    private static let callStart = Array(#""type":"tool_use","id":""#.utf8)
    private static let nameStart = Array(#"","name":"mcp__"#.utf8)

    /// Calls per server in these bytes: each `"type":"tool_use","id":"…","name":"mcp__SERVER__tool"`. A byte search, not a
    /// regular expression: a month of transcripts is easily a gigabyte.
    static func servers(in data: Data) -> [String: Int] {
        var counts: [String: Int] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            var offset = 0
            while offset < count, let hit = find(callStart, in: base, from: offset, count: count) {
                var at = hit + callStart.count
                // The id: up to its closing quote.
                while at < count, raw[at] != UInt8(ascii: "\"") { at += 1 }
                offset = at
                guard at + nameStart.count <= count,
                      memcmp(base + at, nameStart, nameStart.count) == 0 else { continue }
                at += nameStart.count
                let start = at
                // The server name ends at the next "__".
                while at + 1 < count, !(raw[at] == UInt8(ascii: "_") && raw[at + 1] == UInt8(ascii: "_")), raw[at] != UInt8(ascii: "\""), at - start < 200 {
                    at += 1
                }
                if at + 1 < count, raw[at] == UInt8(ascii: "_"), at > start {
                    counts[String(decoding: raw[start..<at], as: UTF8.self), default: 0] += 1
                }
                offset = at
            }
        }
        return counts
    }

    static func servers(in text: String) -> [String: Int] { servers(in: Data(text.utf8)) }

    /// Where `pattern` starts at or after `from`. memmem where the C library has it (macOS); elsewhere Foundation's search.
    private static func find(_ pattern: [UInt8], in base: UnsafeRawPointer, from: Int, count: Int) -> Int? {
        guard from + pattern.count <= count else { return nil }
        #if canImport(Darwin)
        guard let hit = memmem(base + from, count - from, pattern, pattern.count) else { return nil }
        return UnsafeRawPointer(hit) - base
        #else
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), count: count, deallocator: .none)
        return data.range(of: Data(pattern), in: from..<count)?.lowerBound
        #endif
    }

    /// Calls per server in the transcripts changed since `since`.
    static func servers(in projects: URL, since: Date) -> [String: Int] {
        var counts: [String: Int] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: projects, includingPropertiesForKeys: keys) else { return counts }
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate, modified >= since,
                  let data = try? Data(contentsOf: file, options: .alwaysMapped) else { continue }
            for (name, count) in servers(in: data) { counts[name, default: 0] += count }
        }
        return counts
    }

    /// The server key in tool names for a claude.ai connector: "claude.ai Google Drive" → "claude_ai_Google_Drive".
    static func serverKey(connector: String) -> String {
        connector.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: " ", with: "_")
    }
}

// MARK: - Codex and JSONC

enum CodexConfig {
    /// The `[mcp_servers.NAME]` tables of a config.toml that do not say `enabled = false`.
    static func enabledServers(_ toml: String) -> [String] {
        var servers: [(name: String, enabled: Bool)] = []
        for raw in toml.split(separator: "\n") {
            let line = withoutComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let header = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t"))
                if header.hasPrefix("mcp_servers."), let name = name(String(header.dropFirst("mcp_servers.".count))) {
                    servers.append((name, true))
                } else {
                    servers.append(("", false))
                }
            } else if let last = servers.last, !last.name.isEmpty,
                      line.filter({ !$0.isWhitespace }) == "enabled=false" {
                servers[servers.count - 1].enabled = false
            }
        }
        var seen = Set<String>()
        return servers.filter { !$0.name.isEmpty && $0.enabled && seen.insert($0.name).inserted }.map(\.name).sorted()
    }

    /// The server's name from the rest of its header; nil for a subtable (`[mcp_servers.x.env]`).
    private static func name(_ rest: String) -> String? {
        if rest.hasPrefix("\"") {
            guard let end = rest.dropFirst().firstIndex(of: "\"") else { return nil }
            let after = rest[rest.index(after: end)...]
            return after.isEmpty ? String(rest[rest.index(after: rest.startIndex)..<end]) : nil
        }
        return rest.contains(".") ? nil : rest
    }

    /// A table key: bare when TOML allows it (ASCII letters, digits, `_` and `-`), quoted otherwise.
    static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        return bare ? name : BridgeLaunch.toml(name)
    }

    /// What to add to each server's existing table. A table named twice makes the whole file invalid, so this says where
    /// the line goes instead of repeating the header.
    static func disableSnippet(_ servers: [String]) -> String {
        servers.map { "# In the existing [mcp_servers.\(key($0))] table, add:\nenabled = false" }.joined(separator: "\n\n")
    }

    /// The line without a `#` comment (a `#` inside a quoted string stays).
    static func withoutComment(_ line: String) -> String {
        var inString = false
        for (index, char) in zip(line.indices, line) {
            if char == "\"" { inString.toggle() }
            if char == "#", !inString { return String(line[..<index]) }
        }
        return line
    }
}

/// JSON with comments (OpenCode's opencode.jsonc): comments and trailing commas out, strings left alone.
enum JSONC {
    static func strip(_ text: String) -> String {
        var out = ""
        var chars = Array(text)
        var i = 0
        var inString = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
                if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        chars.removeAll()
        return out
    }
}
