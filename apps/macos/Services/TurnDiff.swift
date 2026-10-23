import Foundation

/// An edit of the agent as a unified diff, made from the tool's own input (what it replaced with what, or the whole
/// file it wrote), so a turn's changes can be read in the diff panel without asking git.
/// The line numbers count from the snippet, not the file: the tool input does not say where in the file it was.
enum EditPatch {
    /// A patch longer than this is cut: the diff panel is for reading, not for a generated file of megabytes.
    static let limit = 60_000

    static func make(tool: String, input: [String: Any]) -> String? {
        let patch: String
        switch tool.lowercased() {
        case "edit", "replace":
            patch = hunk((input["old_string"] as? String) ?? "", (input["new_string"] as? String) ?? "")
        case "multiedit":
            guard let edits = input["edits"] as? [[String: Any]] else { return nil }
            patch = edits.map { hunk(($0["old_string"] as? String) ?? "", ($0["new_string"] as? String) ?? "") }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        case "write", "write_file":
            guard let content = input["content"] as? String else { return nil }
            let added = lines(content)
            patch = added.isEmpty ? "" : (["@@ -0,0 +1,\(added.count) @@"] + added.map { "+" + $0 }).joined(separator: "\n")
        case "apply_patch":
            patch = (input["input"] as? String) ?? (input["patch"] as? String) ?? ""
        default:
            return nil
        }
        guard !patch.isEmpty else { return nil }
        return patch.count > limit ? String(patch.prefix(limit)) + "\n\\ " + "…" : patch
    }

    /// One hunk from the text an edit replaced and what it put there, with up to `context` unchanged lines around it.
    static func hunk(_ old: String, _ new: String, context: Int = 3) -> String {
        var ops = diff(lines(old), lines(new))
        guard ops.contains(where: { if case .same = $0 { return false } else { return true } }) else { return "" }
        var leading = 0
        while case .same = ops[leading] { leading += 1 }
        let dropFront = max(0, leading - context)
        ops.removeFirst(dropFront)
        var trailing = 0
        while case .same = ops[ops.count - 1 - trailing] { trailing += 1 }
        ops.removeLast(max(0, trailing - context))
        var oldCount = 0, newCount = 0
        var body: [String] = []
        for op in ops {
            switch op {
            case .same(let line): body.append(" " + line); oldCount += 1; newCount += 1
            case .remove(let line): body.append("-" + line); oldCount += 1
            case .add(let line): body.append("+" + line); newCount += 1
            }
        }
        return (["@@ -\(dropFront + 1),\(oldCount) +\(dropFront + 1),\(newCount) @@"] + body).joined(separator: "\n")
    }

    enum Op: Equatable { case same(String), add(String), remove(String) }

    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result = text.components(separatedBy: "\n")
        if result.last == "" { result.removeLast() }
        return result
    }

    /// The longest common run of lines kept, the rest removed and added; very large chunks count as replaced whole.
    static func diff(_ old: [String], _ new: [String]) -> [Op] {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        let a = Array(old[prefix..<(old.count - suffix)]), b = Array(new[prefix..<(new.count - suffix)])
        var ops = old[0..<prefix].map { Op.same($0) }
        if a.isEmpty || b.isEmpty || a.count * b.count > 250_000 {
            ops += a.map { Op.remove($0) } + b.map { Op.add($0) }
        } else {
            // Lengths of the common runs of every pair of tails, then walked from the front.
            var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] {
                    ops.append(.same(a[i])); i += 1; j += 1
                } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                    // Removed lines before added ones, as a unified diff reads.
                    ops.append(.remove(a[i])); i += 1
                } else {
                    ops.append(.add(b[j])); j += 1
                }
            }
        }
        ops += old[(old.count - suffix)...].map { Op.same($0) }
        return ops
    }

    /// A Codex patch ("*** Begin Patch") split per file: the path and its hunks as a unified diff.
    static func codexFiles(_ patch: String) -> [(path: String, patch: String)] {
        var files: [(path: String, patch: String)] = []
        var path: String?
        var lines: [String] = []
        var added = false
        func flush() {
            guard let path, !lines.isEmpty else { return }
            let body = lines.contains(where: { $0.hasPrefix("@@") }) ? lines
                : ["@@ -\(added ? 0 : 1),\(lines.filter { !$0.hasPrefix("+") }.count) +1,\(lines.filter { !$0.hasPrefix("-") }.count) @@"] + lines
            files.append((path, body.joined(separator: "\n")))
        }
        for line in patch.components(separatedBy: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                flush()
                path = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                lines = []
                added = marker == "*** Add File: "
            }
            if line.hasPrefix("*** ") { continue }
            if path != nil, line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") || line.hasPrefix("@@") {
                lines.append(line.hasPrefix("@@") && !line.contains("+") ? "@@ -1 +1 @@" : line)
            }
        }
        flush()
        return files
    }
}

/// What one turn of a conversation changed, file by file: for the card under the turn's answer ("3 changed files
/// +12 −4") and the diff panel next to the conversation, where you pick a turn or the whole session.
struct TurnDiff: Equatable, Identifiable, Sendable {
    struct File: Equatable, Identifiable, Sendable {
        /// As the agent named it: usually absolute.
        let path: String
        var lines = EditLines()
        /// The edits in the order the agent made them.
        var patches: [String] = []
        var id: String { path }

        /// The file's edits as one unified diff with a file header.
        var diff: String {
            let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
            return (["diff --git a/\(name) b/\(name)"] + patches).joined(separator: "\n")
        }
    }

