import Foundation

// The logic of the one composer that Nook's chat and the agents share: `/` commands, `@` mentions and
// `#` pull requests with a list under the text, typed context references that read well and cannot forge instructions,
// queue / steer on the send button with a key to flip it, ArrowUp for earlier messages, and big pastes as attachments.
// Foundation only, so tests can use it independently.

// MARK: Triggers

/// What you are typing at the end of the text: a command, a mention or a pull request.
struct ComposerTrigger: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `/` at the very start: a command or skill.
        case command
        /// `@`: a file, or another session.
        case mention
        /// `#`: a pull request.
        case pullRequest
        /// `$`: a skill of the agent.
        case skill
    }

    var kind: Kind
    var query: String
    /// The text the trigger stands on, from its character to the end.
    var token: String

    private static func character(_ kind: Kind) -> Character {
        switch kind {
        case .command: return "/"
        case .mention: return "@"
        case .pullRequest: return "#"
        case .skill: return "$"
        }
    }

    /// The trigger at the end of `text`: a token that starts with the trigger character (at the start of the text, or after
    /// a space or line break) and has no space yet. Commands only count at the very start, so a path like `src/app` never
    /// opens the list.
    static func detect(in text: String) -> ComposerTrigger? {
        guard let space = text.lastIndex(where: { $0.isWhitespace }) else { return trigger(text, atStart: true) }
        return trigger(String(text[text.index(after: space)...]), atStart: false)
    }

    private static func trigger(_ token: String, atStart: Bool) -> ComposerTrigger? {
        guard let first = token.first else { return nil }
        let kind: Kind
        switch first {
        case "/": guard atStart else { return nil }; kind = .command
        case "@": kind = .mention
        case "#": kind = .pullRequest
        case "$": kind = .skill
        default: return nil
        }
        return ComposerTrigger(kind: kind, query: String(token.dropFirst()), token: token)
    }

    /// The text with the trigger replaced (a chosen link, or a command's text), followed by a space.
    func replacing(in text: String, with insertion: String) -> String {
        guard text.hasSuffix(token) else { return text }
        return String(text.dropLast(token.count)) + insertion + " "
    }
}

/// A command in the `/` list.
struct ComposerCommand: Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    /// The text it puts in the box ("/plan" turns on Plan mode instead and puts nothing).
    var insertion: String
    var action: Action

    enum Action: Equatable, Sendable {
        /// Put `insertion` in the box.
        case insert
        case plan
        case compact
        case new
        case fork
    }

    static func filter(_ commands: [ComposerCommand], query: String) -> [ComposerCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return commands }
        let starts = commands.filter { $0.name.lowercased().hasPrefix(q) }
        let contains = commands.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return starts + contains
    }
}

// MARK: Send, queue, steer

/// What the send button does while the agent works.
enum ComposerDispatch {
    enum Intent: String, CaseIterable, Sendable { case steer, queue }
    enum Outcome: Equatable, Sendable { case send, steer, queue }

    /// The intent for this message: your default, flipped by the modifier key (Cmd+Return).
    static func intent(default preferred: Intent, flip: Bool) -> Intent {
        guard flip else { return preferred }
        return preferred == .steer ? .queue : .steer
    }

    /// Not busy: send. Busy: steer when you chose it and the agent can, otherwise queue.
    static func resolve(busy: Bool, intent: Intent, canSteer: Bool) -> Outcome {
        guard busy else { return .send }
        return intent == .steer && canSteer ? .steer : .queue
    }
}

// MARK: History

/// ArrowUp and ArrowDown walk through what you sent earlier, as in a shell. What you were typing comes back at the end.
struct PromptHistory: Sendable {
    private(set) var entries: [String] = []
    private var position: Int?
    private var draft = ""
    static let limit = 50

