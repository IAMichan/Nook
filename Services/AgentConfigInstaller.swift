import Foundation

/// Koppelt Nook aan je agents door hun instellingenbestand aan te passen, maar alleen na jouw OK:
/// Nook leest het bestand, laat precies zien wat er verandert, maakt een backup met datum
/// en schrijft pas als het bestand sinds het voorbeeld niet is veranderd. Bestaande instellingen blijven staan.
enum AgentConfigInstaller {
    enum Target: String, CaseIterable, Identifiable {
        case claudeHooks, claudeStatusLine, codex, gemini, antigravity, cursor, copilot, muse, openCode, amp, hermes

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeHooks: return "Claude Code"
            case .claudeStatusLine: return "Claude-abonnement in de notch"
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
            case .claudeHooks: return "Voortgang, toestemming en vragen in de notch"
            case .claudeStatusLine: return "Je 5-uurs- en weeklimiet (Pro/Max), via de statusregel"
            case .codex: return "Voortgang en toestemming in de notch"
            case .gemini, .antigravity, .cursor, .copilot, .muse: return "Voortgang in de notch"
            case .openCode, .amp: return "Voortgang in de notch, via een kleine plugin"
            case .hermes: return "Voortgang in de notch, via een plugin. Zet hem daarna aan met: hermes plugins enable nook"
            }
        }

        /// Het (eerste) bestand dat Nook aanpast of maakt.
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

        /// De koppeling voor een agent zoals Nook hem op je Mac ziet draaien ("Claude Code", "Codex"…).
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

        /// Agents die een eigen pluginbestand van Nook laden, in plaats van hook-commando's in hun JSON.
        var isPlugin: Bool {
            switch self {
            case .openCode, .amp, .hermes: return true
            default: return false
            }
        }

        /// De bestanden van een plugin met hun inhoud; leeg voor agents met JSON-instellingen.
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
        /// Gekoppeld met een oudere versie van Nook: bijwerken geeft toestemming via PermissionRequest en vragen.
        case outdated
        case unreadable(String)
    }

    /// Eén bestand in een wijziging. `updated == nil` betekent: het bestand verdwijnt
    /// (alleen bij een bestand dat helemaal van Nook is, zoals een plugin).
    struct FileChange {
        let url: URL
        let original: Data?
        let updated: Data?
    }

    /// Een voorgestelde wijziging. Pas `apply` schrijft hem weg.
    struct Change: Identifiable {
        let id = UUID()
        let target: Target
        let install: Bool
        /// Het eerste bestand is `target.fileURL`; een plugin kan er meer hebben (Hermes: plugin.yaml).
        let files: [FileChange]
        let preview: [DiffLine]
        /// Wat er voor de statusregel apart bewaard of weggegooid moet worden.
        let previousStatusLine: Data?
        let removePreviousStatusLine: Bool

        var original: Data? { files.first?.original }
        var updated: Data? { files.first?.updated }
    }

    private static let marker = "nook-hook"
    /// De naam van Nooks eigen groep in ~/.gemini/config/hooks.json (Antigravity).
    private static let antigravityGroup = "nook"
    static let previousStatusLineURL = NookPaths.supportDirectory.appendingPathComponent("statusline-previous.json")

    // MARK: Toestand

    static func state(of target: Target) -> State {
        if target.isPlugin { return pluginState(target) }
        let root: [String: Any]
        do {
            root = try read(target.fileURL).object
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

    /// Een plugin is gekoppeld als al zijn bestanden er staan en van Nook zijn.
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

    // MARK: Voorstel maken

    static func prepare(_ target: Target, install: Bool) throws -> Change {
        _ = try? HookScript.install()
        if target.isPlugin { return try preparePlugin(target, install: install) }
        let snapshot = try read(target.fileURL)
        var root = snapshot.object
        var previous: Data?
        var removePrevious = false
        // Alleen voor een bestand dat helemaal van Nook is: na het ontkoppelen mag het weg.
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
                    inner[0]["statusMessage"] = "Wacht op je antwoord in de notch (Nook)"
                    waiting["hooks"] = inner
                }
                try append(&hooks, event: "PermissionRequest", group: waiting)
            }
            set(&root, "hooks", hooks)

        case .gemini:
            var hooks = try hooksObject(root)
            hooks = try withoutNook(hooks)
            if install {
                // Gemini gebruikt eigen namen en time-outs in milliseconden; Nook krijgt de gewone naam mee.
                for (event, name, timeout) in [("SessionStart", "SessionStart", 10_000), ("SessionEnd", "SessionEnd", 10_000),
                                               ("BeforeTool", "PreToolUse", 5_000), ("AfterTool", "PostToolUse", 5_000),
                                               ("BeforeAgent", "UserPromptSubmit", 5_000), ("AfterAgent", "Stop", 5_000)] {
                    try append(&hooks, event: event,
                               group: group(HookScript.command("--agent gemini \(name)"), matcher: "*", timeout: timeout))
                }
            }
            set(&root, "hooks", hooks)

        case .antigravity:
            // Antigravity (agy) kent benoemde groepen bovenin het bestand; die van Nook heet "nook".
            // Tools krijgen een matcher-groep, de rest een handler zonder; time-outs in seconden.
            if let existing = root[antigravityGroup], !containsMarker(existing) {
                throw NookError("\(target.displayPath) heeft al een groep \"\(antigravityGroup)\" die niet van Nook is. Nook heeft niets aangeraakt.")
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
            // {"version": 1, "hooks": {"stop": [{"command": …}]}}: Cursor zet de naam zelf in de JSON
            // en krijgt nooit een antwoord terug, dus Nook beslist niets voor Cursor.
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
            // Een eigen bestand in Copilots map met hooks: camelCase-namen, {"bash": …, "timeoutSec": N}.
            // Copilot zet de naam niet in de JSON, dus die gaat mee op de opdrachtregel.
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
            // Staat er na het ontkoppelen niets van een ander meer in, dan was het bestand van Nook en gaat het weg.
            if !install, root.keys.allSatisfy({ $0 == "version" }) { removeFile = true }

        case .muse:
            // Net als Claude Code, maar met een matcher en time-outs in milliseconden.
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
                if let current, !ours {
                    // De statusregel die je al had, blijft zichtbaar: Nook roept hem zelf aan.
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
        // Een ontbrekend bestand dat ook niet hoeft te komen: niets te doen.
        let files: [FileChange] = snapshot.original == nil && updated == nil
            ? []
            : [FileChange(url: target.fileURL, original: snapshot.original, updated: updated)]
        return Change(
            target: target,
            install: install,
            files: files,
            preview: LineDiff.display(ops, context: 2, limit: 400, width: 200),
            previousStatusLine: previous,
            removePreviousStatusLine: removePrevious
        )
    }

    /// Een plugin is een eigen bestand van Nook: koppelen schrijft het (opnieuw), ontkoppelen haalt het weg.
    /// Een bestand met dezelfde naam dat niet van Nook is, blijft altijd staan.
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

    // MARK: Wegschrijven

    /// Schrijft de wijziging, met eerst een backup. Is een bestand sinds het voorbeeld veranderd, dan gebeurt er niets.
    @discardableResult
    static func apply(_ change: Change) throws -> URL? {
        let fm = FileManager.default
        for file in change.files {
            let current = fm.fileExists(atPath: file.url.path) ? try? Data(contentsOf: file.url) : nil
            guard current == file.original else {
                throw NookError("\(change.target.displayPath) is veranderd sinds het voorbeeld. Er is niets geschreven; bekijk het opnieuw.")
            }
        }

        // Wat gelijk blijft, hoeft geen backup en wordt niet opnieuw geschreven.
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
                throw NookError("Kon geen backup maken van \(change.target.displayPath). Er is niets geschreven.")
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
                throw NookError("Kon \(change.target.displayPath) niet schrijven: \(error.localizedDescription). De backup staat ernaast.")
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

    // MARK: Hulpfuncties

    private struct Snapshot {
        var object: [String: Any]
        var original: Data?
    }

    /// Een ontbrekend bestand telt als leeg; een onleesbaar of ongeldig bestand nooit.
    private static func read(_ url: URL) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot(object: [:], original: nil) }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NookError("\(url.path) is niet te lezen. Nook heeft niets aangeraakt.")
        }
        if data.allSatisfy({ $0 == 32 || $0 == 10 || $0 == 13 || $0 == 9 }) {
            return Snapshot(object: [:], original: data)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NookError("\(url.path) is geen geldige JSON (of bevat commentaar). Nook heeft niets aangeraakt.")
        }
        return Snapshot(object: object, original: data)
    }

    /// De inhoud van een pluginbestand van Nook, nil als het er niet is. Onleesbaar, of niet van Nook: dan nooit aanraken.
    private static func readPlugin(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw NookError("\(url.path) is niet te lezen. Nook heeft niets aangeraakt.")
        }
        guard String(decoding: data, as: UTF8.self).contains(AgentPlugins.marker) else {
            throw NookError("\(url.path) bestaat al en is niet door Nook gemaakt. Nook heeft niets aangeraakt.")
        }
        return data
    }

    private static func hooksObject(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else {
            throw NookError("\"hooks\" heeft een onverwachte vorm. Nook heeft niets aangeraakt.")
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

    /// Eén hook zonder groep eromheen (Antigravity, voor gebeurtenissen buiten tools).
    private static func handler(_ command: String, timeout: Int) -> [String: Any] {
        ["type": "command", "command": command, "timeout": timeout]
    }

    private static func append(_ hooks: inout [String: Any], event: String, group: [String: Any]) throws {
        if let raw = hooks[event], !(raw is [Any]) {
            throw NookError("\"hooks\".\(event) heeft een onverwachte vorm. Nook heeft niets aangeraakt.")
        }
        var groups = (hooks[event] as? [Any]) ?? []
        groups.append(group)
        hooks[event] = groups
    }

    /// Haalt alleen Nooks eigen regels weg; groepen die daarna leeg zijn, verdwijnen ook.
    private static func withoutNook(_ hooks: [String: Any]) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [Any] else {
                if containsMarker(value) {
                    throw NookError("\"hooks\".\(event) heeft een onverwachte vorm. Nook heeft niets aangeraakt.")
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
                // Een losse regel zonder "hooks" (Copilot: "bash") van Nook.
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
