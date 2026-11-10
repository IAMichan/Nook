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
    /// The text the trigger stands on, from its character to the caret.
    var token: String
    /// Where `token` is in the text (UTF-16 offsets), when it was read at the caret (`detect(in:caret:)`); nil means at
    /// the end.
    var range: Range<Int>? = nil

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

    /// The trigger that ends right at `caret` (UTF-16 offset), so `@` typed in the middle of the text opens the list
    /// there too; the text after the caret plays no part. Nil `caret` (or the end) reads the end of the text.
    static func detect(in text: String, caret: Int?) -> ComposerTrigger? {
        let length = text.utf16.count
        let end = min(max(caret ?? length, 0), length)
        guard let index = String.Index(exactUTF16: end, in: text) else { return nil }
        guard var found = detect(in: String(text[..<index])) else { return nil }
        found.range = (end - found.token.utf16.count)..<end
        return found
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
        inserting(insertion, in: text).text
    }

    /// The text with the trigger replaced by `insertion` where it was typed, and the caret (UTF-16) right after it. A
    /// space follows the insertion unless the text goes on with one already; the caret then lands past that space. Text
    /// that no longer holds the token where it was is left alone (caret nil).
    func inserting(_ insertion: String, in text: String) -> (text: String, caret: Int?) {
        guard let start = tokenStart(in: text) else { return (text, nil) }
        let end = text.index(start, offsetBy: token.count)
        let head = String(text[..<start]) + insertion
        let rest = text[end...]
        if let next = rest.first, next.isWhitespace {
            // Past the space or line break that is already there.
            return (head + rest, head.utf16.count + String(next).utf16.count)
        }
        return (head + " " + rest, head.utf16.count + 1)
    }

    /// The text without the trigger (a command that runs instead of filling the box), and the caret where it was.
    func removing(from text: String) -> (text: String, caret: Int?) {
        guard let start = tokenStart(in: text) else { return (text, nil) }
        let end = text.index(start, offsetBy: token.count)
        if range == nil || end == text.endIndex {
            let kept = String(text[..<start]).trimmingCharacters(in: .whitespaces)
            return (kept + text[end...], kept.utf16.count)
        }
        return (String(text[..<start]) + text[end...], text[..<start].utf16.count)
    }

    /// Where the token starts, if the text still holds it where it was read.
    private func tokenStart(in text: String) -> String.Index? {
        guard let range else {
            guard text.hasSuffix(token) else { return nil }
            return text.index(text.endIndex, offsetBy: -token.count)
        }
        guard let start = String.Index(exactUTF16: range.lowerBound, in: text),
              let end = String.Index(exactUTF16: range.upperBound, in: text),
              text[start..<end] == token else { return nil }
        return start
    }
}

extension String.Index {
    /// The index at a UTF-16 offset of `text`; nil when the offset is outside the text or splits a character.
    init?(exactUTF16 offset: Int, in text: String) {
        guard offset >= 0, offset <= text.utf16.count,
              let index = text.utf16.index(text.utf16.startIndex, offsetBy: offset).samePosition(in: text) else { return nil }
        self = index
    }
}