    mutating func record(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        position = nil
        guard !clean.isEmpty, entries.last != clean else { return }
        entries.append(clean)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// ArrowUp: the previous message. `current` is kept as the draft at the first step.
    mutating func previous(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let at = position {
            guard at > 0 else { return nil }
            position = at - 1
        } else {
            draft = current
            position = entries.count - 1
        }
        return position.map { entries[$0] }
    }

    /// ArrowDown: the next message, and finally your draft. Nil when you are not walking through the history.
    mutating func next() -> String? {
        guard let at = position else { return nil }
        if at + 1 < entries.count {
            position = at + 1
            return entries[at + 1]
        }
        position = nil
        return draft
    }

    var isWalking: Bool { position != nil }

    mutating func stopWalking() { position = nil }
}

/// ArrowUp only walks through the history when the text is empty or one line, so it never takes the arrow from a text
/// you are editing.
enum ComposerKeys {
    static func arrowWalksHistory(text: String, walking: Bool) -> Bool {
        walking || !text.contains("\n")
    }
}

// MARK: Big pastes

enum PasteRule {
    /// A paste at least this big becomes a file the agent reads, not text in the box.
    static let attachThreshold = 32 * 1024

    static func shouldAttach(_ text: String) -> Bool { text.utf8.count >= attachThreshold }

    /// A name for the pasted text: "Pasted text (45 KB).txt".
    static func fileName(for text: String) -> String {
        "Pasted text (\(max(1, text.utf8.count / 1024)) KB)"
    }

    /// What a paste added: the text before it, the pasted text and the text after it, found by comparing the box before and
    /// after. Nil when nothing was added or the change was not one insertion.
    static func split(old: String, new: String) -> (prefix: String, inserted: String, suffix: String)? {
        guard new.count > old.count else { return nil }
        let before = Array(old), after = Array(new)
        var head = 0
        while head < before.count, head < after.count, before[head] == after[head] { head += 1 }
        var tail = 0
        while tail < before.count - head, tail < after.count - head, before[before.count - 1 - tail] == after[after.count - 1 - tail] { tail += 1 }
        guard head + tail == before.count else { return nil }
        let inserted = String(after[head..<(after.count - tail)])
        guard !inserted.isEmpty else { return nil }
        return (String(after[..<head]), inserted, String(after[(after.count - tail)...]))
    }
}

// MARK: Context references

/// Something you point the agent at. It sits in the message as a link that reads well, and reaches the agent as a short
/// marker plus a record.
struct ContextRef: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case file, session, pullRequest, excerpt, source
        /// A skill the agent has (by name): named in the text, the agent loads it itself.
        case skill
        /// A big paste kept out of the box: it goes to the agent whole (up to `ContextRefs.pasteLimit`).
        case paste
    }

    var kind: Kind
    /// A path, a session id, "owner/repo#12", or a counter for excerpts.
    var id: String
    var label: String
    /// Text carried along (an excerpt); files, sessions and pull requests carry none: the agent reads them when it needs them.
    var content: String? = nil
}

enum ContextRefs {
    static let scheme = "nook-context"
    static let version = "v1"
    /// The most excerpt text that goes to the agent for one reference.
    static let excerptLimit = 12_000
    /// Text you pasted yourself is not clipped like captured output, only bounded.
    static let pasteLimit = 400_000

    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()

    /// `[label](nook-context://v1/file/Sources%2FLogin.swift)`
    static func link(_ ref: ContextRef) -> String {
        let id = ref.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref.id
        let label = ref.label.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return "[\(label)](\(scheme)://\(version)/\(ref.kind.rawValue)/\(id))"
    }

    struct Found: Equatable {
        var kind: ContextRef.Kind
        var id: String
        var label: String
        var range: Range<String.Index>
    }