    /// The id of the message that started the turn (your prompt), or "start" for work before any prompt.
    let id: String
    /// 1 for the first turn of the conversation.
    let number: Int
    var files: [File] = []
    /// The last answer of the turn: the card goes under it.
    var answerID: String?
    /// When the turn started and ended, for a session Nook runs: its git snapshots around the turn give the real diff.
    var start: Date?
    var end: Date?

    var lines: EditLines { files.reduce(EditLines()) { $0 + $1.lines } }
    var isEmpty: Bool { files.isEmpty }

    /// The path as it reads in the session's folder: relative when it is inside it.
    static func relative(_ path: String, to directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return path }
        let root = directory.hasSuffix("/") ? directory : directory + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }

    /// The files as a folder tree (the changed-files card), keyed by their path relative to `directory`.
    func tree(relativeTo directory: String?) -> ChangedFilesTree {
        ChangedFilesTree.build(files.map {
            ChangedFilesTree.FileStat(path: Self.relative($0.path, to: directory), added: $0.lines.added, removed: $0.lines.removed,
                                      kind: $0.patches.first?.hasPrefix("@@ -0,0") == true ? .added : .modified)
        })
    }

    /// The file with this path relative to `directory`, or as the agent named it.
    func file(_ path: String, relativeTo directory: String?) -> File? {
        // The tree drops the leading slash of a path outside the folder.
        files.first {
            let relative = Self.relative($0.path, to: directory)
            return $0.path == path || relative == path || relative == "/" + path
        }
    }

    /// Every file of these files as one diff, one file after the other.
    static func diff(_ files: [File]) -> String { files.map(\.diff).joined(separator: "\n") }

    /// The turns that changed a file, oldest first.
    static func collect(_ messages: [AgentChatMessage]) -> [TurnDiff] {
        var turns: [TurnDiff] = []
        var current = TurnDiff(id: "start", number: 0)
        func close() { if !current.isEmpty { turns.append(current) } }
        var number = 0
        for message in messages {
            switch message.kind {
            // A message sent while the agent worked steers the same turn; it does not start a new one.
            case .user where message.queued:
                break
            case .user:
                close()
                number += 1
                current = TurnDiff(id: message.id, number: number)
            case .assistant:
                current.answerID = message.id
            case .tools:
                for step in message.steps where step.state != .failed {
                    current.add(step)
                }
            case .thinking:
                break
            }
        }
        close()
        return turns
    }

    /// The finished turns of a session Nook runs that changed a file, from its timeline. The card goes under the
    /// turn's end; a file the agent changed without an edit tool (Codex's file changes) has no patch of its own.
    static func collect(events: [RunEvent]) -> [TurnDiff] {
        var turns: [TurnDiff] = []
        var number = 0
        for events in TimelinePresentation.split(events) {
            guard let first = events.first else { continue }
            if first.kind == .user { number += 1 }
            guard let end = events.last(where: { $0.kind == .result }) else { continue }
            var turn = TurnDiff(id: first.id.uuidString, number: max(number, 1), answerID: end.id.uuidString,
                                start: first.date, end: end.date)
            for event in events {
                switch event.kind {
                case .fileChange:
                    if let path = event.detail ?? (event.text.isEmpty ? nil : event.text) { turn.merge(File(path: path)) }
                case .tool where ToolCategory.of(tool: event.tool ?? "") == .edit && event.state != .failed:
                    let input = event.detail.flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    var step = AgentToolStep(id: event.id.uuidString, name: event.tool ?? "", summary: "",
                                             path: ToolSummary.path(input), lines: EditLines.of(event),
                                             patch: EditPatch.make(tool: event.tool ?? "", input: input))
                    step.state = .done
                    if step.patch == nil, let path = step.path { turn.merge(File(path: path, lines: step.lines ?? EditLines())) }
                    turn.add(step)
                default:
                    continue
                }
            }
            if !turn.isEmpty { turns.append(turn) }
        }
        return turns
    }

    /// The same turn with the lines git counted (keyed by the path relative to `directory`) in place of those from the
    /// agent's edits.
    func counted(_ counts: [String: EditLines], relativeTo directory: String?) -> TurnDiff {
        var copy = self
        for index in copy.files.indices {
            if let lines = counts[Self.relative(copy.files[index].path, to: directory)] { copy.files[index].lines = lines }
        }
        return copy
    }

    /// All the turns together, each file once with the edits of every turn: the whole session.
    static func session(_ turns: [TurnDiff]) -> TurnDiff {
        var all = TurnDiff(id: "all", number: 0, start: turns.compactMap(\.start).min(), end: turns.compactMap(\.end).max())
        for turn in turns {
            for file in turn.files { all.merge(file) }
        }
        return all
    }

    mutating func add(_ step: AgentToolStep) {
        guard let patch = step.patch else { return }
        if patch.hasPrefix("*** Begin Patch") {
            for part in EditPatch.codexFiles(patch) {
                merge(File(path: part.path, lines: EditLines.of(patch: part.patch) ?? EditLines(), patches: [part.patch]))
            }
        } else if let path = step.path ?? step.file {
            merge(File(path: path, lines: step.lines ?? EditLines(), patches: [patch]))
        }
    }

    mutating func merge(_ file: File) {
        if let index = files.firstIndex(where: { $0.path == file.path }) {
            files[index].lines = files[index].lines + file.lines
            files[index].patches += file.patches
        } else {
            files.append(file)
        }
    }
}