/// A command in the `/` list.
struct ComposerCommand: Equatable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    /// The text it puts in the box ("/plan" turns on Plan mode instead and puts nothing).
    var insertion: String
    var action: Action
    /// What it does, in the words of the agent that offers it; Nook's own commands are described in `I18n`.
    var detail: String? = nil

    enum Action: Equatable, Sendable {
        /// Put `insertion` in the box.
        case insert
        case plan
        case compact
        case new
        case fork
        /// Start a new conversation with the same agent in this session (`WorkspaceManager.clearConversation`).
        case clear
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

    /// The history of one session: the messages you sent it, oldest first, so ArrowUp after a relaunch or a switch walks
    /// through what you wrote there rather than in another session.
    mutating func seed(_ sent: [String]) {
        entries = []
        position = nil
        draft = ""
        for text in sent.suffix(Self.limit * 2) { record(text) }
    }

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

    /// The most characters one message holds (as in t3code): a longer draft stays in the box, with a notice, until you
    /// shorten it or split it into several messages.
    static let messageLimit = 120_000

    /// Characters over the limit, or nil when the draft fits.
    static func overLimit(_ text: String) -> Int? {
        // Asked on every redraw of the composer: a text has at least as many UTF-16 units as characters, and counting
        // those is constant time.
        guard text.utf16.count > messageLimit else { return nil }
        let count = text.count
        return count > messageLimit ? count - messageLimit : nil
    }

    /// Whether a paste of `inserted` that made the box `result` goes aside as an attachment: a big one unless you pasted
    /// it as text (⇧⌘V), and any paste that would push the message past `messageLimit`, as text or not.
    static func attaches(_ inserted: String, result: String, asText: Bool) -> Bool {
        if overLimit(result) != nil { return true }
        return !asText && shouldAttach(inserted)
    }

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
        /// A model, named for the agent to use (for a subagent or a delegated task); it does not change the session's
        /// own model. Its id is "agent/model" (`ModelMention.id`).
        case model
        /// A secret you pasted, kept out of the message: the id is the private file that holds it (`SecretFiles`), the
        /// label its name. The agent gets the path and how to use it, never the value.
        case secret
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

    /// The reference as words people read (a mail, a commit message): a file by its path, a pull request as `#12`, the
    /// rest by its label.
    static func plainText(_ ref: ContextRef) -> String {
        switch ref.kind {
        case .file: return ref.id
        case .pullRequest: return "#" + ref.label
        case .skill: return "$" + ref.label
        case .session, .excerpt, .source, .paste, .model, .secret: return ref.label
        }
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
        // Runs several times per key in the composer: most drafts hold no reference, so skip the expression for them.
        guard let pattern, text.contains("nook-context:") else { return [] }
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
            if item.kind == .secret {
                record += ">\n\(escape(SecretFiles.instructions(name: item.label, path: item.id)))\n</ref>"
            } else if item.kind == .excerpt || item.kind == .paste, let content = excerpts[item.id] {
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
        case .excerpt, .paste, .secret: return "[" + item.label + "]"
        case .source: return "[" + item.label + "]"
        case .model: return "[model: " + item.label + "]"
        }
    }

    /// What you wrote, without the envelope that `project` adds: for the timeline and the queue.
    static func visible(_ projected: String) -> String {
        guard let range = projected.range(of: "\n\n<nook_context>\n") else { return projected }
        return String(projected[..<range.lowerBound])
    }

    /// What your message shows in the timeline: as `visible`, but the files and folders attached at its end (`@Downloads`)
    /// become their paths on lines of their own, followed by the paths of the pictures sent with it, so the message
    /// shows them all as tiles above its bubble (`ImageAttachment.splittingPaths`). Relative paths start from `folder`.
    static func timeline(_ projected: String, folder: String?) -> String {
        guard let start = projected.range(of: "\n\n<nook_context>\n"),
              let end = projected.range(of: "\n</nook_context>", range: start.upperBound..<projected.endIndex) else { return projected }
        var words = String(projected[..<start.lowerBound])
        let records = String(projected[start.upperBound..<end.lowerBound])
        let pictures = projected[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        var files = fileRecords(in: records)
        var attached: [String] = []
        // The attached files close the words, one `@label` after another: take them off from the end.
        while !files.isEmpty {
            let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = files.lastIndex(where: { endsWithMarker(trimmed, of: $0) }) else { break }
            let id = files.remove(at: index)
            words = String(trimmed.dropLast(marker(of: id).count))
            attached.insert(AnswerAttachments.absolutePath(id, folder: folder), at: 0)
        }
        let paths = (attached + (pictures.isEmpty ? [] : [pictures])).joined(separator: "\n")
        let body = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty else { return body }
        return body.isEmpty ? paths : body + "\n\n" + paths
    }

    /// The ids of the file records in an envelope, in order.
    private static func fileRecords(in records: String) -> [String] {
        records.components(separatedBy: "\n").compactMap { line in
            let prefix = "<ref kind=\"file\" id=\""
            guard line.hasPrefix(prefix), line.hasSuffix("\"/>") else { return nil }
            let id = line.dropFirst(prefix.count).dropLast(3)
            return id.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&amp;", with: "&")
        }
    }

    /// `@label` of a file as `project` writes it: files are labeled by their name.
    private static func marker(of id: String) -> String {
        "@" + (id as NSString).lastPathComponent.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
    }

    private static func endsWithMarker(_ text: String, of id: String) -> Bool {
        let marker = marker(of: id)
        guard text.hasSuffix(marker) else { return false }
        let before = text.dropLast(marker.count)
        return before.isEmpty || before.last?.isWhitespace == true
    }

    /// The text as you read it back: links shown by their label.
    static func plain(_ text: String) -> String {
        var result = text
        for item in find(in: text).reversed() { result.replaceSubrange(item.range, with: item.label) }
        return result
    }
}

// MARK: Attached files

/// Files at the end of a draft are shown as tiles above the box (like pictures) instead of as links in the text. The draft
/// keeps them as links, so sending, saving and restoring a draft work as before; the box only shows and edits `body`.
enum ComposerAttachments {
    struct Split: Equatable {
        /// What the box shows: the draft up to the first attached file, whitespace before it included.
        var body: String
        /// The attached files, in order.
        var files: [ContextRefs.Found]
        /// The rest of the draft: the links and the whitespace between them. `body + tail` is the draft.
        var tail: String
    }

    static func isAttachable(_ kind: ContextRef.Kind) -> Bool { kind == .file || kind == .paste }

    /// The draft split into the words you typed and the run of file links that ends it.
    static func split(_ text: String) -> Split {
        var start = text.endIndex
        var files: [ContextRefs.Found] = []
        for item in ContextRefs.find(in: text).reversed() {
            var end = start
            while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
            guard isAttachable(item.kind), item.range.upperBound == end else { break }
            start = item.range.lowerBound
            files.insert(item, at: 0)
        }
        guard !files.isEmpty else { return Split(body: text, files: [], tail: "") }
        return Split(body: String(text[..<start]), files: files, tail: String(text[start...]))
    }

    /// The draft after the box changed its words: the attached files stay at the end.
    static func replacingBody(of text: String, with body: String) -> String {
        body + split(text).tail
    }

    /// The draft with one more file at the end.
    static func appending(_ ref: ContextRef, to text: String) -> String {
        text + (text.isEmpty || text.last?.isWhitespace == true ? "" : " ") + ContextRefs.link(ref) + " "
    }

    /// The draft without the attached file at `index`.
    static func removing(at index: Int, from text: String) -> String {
        let parts = split(text)
        guard parts.files.indices.contains(index) else { return text }
        let kept = parts.files.enumerated().filter { $0.offset != index }.map { String(text[$0.element.range]) }
        return parts.body + kept.map { $0 + " " }.joined()
    }

    /// What goes out: the attached files on their own line under the words, so their markers never stick to a word.
    static func spaced(_ text: String) -> String {
        let parts = split(text)
        let body = parts.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parts.files.isEmpty, !body.isEmpty else { return text }
        return body + "\n\n" + parts.tail.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Paths in the box

/// A path that lands in the box as text (dropped on the focused field, which writes it in itself, or pasted from "Copy as
/// Pathname") is an attachment like any other: it leaves the text and becomes a tile.
enum PastedPaths {
    /// More text than this is not a list of paths.
    static let maxLength = 16 * 1024

    /// The box without the path, and what it pointed at, when the change put nothing but existing paths at the end of the
    /// words. A path you paste into the middle of a sentence stays where you put it, and keys you type never count: this
    /// looks at one insertion of several characters.
    static func attaching(old: String, new: String,
                          exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (body: String, urls: [URL])? {
        // Runs on every key: one more character can never be a paste, so stop before comparing the texts.
        guard new.count - old.count >= 2, new.utf8.count - old.utf8.count <= maxLength,
              let parts = PasteRule.split(old: old, new: new),
              parts.suffix.allSatisfy(\.isWhitespace), parts.prefix.last?.isWhitespace != false,
              let urls = urls(in: parts.inserted, exists: exists) else { return nil }
        return (parts.prefix, urls)
    }

    /// The files and folders a text names, or nil when any part of it is not one. Tried whole first (a path may hold
    /// spaces), then per line, then as shell words (`/a\ b "/c d"`, what Terminal and a multiple drop write).
    static func urls(in text: String, exists: (String) -> Bool) -> [URL]? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = clean.first, "/~'\"f".contains(first) else { return nil }
        if let whole = url(clean, exists: exists) { return [whole] }
        let lines = clean.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for parts in [lines, words(clean)] where parts.count > 1 {
            let found = parts.compactMap { url($0, exists: exists) }
            if found.count == parts.count { return found }
        }
        if let word = words(clean).first, words(clean).count == 1 { return url(word, exists: exists).map { [$0] } }
        return nil
    }

    private static func url(_ text: String, exists: (String) -> Bool) -> URL? {
        var path = text
        if path.count > 1, let quote = path.first, "'\"".contains(quote), path.last == quote { path = String(path.dropFirst().dropLast()) }
        if path.hasPrefix("file://") {
            guard let url = URL(string: path), url.isFileURL else { return nil }
            path = url.path
        }
        path = (path as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), path.count > 1, exists(path) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// The text split on spaces, with quotes and backslashes read the way a shell does.
    private static func words(_ text: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false, started = false
        for character in text {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\", quote != "'" {
                escaped = true
                started = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if started { words.append(word) }
                word = ""
                started = false
            } else {
                word.append(character)
                started = true
            }
        }
        if started { words.append(word) }
        return words
    }
}

// MARK: Files in an answer

/// Files you attach to your own answer to an agent's question. A question's answer goes back as plain text (Claude
/// Code's AskUserQuestion, Codex's `requestUserInput`), so the files go as their absolute paths below your words, one per
/// line: every agent reads a path the same way and opens the file itself.
enum AnswerAttachments {
    /// A file reference from the picker (relative to `folder` when inside it) as an absolute path.
    static func absolutePath(_ id: String, folder: String?) -> String {
        guard !id.hasPrefix("/"), let folder, !folder.isEmpty else { return id }
        return URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(id).standardizedFileURL.path
    }

    /// Your words with the paths below them; each path once, in the order they were added. Only words: unchanged.
    static func answer(_ text: String, paths: [String]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        let clean = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !clean.isEmpty else { return trimmed }
        return (trimmed.isEmpty ? "" : trimmed + "\n\n") + clean.joined(separator: "\n")
    }
}

// MARK: File search

/// Files under a folder for the `@` list: a path match, best first, without build output and hidden folders.
enum FileSearch {
    static let skipped: Set<String> = [".git", "node_modules", ".build", "build", "DerivedData", "Pods", ".next", "dist",
                                       "target", ".venv", "venv", "__pycache__", ".idea", ".gradle"]

    /// Paths relative to `root`, at most `limit`. Scoring: name starts with the query, then name contains it, then the path.
    static func search(root: String, query: String, limit: Int = 8, scanLimit: Int = 6_000, fileManager: FileManager = .default) -> [String] {
        rank(list(root: root, scanLimit: scanLimit, fileManager: fileManager), query: query, limit: limit)
    }

    /// Every file under `root` the `@` list can offer, relative to it, at most `scanLimit`: the walk, done once per
    /// folder by `FileIndex` instead of on every key.
    static func list(root: String, scanLimit: Int = 6_000, fileManager: FileManager = .default) -> [String] {
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        guard let walker = fileManager.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var paths: [String] = []
        for case let url as URL in walker {
            if skipped.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if paths.count >= scanLimit { break }
            paths.append(String(url.standardizedFileURL.path.dropFirst(base.path.count + 1)))
        }
        return paths
    }

    /// The best `limit` of `paths` for `query`.
    static func rank(_ paths: [String], query: String, limit: Int = 8) -> [String] {
        let q = query.lowercased()
        var scored: [(path: String, score: Int)] = []
        for relative in paths {
            let name = (relative.split(separator: "/").last.map { String($0) } ?? relative).lowercased()
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

/// The files of a folder for the `@` list, walked once and kept for half a minute, so each key only filters a list in
/// memory. One walk per folder at a time: a key typed while it runs waits for the same walk instead of starting another.
actor FileIndex {
    static let shared = FileIndex()
    static let lifetime: TimeInterval = 30

    private var known: [String: (paths: [String], made: Date)] = [:]
    private var walking: [String: Task<[String], Never>] = [:]

    func paths(root: String) async -> [String] {
        let now = Date()
        if let entry = known[root], now.timeIntervalSince(entry.made) < Self.lifetime { return entry.paths }
        if let running = walking[root] { return await running.value }
        // Detached: a composer that stops waiting (the next key) must not stop the walk the others wait for.
        let walk = Task.detached(priority: .userInitiated) { FileSearch.list(root: root) }
        walking[root] = walk
        let paths = await walk.value
        walking[root] = nil
        known = known.filter { now.timeIntervalSince($0.value.made) < Self.lifetime }
        known[root] = (paths, Date())
        return paths
    }
}

// MARK: Model mentions

/// `@` and part of a model or agent name ("@opus", "@gpt-5", "@opus:claude") names a model for the agent, for a subagent
/// or a task it delegates; the session keeps its own model. The words of the query (split on `:`, `/`, `-` and spaces)
/// must each appear in the model's name, its id or its agent's name.
enum ModelMention {
    struct Candidate: Equatable, Sendable {
        /// The agent's id (`RunProvider.rawValue`, or the profile of an agent you added).
        var agent: String
        var agentName: String
        var model: String
        var name: String
    }

    /// Every connected agent's models as candidates, in the agents' order. The agents you added yourself (ACP) are left
    /// out: `delegate_task` cannot start them.
    static func candidates(_ providers: [RunProvider], models: (RunProvider) -> [(id: String, name: String)]) -> [Candidate] {
        providers.flatMap { provider -> [Candidate] in
            switch provider {
            case .acp: return []
            case .claude, .codex, .gemini, .antigravity, .opencode, .cursor, .grok, .pi:
                return models(provider).map { Candidate(agent: provider.rawValue, agentName: provider.displayName,
                                                        model: $0.id, name: $0.name) }
            }
        }
    }

    /// The reference's id: the agent and the model it runs, so the agent knows where to send the task.
    static func id(agent: String, model: String) -> String { agent + "/" + model }

    /// The reference for a candidate; its label reads "Opus 4.6 · Claude Code".
    static func ref(_ candidate: Candidate) -> ContextRef {
        ContextRef(kind: .model, id: id(agent: candidate.agent, model: candidate.model),
                   label: candidate.name + " · " + candidate.agentName)
    }

    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "-" || $0.isWhitespace }).map(String.init)
    }

    /// The candidates the query names, in their order; none for an empty query, so a bare `@` lists files and sessions.
    static func matches(_ query: String, in candidates: [Candidate], limit: Int = 4) -> [Candidate] {
        let words = words(query)
        guard !words.isEmpty else { return [] }
        var seen = Set<String>()
        return Array(candidates.filter { candidate in
            let haystack = [candidate.name, candidate.model, candidate.agentName, candidate.agent].joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) } && seen.insert(id(agent: candidate.agent, model: candidate.model)).inserted
        }.prefix(limit))
    }
}