    private static let pattern = try? NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(nook-context://v1/([a-zA-Z]+)/([^)\s]*)\)"#)

    /// The references in a text, in order. Links of another kind or version are left alone.
    static func find(in text: String) -> [Found] {
        guard let pattern else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: whole).compactMap { match in
            guard match.numberOfRanges == 4, let all = Range(match.range, in: text), let label = Range(match.range(at: 1), in: text),
                  let kindRange = Range(match.range(at: 2), in: text), let idRange = Range(match.range(at: 3), in: text),
                  let kind = ContextRef.Kind(rawValue: String(text[kindRange])) else { return nil }
            let id = String(text[idRange]).removingPercentEncoding ?? String(text[idRange])
            return Found(kind: kind, id: id, label: String(text[label]), range: all)
        }
    }

    /// `<` and `&` made harmless: captured text can never close a record or open another.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// What the agent receives. Each reference stays in place as a short marker (`@Login.swift`); after the text comes one
    /// `<nook_context>` envelope with a record per reference. Files, sessions and pull requests are only named: the agent
    /// reads them itself (so a path never grants anything, and a long session is not pasted). Excerpts carry their text,
    /// clipped and escaped. Without references the text goes through unchanged.
    static func project(_ text: String, excerpts: [String: String] = [:]) -> String {
        let found = find(in: text)
        guard !found.isEmpty else { return text }
        var result = text
        for item in found.reversed() {
            result.replaceSubrange(item.range, with: marker(item))
        }
        var seen = Set<String>()
        var records: [String] = []
        for item in found {
            let key = "\(item.kind.rawValue)|\(item.id)"
            guard seen.insert(key).inserted else { continue }
            var record = "<ref kind=\"\(item.kind.rawValue)\" id=\"\(escape(item.id))\""
            if item.kind == .excerpt || item.kind == .paste, let content = excerpts[item.id] {
                let limit = item.kind == .paste ? pasteLimit : excerptLimit
                let clipped = content.count > limit ? String(content.prefix(limit)) + "\n…" : content
                record += ">\n\(escape(clipped))\n</ref>"
            } else {
                record += "/>"
            }
            records.append(record)
        }
        return result + "\n\n<nook_context>\n" + records.joined(separator: "\n") + "\n</nook_context>"
    }

    private static func marker(_ item: Found) -> String {
        switch item.kind {
        case .file: return "@" + item.label
        case .session: return "[session: " + item.label + "]"
        case .pullRequest: return "#" + item.label
        case .skill: return "$" + item.label
        case .excerpt, .paste: return "[" + item.label + "]"
        case .source: return "[" + item.label + "]"
        }
    }

    /// What you wrote, without the envelope that `project` adds: for the timeline and the queue.
    static func visible(_ projected: String) -> String {
        guard let range = projected.range(of: "\n\n<nook_context>\n") else { return projected }
        return String(projected[..<range.lowerBound])
    }

    /// The text as you read it back: links shown by their label.
    static func plain(_ text: String) -> String {
        var result = text
        for item in find(in: text).reversed() { result.replaceSubrange(item.range, with: item.label) }
        return result
    }
}

// MARK: File search

/// Files under a folder for the `@` list: a path match, best first, without build output and hidden folders.
enum FileSearch {
    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".next", "dist",
                                       "target", ".venv", "venv", "__pycache__", ".idea", ".gradle"]

    /// Paths relative to `root`, at most `limit`. Scoring: name starts with the query, then name contains it, then the path.
    static func search(root: String, query: String, limit: Int = 8, scanLimit: Int = 6_000, fileManager: FileManager = .default) -> [String] {
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        guard let walker = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let q = query.lowercased()
        var scored: [(path: String, score: Int)] = []
        var scanned = 0
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            scanned += 1
            if scanned > scanLimit { break }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.path.count + 1))
            let name = url.lastPathComponent.lowercased()
            let score: Int
            if q.isEmpty { score = 3 - min(2, relative.filter { $0 == "/" }.count) }
            else if name.hasPrefix(q) { score = 100 - min(50, relative.count) }
            else if name.contains(q) { score = 60 - min(30, relative.count) }
            else if relative.lowercased().contains(q) { score = 20 - min(15, relative.count) }
            else { continue }
            scored.append((relative, score))
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }.prefix(limit).map(\.path)
    }
}
