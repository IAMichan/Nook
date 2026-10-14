import Foundation

/// Koppelt Nook aan je agents door hun instellingenbestand aan te passen, maar alleen na jouw OK:
/// Nook leest het bestand, laat precies zien wat er verandert, maakt een backup met datum
/// en schrijft pas als het bestand sinds het voorbeeld niet is veranderd. Bestaande instellingen blijven staan.
enum AgentConfigInstaller {
    enum Target: String, CaseIterable, Identifiable {
        case claudeHooks, claudeStatusLine, codex, gemini

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeHooks: return "Claude Code"
            case .claudeStatusLine: return "Claude-abonnement in de notch"
            case .codex: return "Codex"
            case .gemini: return "Gemini CLI"
            }
        }

        var detail: String {
            switch self {
            case .claudeHooks: return "Voortgang, toestemming en vragen in de notch"
            case .claudeStatusLine: return "Je 5-uurs- en weeklimiet (Pro/Max), via de statusregel"
            case .codex: return "Voortgang en toestemming in de notch"
            case .gemini: return "Voortgang in de notch"
            }
        }

        var fileURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claudeHooks, .claudeStatusLine: return home.appendingPathComponent(".claude/settings.json")
            case .codex: return home.appendingPathComponent(".codex/hooks.json")
            case .gemini: return home.appendingPathComponent(".gemini/settings.json")
            }
        }

        var displayPath: String {
            switch self {
            case .claudeHooks, .claudeStatusLine: return "~/.claude/settings.json"
            case .codex: return "~/.codex/hooks.json"
            case .gemini: return "~/.gemini/settings.json"
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

    /// Een voorgestelde wijziging. Pas `apply` schrijft hem weg.
    struct Change: Identifiable {
        let id = UUID()
        let target: Target
        let install: Bool
        let original: Data?
        let updated: Data
        let preview: [DiffLine]
        /// Wat er voor de statusregel apart bewaard of weggegooid moet worden.
        let previousStatusLine: Data?
        let removePreviousStatusLine: Bool
    }

    private static let marker = "nook-hook"
    static let previousStatusLineURL = NookPaths.supportDirectory.appendingPathComponent("statusline-previous.json")

    // MARK: Toestand

    static func state(of target: Target) -> State {
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
        case .claudeHooks, .codex, .gemini:
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
        }
    }

    // MARK: Voorstel maken

    static func prepare(_ target: Target, install: Bool) throws -> Change {
        _ = try? HookScript.install()
        let snapshot = try read(target.fileURL)
        var root = snapshot.object
        var previous: Data?
        var removePrevious = false

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
        }

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let before = try snapshot.original.map { _ in
            try JSONSerialization.data(withJSONObject: snapshot.object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } ?? Data()
        let ops = LineDiff.diff(
            LineDiff.lines(String(decoding: before, as: UTF8.self)),
            LineDiff.lines(String(decoding: updated, as: UTF8.self))
        )
        return Change(
            target: target,
            install: install,
            original: snapshot.original,
            updated: updated,
            preview: LineDiff.display(ops, context: 2, limit: 400, width: 200),
            previousStatusLine: previous,
            removePreviousStatusLine: removePrevious
        )
    }

    // MARK: Wegschrijven

    /// Schrijft de wijziging, met eerst een backup. Is het bestand sinds het voorbeeld veranderd, dan gebeurt er niets.
    @discardableResult
    static func apply(_ change: Change) throws -> URL? {
        let url = change.target.fileURL
        let fm = FileManager.default
        let current = fm.fileExists(atPath: url.path) ? try? Data(contentsOf: url) : nil
        guard current == change.original else {
            throw NookError("\(change.target.displayPath) is veranderd sinds het voorbeeld. Er is niets geschreven; bekijk het opnieuw.")
        }

        var backup: URL?
        if change.original != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).nook-backup-\(formatter.string(from: Date()))")
            do {
                try fm.copyItem(at: url, to: backupURL)
            } catch {
                throw NookError("Kon geen backup maken van \(change.target.displayPath). Er is niets geschreven.")
            }
            backup = backupURL
        }

        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try change.updated.write(to: url, options: .atomic)
        } catch {
            throw NookError("Kon \(change.target.displayPath) niet schrijven: \(error.localizedDescription). Het origineel is niet aangeraakt.")
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
