import Foundation

/// Connects Nook to your agents by updating their configuration file, but only after your confirmation:
/// Nook reads the file, displays an exact diff of the changes, creates a timestamped backup,
/// and only writes if the file has not changed since the preview. Existing settings are preserved.
enum AgentConfigInstaller {
    enum Target: String, CaseIterable, Identifiable {
        case claudeHooks, claudeStatusLine, codex, gemini, antigravity, cursor, copilot, muse, openCode, amp, hermes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeHooks: return "Claude Code"
            case .claudeStatusLine: return "Claude subscription in the notch"
            case .codex: return "Codex"
            case .gemini: return "Gemini CLI"
            case .antigravity: return "Antigravity"
            case .cursor: return "Cursor"
            case .copilot: return "Copilot CLI"
            case .muse: return "Muse Code"
            case .openCode: return "OpenCode"
            case .amp: return "Amp"
            case .hermes: return "Hermes"
            }
        }

        var detail: String {
            switch self {
            case .claudeHooks: return "Progress, permissions, and prompts in the notch"
            case .claudeStatusLine: return "Your 5-hour and weekly limits (Pro/Max), via the status line"
            case .codex: return "Progress and permissions in the notch"
            case .gemini, .antigravity, .cursor, .copilot, .muse: return "Progress in the notch"
            case .openCode, .amp: return "Progress in the notch, via a small plugin"
            case .hermes: return "Progress in the notch, via a plugin. Enable it afterwards with: hermes plugins enable nook"
            }
        }

        /// The (primary) file modified or created by Nook.
        var fileURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeHooks, .claudeStatusLine: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            case .gemini: return home.appendingPathComponent(".gemini/settings.json")
            case .antigravity: return home.appendingPathComponent(".gemini/config/hooks.json")
            case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
            case .copilot: return home.appendingPathComponent(".copilot/hooks/nook.json")
            case .muse: return home.appendingPathComponent(".config/muse/settings.json")
            case .openCode: return home.appendingPathComponent(".config/opencode/plugins/nook.js")
            case .amp: return home.appendingPathComponent(".config/amp/plugins/nook.ts")
            case .hermes: return home.appendingPathComponent(".hermes/plugins/nook/__init__.py")
            }
        }

        /// The file for an account with a custom directory (CLAUDE_CONFIG_DIR, CODEX_HOME). Nil: the default directory.
        func fileURL(home: URL?) -> URL {
            guard let home else { return fileURL }
            switch self {
            case .claudeHooks, .claudeStatusLine: return home.appendingPathComponent("settings.json")
            case .codex: return home.appendingPathComponent("hooks.json")
            default: return fileURL
            }
        }

        var displayPath: String {
            switch self {
            case .claudeHooks, .claudeStatusLine: return "~/.claude/settings.json"
            case .codex: return "~/.codex/hooks.json"
            case .gemini: return "~/.gemini/settings.json"
            case .antigravity: return "~/.gemini/config/hooks.json"
            case .cursor: return "~/.cursor/hooks.json"
            case .copilot: return "~/.copilot/hooks/nook.json"
            case .muse: return "~/.config/muse/settings.json"
            case .openCode: return "~/.config/opencode/plugins/nook.js"
            case .amp: return "~/.config/amp/plugins/nook.ts"
            case .hermes: return "~/.hermes/plugins/nook/"
            }
        }

        /// Configuration target for an agent as Nook detects it running on your Mac ("Claude Code", "Codex"...).
        static func forAgent(named name: String) -> Target? {
            switch name {
            case "Claude Code": return .claudeHooks
            case "Codex": return .codex
            case "Gemini CLI": return .gemini
            case "Antigravity": return .antigravity
            case "Cursor": return .cursor
            case "Copilot CLI": return .copilot
            case "Muse Code": return .muse
            case "OpenCode": return .openCode
            case "Amp": return .amp
            case "Hermes": return .hermes
            default: return nil
            }
        }

        /// Agents that load a dedicated Nook plugin file, rather than hook commands in their JSON.
        var isPlugin: Bool {
            switch self {
            case .openCode, .amp, .hermes: return true
            default: return false
            }
        }

        /// Plugin files and their contents; empty for agents with JSON settings.
        var pluginFiles: [(url: URL, contents: String)] {
            switch self {
            case .openCode: return [(url: fileURL, contents: AgentPlugins.openCode)]
            case .amp: return [(url: fileURL, contents: AgentPlugins.amp)]
            case .hermes:
                let manifest = fileURL.deletingLastPathComponent().appendingPathComponent("plugin.yaml")
                return [(url: fileURL, contents: AgentPlugins.hermesInit),
                        (url: manifest, contents: AgentPlugins.hermesManifest)]
            default: return []
            }
        }
    }

    enum State: Equatable {
        case notInstalled
        case installed
        /// Connected with an older version of Nook: updating grants permission via PermissionRequest and prompts.
        case outdated
        case unreadable(String)
    }

    /// A single file in a change. `updated == nil` means: the file is removed
    /// (only for files owned entirely by Nook, such as plugins).
    struct FileChange {
        let url: URL
        let original: Data?
        let updated: Data?
    }

    /// A proposed change. Only `apply` writes it to disk.
    struct Change: Identifiable {
        let id = UUID()
        let target: Target
        let install: Bool
        /// The first file is `target.fileURL`; a plugin may have multiple (Hermes: plugin.yaml).
        let files: [FileChange]
        let preview: [DiffLine]
        /// Saved state to preserve or discard for the status line.
        let previousStatusLine: Data?
        let removePreviousStatusLine: Bool

        var original: Data? { files.first?.original }
        var updated: Data? { files.first?.updated }
    }

    private static let marker = "nook-hook"
    /// Name of Nook's dedicated group in ~/.gemini/config/hooks.json (Antigravity).
    private static let antigravityGroup = "nook"
    static let previousStatusLineURL = NookPaths.supportDirectory.appendingPathComponent("statusline-previous.json")

    // MARK: State

    /// `home`: directory of a secondary account; nil for the default agent directory.
    static func state(of target: Target, home: URL? = nil) -> State {
        if target.isPlugin { return pluginState(target) }
        let root: [String: Any]
        do {
            root = try read(target.fileURL(home: home)).object
        } catch {
            return .unreadable(error.localizedDescription)
        }
        switch target {
        case .claudeStatusLine:
            let command = (root["statusLine"] as? [String: Any])?["command"] as? String ?? ""
            return command.contains(marker) ? .installed : .notInstalled
        case .antigravity:
            guard let block = root[antigravityGroup] else { return .notInstalled }
            return containsMarker(block) ? .installed : .notInstalled
        case .claudeHooks, .codex, .gemini, .cursor, .copilot, .muse:
            let hooks = (root["hooks"] as? [String: Any]) ?? [:]
            let ours = hooks.filter { _, value in containsMarker(value) }
            if ours.isEmpty { return .notInstalled }
            if target == .claudeHooks {
                let current = hooks["PermissionRequest"].map(containsMarker) ?? false
                let asks = (hooks["PreToolUse"] as? [[String: Any]])?.contains {
                    ($0["matcher"] as? String) == "AskUserQuestion" && containsMarker($0)
                } ?? false
                return current && asks ? .installed : .outdated
            }
            return .installed
        case .openCode, .amp, .hermes:
            return pluginState(target)
        }
    }

    /// A plugin is installed when all its files exist and originate from Nook.
    private static func pluginState(_ target: Target) -> State {
        var present = 0
        let files = target.pluginFiles
        for file in files {
            do {
                if try readPlugin(file.url) != nil { present += 1 }
            } catch {
                return .unreadable(error.localizedDescription)
            }
        }
        return present == files.count && present > 0 ? .installed : .notInstalled
    }

    // MARK: Preparing Changes

    static func prepare(_ target: Target, install: Bool, home: URL? = nil) throws -> Change {
        _ = try? HookScript.install()
        if target.isPlugin { return try preparePlugin(target, install: install) }
        let fileURL = target.fileURL(home: home)
        let snapshot = try read(fileURL)
        var root = snapshot.object
        var previous: Data?
        var removePrevious = false
        // Only for files wholly owned by Nook: deleted after disconnecting.
        var removeFile = false

        switch target {
        case .claudeHooks:
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                let plain = HookScript.command("--agent claude-code")
                for event in ["SessionStart", "SessionEnd", "UserPromptSubmit", "PostToolUse", "PostToolUseFailure",
                              "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop"] {
                    try append(&hooks, event: event, group: group(plain, timeout: 5))
                }
                try append(&hooks, event: "PreToolUse", group: group(plain, timeout: 5))
                try append(&hooks, event: "PreToolUse",
                           group: group(HookScript.command("--agent claude-code --ask"), matcher: "AskUserQuestion", timeout: 130))
                try append(&hooks, event: "PermissionRequest",
                           group: group(HookScript.command("--agent claude-code --wait"), timeout: 120))
            }
            set(&root, "hooks", hooks)

        case .codex:
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                let plain = HookScript.command("--agent codex")
                for (event, timeout) in [("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5),
                                         ("PostToolUse", 5), ("Stop", 5), ("SessionEnd", 3)] {
                    try append(&hooks, event: event, group: group(plain, timeout: timeout))
                }
                var waiting = group(HookScript.command("--agent codex --wait"), timeout: 120)
                if var inner = waiting["hooks"] as? [[String: Any]], !inner.isEmpty {
                    inner[0]["statusMessage"] = "Waiting for your response in the notch (Nook)"
                    waiting["hooks"] = inner
                }
                try append(&hooks, event: "PermissionRequest", group: waiting)
            }
            set(&root, "hooks", hooks)

        case .gemini:
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                // Gemini uses proprietary names and millisecond timeouts; Nook receives canonical names.
                for (event, name, timeout) in [("SessionStart", "SessionStart", 10_000), ("SessionEnd", "SessionEnd", 10_000),
                                               ("BeforeTool", "PreToolUse", 5_000), ("AfterTool", "PostToolUse", 5_000),
                                               ("BeforeAgent", "UserPromptSubmit", 5_000), ("AfterAgent", "Stop", 5_000)] {
                    try append(&hooks, event: event,
                               group: group(HookScript.command("--agent gemini \(name)"), matcher: "*", timeout: timeout))
                }
            }
            set(&root, "hooks", hooks)

        case .antigravity:
            // Antigravity (agy) defines top-level named groups; Nook's group is named "nook".
            // Tools receive a matcher group, others a plain handler; timeouts in seconds.
            if let existing = root[antigravityGroup], !containsMarker(existing) {
                throw NookError("\(target.displayPath) already has a group \"\(antigravityGroup)\" that does not belong to Nook. Nook made no changes.")
            }
            root.removeValue(forKey: antigravityGroup)
            if install {
                var block: [String: Any] = [:]
                for event in ["PreToolUse", "PostToolUse"] {
                    block[event] = [group(HookScript.command("--agent antigravity \(event)"), matcher: "*", timeout: 10)]
                }
                for event in ["PreInvocation", "PostInvocation", "Stop"] {
                    block[event] = [handler(HookScript.command("--agent antigravity \(event)"), timeout: 10)]
                }
                root[antigravityGroup] = block
            }

        case .cursor:
            // {"version": 1, "hooks": {"stop": [{"command": ...}]}}: Cursor includes the event name in the JSON
            // and never awaits a response, so Nook makes no decisions for Cursor.
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                for event in ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse",
                              "postToolUseFailure", "subagentStart", "subagentStop", "stop"] {
                    try append(&hooks, event: event, group: ["command": HookScript.command("--agent cursor \(event)")])
                }
                if root["version"] == nil { root["version"] = 1 }
            }
            set(&root, "hooks", hooks)

        case .copilot:
            // Dedicated file in Copilot's hooks directory: camelCase names, {"bash": ..., "timeoutSec": N}.
            // Copilot omits the event name from JSON, so it is passed on the command line.
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                for (event, timeout) in [("sessionStart", 10), ("userPromptSubmitted", 10), ("preToolUse", 10),
                                         ("postToolUse", 10), ("agentStop", 10), ("sessionEnd", 3), ("notification", 10)] {
                    let entry: [String: Any] = ["type": "command",
                                                "bash": HookScript.command("--agent copilot \(event)"),
                                                "timeoutSec": timeout]
                    try append(&hooks, event: event, group: entry)
                }
                root["version"] = 1
            }
            set(&root, "hooks", hooks)
            // If no third-party configuration remains after uninstalling, the file was Nook-owned and is removed.
            if !install, root.keys.allSatisfy({ $0 == "version" }) { removeFile = true }

        case .muse:
            // Similar to Claude Code, but using a matcher and millisecond timeouts.
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                for (event, seconds) in [("SessionStart", 10), ("UserPromptSubmit", 5), ("PreToolUse", 5),
                                         ("PostToolUse", 5), ("Stop", 5), ("SessionEnd", 3)] {
                    try append(&hooks, event: event,
                               group: group(HookScript.command("--agent muse \(event)"), matcher: "*", timeout: seconds * 1_000))
                }
                if snapshot.original == nil { root["schema_version"] = 1 }
            }
            set(&root, "hooks", hooks)

        case .claudeStatusLine:
            let current = root["statusLine"] as? [String: Any]
            let currentCommand = current?["command"] as? String ?? ""
            let ours = currentCommand.contains(marker)
            if install {
                var line = current ?? ["type": "command"]
                if let current, !ours, home == nil {
                    // The existing statusline remains visible: Nook invokes it directly.
                    previous = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
                }
                line["type"] = "command"
                line["command"] = HookScript.command("--statusline")
                root["statusLine"] = line
            } else if ours {
                if let saved = try? Data(contentsOf: previousStatusLineURL),
                   let object = (try? JSONSerialization.jsonObject(with: saved)) as? [String: Any] {
                    root["statusLine"] = object
                } else {
                    root.removeValue(forKey: "statusLine")
                }
                removePrevious = true
            }

        case .openCode, .amp, .hermes:
            return try preparePlugin(target, install: install)
        }

        var updated: Data?
        if !removeFile {
            updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
        let before = try snapshot.original.map { _ in
            try JSONSerialization.data(withJSONObject: snapshot.object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } ?? Data()
        let ops = LineDiff.diff(
            LineDiff.lines(String(decoding: before, as: UTF8.self)),
            LineDiff.lines(String(decoding: updated ?? Data(), as: UTF8.self))
        )
        // Non-existent file that does not need to be created: nothing to do.
        let files: [FileChange] = snapshot.original == nil && updated == nil
            ? []
            : [FileChange(url: fileURL, original: snapshot.original, updated: updated)]
        return Change(
            target: target,
            install: install,
            files: files,
            preview: LineDiff.display(ops, context: 2, limit: 400, width: 200),
            previousStatusLine: previous,
            removePreviousStatusLine: removePrevious
        )
    }

    /// A plugin is Nook's own file: linking writes (or rewrites) it, unlinking removes it.
    /// A file with the same name that does not belong to Nook is never touched.
    private static func preparePlugin(_ target: Target, install: Bool) throws -> Change {
        var files: [FileChange] = []
        var preview: [DiffLine] = []
        let several = target.pluginFiles.count > 1
        for file in target.pluginFiles {
            let original = try readPlugin(file.url)
            let updated: Data? = install ? Data(file.contents.utf8) : nil
            if original == nil && updated == nil { continue }
            files.append(FileChange(url: file.url, original: original, updated: updated))
            let ops = LineDiff.diff(
                LineDiff.lines(String(decoding: original ?? Data(), as: UTF8.self)),
                LineDiff.lines(String(decoding: updated ?? Data(), as: UTF8.self))
            )
            if several {
                preview.append(DiffLine(kind: .context, text: "── \(file.url.lastPathComponent)"))
            }
            preview += LineDiff.display(ops, context: 2, limit: 400, width: 200)
        }
        return Change(
            target: target,
            install: install,
            files: files,
            preview: preview,
            previousStatusLine: nil,
            removePreviousStatusLine: false
        )
    }

    // MARK: Applying Changes

    /// Writes the change after creating a backup. If a file changed since the preview, nothing is written.
    @discardableResult
    static func apply(_ change: Change) throws -> URL? {
        let fm = FileManager.default
        for file in change.files {
            let current = fm.fileExists(atPath: file.url.path) ? try? Data(contentsOf: file.url) : nil
            guard current == file.original else {
                throw NookError("\(change.target.displayPath) has changed since the preview. Nothing was written; please review again.")
            }
        }

        // Content that remains unchanged does not need a backup and is not rewritten.
        let pending = change.files.filter { $0.original != $0.updated }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var backup: URL?
        for file in pending where file.original != nil {
            let backupURL = file.url.deletingLastPathComponent()
                .appendingPathComponent("\(file.url.lastPathComponent).nook-backup-\(stamp)")
            do {
                try fm.copyItem(at: file.url, to: backupURL)
            } catch {
                throw NookError("Could not create a backup of \(change.target.displayPath). Nothing was written.")
            }
            if backup == nil { backup = backupURL }
        }

        for file in pending {
            do {
                if let data = file.updated {
                    try fm.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: file.url, options: .atomic)
                } else if fm.fileExists(atPath: file.url.path) {
                    try fm.removeItem(at: file.url)
                }
            } catch {
                throw NookError("Could not write \(change.target.displayPath): \(error.localizedDescription). The backup is located next to it.")
            }
        }

        if let previous = change.previousStatusLine {
            try? previous.write(to: previousStatusLineURL, options: .atomic)
        }
        if change.removePreviousStatusLine {
            try? fm.removeItem(at: previousStatusLineURL)
        }
        return backup
    }

    // MARK: Helper Functions

    private struct Snapshot {
        var object: [String: Any]
        var original: Data?
    }

    /// A missing file counts as empty; an unreadable or invalid file never does.
    private static func read(_ url: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot(object: [:], original: nil) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NookError("\(url.path) cannot be read. Nook did not touch anything.")
        }
        if data.allSatisfy({ $0 == 32 || $0 == 10 || $0 == 13 || $0 == 9 }) {
            return Snapshot(object: [:], original: data)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NookError("\(url.path) is not valid JSON (or contains comments). Nook did not touch anything.")
        }
        return Snapshot(object: object, original: data)
    }

    /// The contents of a Nook plugin file, or nil if it does not exist. If unreadable or not created by Nook: never touch it.
    private static func readPlugin(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NookError("\(url.path) cannot be read. Nook did not touch anything.")
        }
        guard String(decoding: data, as: UTF8.self).contains(AgentPlugins.marker) else {
            throw NookError("\(url.path) already exists and was not created by Nook. Nook did not touch anything.")
        }
        return data
    }

    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw NookError("\"hooks\" has an unexpected structure. Nook did not touch anything.")
        }
        return hooks
    }

    private static func set(_ root: inout [String: Any], _ key: String, _ hooks: [String: Any]) {
        if hooks.isEmpty { root.removeValue(forKey: key) } else { root[key] = hooks }
    }

    private static func group(_ command: String, matcher: String? = nil, timeout: Int) -> [String: Any] {
        var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    /// Single hook without an enclosing group (Antigravity, for non-tool events).
    private static func handler(_ command: String, timeout: Int) -> [String: Any] {
        ["type": "command", "command": command, "timeout": timeout]
    }

    private static func append(_ hooks: inout [String: Any], event: String, group: [String: Any]) throws {
        if let raw = hooks[event], !(raw is [Any]) {
            throw NookError("\"hooks\".\(event) has an unexpected structure. Nook did not touch anything.")
        }
        var groups = (hooks[event] as? [Any]) ?? []
        groups.append(group)
        hooks[event] = groups
    }

    /// Removes only Nook's own entries; groups that become empty are removed as well.
    private static func withoutNook(_ hooks: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                if containsMarker(value) {
                    throw NookError("\"hooks\".\(event) has an unexpected structure. Nook did not touch anything.")
                }
                result[event] = value
                continue
            }
            var kept: [Any] = []
            for entry in groups {
                guard var group = entry as? [String: Any] else {
                    kept.append(entry)
                    continue
                }
                if let command = group["command"] as? String, command.contains(marker) { continue }
                // A standalone entry without "hooks" (Copilot: "bash") from Nook.
                if group["hooks"] == nil, containsMarker(group) { continue }
                if let inner = group["hooks"] as? [Any] {
                    let filtered = inner.filter { !containsMarker($0) }
                    if filtered.isEmpty { continue }
                    group["hooks"] = filtered
                }
                kept.append(group)
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func containsMarker(_ value: Any) -> Bool {
        if let text = value as? String { return text.contains(marker) }
        if let list = value as? [Any] { return list.contains { containsMarker($0) } }
        if let dict = value as? [String: Any] { return dict.values.contains { containsMarker($0) } }
        return false
    }
}
