import Foundation

/// A chat message's own markup, read the way the chat apps show it, the same for every app: *bold*, _italic_,
/// ~strikethrough~ and `code` (WhatsApp and Slack write them like this; **bold** and __italic__ as Markdown has them),
/// links written as Markdown ("[label](https://…)", as Instagram's shared reels and posts come in), ```code blocks```,
/// quotes ("> …") and lists ("• …", "- …", "1. …"). Foundation only, so it can be tested anywhere;
/// `ChatMessageText` draws it.
enum ChatFormat {
    /// A piece of text with its style.
    struct Span: Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var strike = false
        var code = false
        /// Where it leads, for a link written as Markdown: `text` is then what it shows (its label, or a short form of
        /// the address when the label is the address itself).
        var link: URL? = nil
    }

    /// One line or block of a message.
    enum Block: Equatable, Sendable {
        case paragraph([Span])
        case quote([Span])
        /// A list item: its marker ("•", "1.") and its text.
        case item(String, [Span])
        case code(String)
    }

    /// The blocks of a message: lines in a row of the same kind stay together. Kept per text: every bubble asks for
    /// them each time it is drawn, and opening a chat draws dozens at once.
    static func blocks(_ text: String) -> [Block] {
        let key = text as NSString
        if let kept = blocksCache.object(forKey: key) { return kept.value }
        let made = parse(text)
        blocksCache.setObject(Kept(made), forKey: key, cost: textCost(key))
        return made
    }

    /// A web or mail address in a message, for "Copy link" and "Copy email address" in its menu.
    struct Address: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case link, email }
        var kind: Kind
        /// What is copied: a link as the message writes it (or where a Markdown link leads), a mail address without
        /// "mailto:".
        var text: String
    }

    /// The web and mail addresses in a message, in the order they come, each once; none in code. Kept per text: the
    /// detector is costly and a bubble's menu asks for them each time it is drawn.
    static func addresses(_ text: String) -> [Address] {
        guard text.contains(".") || text.contains("](") else { return [] }
        let key = text as NSString
        if let kept = addressCache.object(forKey: key) { return kept.value }
        var found: [Address] = []
        func add(_ address: Address?) {
            if let address, !address.text.isEmpty, !found.contains(address) { found.append(address) }
        }
        for block in blocks(text) {
            let spans: [Span]
            switch block {
            case .paragraph(let line), .quote(let line), .item(_, let line): spans = line
            case .code: continue
            }
            for span in spans where !span.code {
                if let link = span.link {
                    add(address(link, written: nil))
                    continue
                }
                guard span.text.contains("."), let detector = addressDetector else { continue }
                let written = span.text as NSString
                for match in detector.matches(in: span.text, range: NSRange(location: 0, length: written.length)) {
                    guard let url = match.url else { continue }
                    add(address(url, written: written.substring(with: match.range)))
                }
            }
        }
        addressCache.setObject(Kept(found), forKey: key, cost: textCost(key))
        return found
    }

    /// A web link (http, https) or a mail address; nil for anything else (a phone number, a file).
    private static func address(_ url: URL, written: String?) -> Address? {
        switch url.scheme?.lowercased() {
        case "mailto":
            var mail = written ?? url.absoluteString
            if mail.lowercased().hasPrefix("mailto:") { mail = String(mail.dropFirst("mailto:".count)) }
            mail = String(mail.split(separator: "?", maxSplits: 1).first ?? "")
            return Address(kind: .email, text: mail.removingPercentEncoding ?? mail)
        case "http", "https":
            return Address(kind: .link, text: written ?? url.absoluteString)
        default:
            return nil
        }
    }

    private static let addressDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static let addressCache: NSCache<NSString, Kept<[Address]>> = textCache("chatFormat.addresses")

    /// A cache of what was worked out per message text: at most 2 000 texts and `textCacheBytes`, so a few very long
    /// messages cannot hold megabytes, and emptied when macOS runs low on memory.
    private static func textCache<Value: AnyObject>(_ name: String) -> NSCache<NSString, Value> {
        let cache = NSCache<NSString, Value>()
        cache.countLimit = 2_000
        cache.totalCostLimit = textCacheBytes
        MemoryPressure.shared.register(name) { [cache] _ in cache.removeAllObjects() }
        return cache
    }

    private static let textCacheBytes = 4 * 1024 * 1024

    /// About what an entry holds: the text as its key (UTF-16) and what was made from it, of about the same size.
    private static func textCost(_ key: NSString) -> Int { key.length * 4 + 64 }

    /// A value an `NSCache` can hold.
    final class Kept<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let blocksCache: NSCache<NSString, Kept<[Block]>> = textCache("chatFormat.blocks")

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(spans(paragraph.joined(separator: "\n")))) }
            if !quote.isEmpty { blocks.append(.quote(spans(quote.joined(separator: "\n")))) }
            paragraph = []
            quote = []
        }
        var lines = text.components(separatedBy: "\n")[...]
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                // A code block runs to the next ``` (on the same line or a later one), or to the end.
                var body = String(trimmed.dropFirst(3))
                if let end = body.range(of: "```") {
                    blocks.append(.code(String(body[..<end.lowerBound])))
                    let rest = String(body[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if !rest.isEmpty { paragraph.append(rest) }
                    continue
                }
                var code: [String] = body.isEmpty ? [] : [body]
                while let next = lines.popFirst() {
                    if let end = next.range(of: "```") {
                        body = String(next[..<end.lowerBound])
                        if !body.isEmpty { code.append(body) }
                        break
                    }
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = listItem(trimmed) {
                flush()
                blocks.append(.item(item.marker, spans(item.text)))
            } else {
                if !quote.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Nothing that shows: only spaces, line breaks and invisible marks (a zero-width space, a direction mark, a lone
    /// variation selector). A message with only that and no file is no bubble of its own.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.properties.isWhitespace || scalar.properties.isVariationSelector
                || [.format, .control].contains(scalar.properties.generalCategory)
        }
    }

    /// The message as plain text, without its markup: for a chat's line in a list and for what is copied. Kept per text:
    /// the Chats tab asks it for every chat's newest message each time it lists them.
    static func plain(_ text: String) -> String {
        let key = text as NSString
        if let kept = plainCache.object(forKey: key) { return kept as String }
        let made = unstyled(text)
        plainCache.setObject(made as NSString, forKey: key, cost: textCost(key))
        return made
    }

    private static let plainCache: NSCache<NSString, NSString> = textCache("chatFormat.plain")

    private static func unstyled(_ text: String) -> String {
        blocks(text).map { block in
            switch block {
            case .paragraph(let spans), .quote(let spans): return spans.map(\.text).joined()
            case .item(let marker, let spans): return marker + " " + spans.map(\.text).joined()
            case .code(let code): return code
            }
        }.joined(separator: "\n")
    }

    /// "• milk", "- milk", "* milk", "1. milk", "2) milk" as a list item; a bold "*word*" is no item.
    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        for bullet in ["• ", "- ", "* ", "◦ ", "▪ "] where line.hasPrefix(bullet) {
            let text = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : ("•", text)
        }
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (String(digits) + ".", text)
    }

    /// The styled pieces of a text. A marker only counts around a word: "*bold*" is bold, "5 * 3 * 2" and
    /// "file_name_here" are not, and a web address is left as it is.
    static func spans(_ text: String) -> [Span] {
        var result: [Span] = []
        var plain = ""
        var index = text.startIndex
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("["), let found = markdownLink(text, at: index) {
                if !plain.isEmpty { result.append(Span(text: plain)) }
                plain = ""
                result.append(found.0)
                index = found.1
            } else if rest.hasPrefix("http://") || rest.hasPrefix("https://") {
                let end = rest.firstIndex(where: \.isWhitespace) ?? text.endIndex
                plain += text[index..<end]
                index = end
            } else if let found = styled(text, at: index) {
                if !plain.isEmpty { result.append(Span(text: plain)) }
                plain = ""
                result += found.0
                index = found.1
            } else {
                plain.append(text[index])
                index = text.index(after: index)
            }
        }
        if !plain.isEmpty { result.append(Span(text: plain)) }
        return result
    }

    /// A Markdown link that starts at `index` ("[label](https://…)"), as one span, and where it ends. Only a web or mail
    /// address counts as its target; anything else stays the text it is.
    private static func markdownLink(_ text: String, at index: String.Index) -> (Span, String.Index)? {
        let rest = text[text.index(after: index)...]
        guard let close = rest.range(of: "](")?.lowerBound else { return nil }
        let label = rest[..<close]
        guard !label.contains("\n"), !label.contains("[") else { return nil }
        let target = rest[rest.index(close, offsetBy: 2)...]
        guard let end = target.firstIndex(of: ")") else { return nil }
        let address = String(target[..<end])
        guard !address.contains(where: \.isWhitespace), let url = URL(string: address),
              ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let shown = label.trimmingCharacters(in: .whitespaces)
        let isAddress = shown.isEmpty || shown.hasPrefix("http://") || shown.hasPrefix("https://")
        return (Span(text: isAddress ? shortLink(url) : shown, link: url), text.index(after: end))
    }

    /// What a web address in a message leads to, for how the chat shows it under the text: a picture, a video or a
    /// sound file shows as itself, any other page as a preview card of its title and picture.
    enum LinkKind: Equatable, Sendable {
        case image, video, audio, page
    }

    /// The first web address in a message (written out, or as a Markdown link), for its preview; nil when it has none.
    /// Kept per text, as a bubble asks for it on every draw.
    static func firstLink(_ text: String) -> URL? {
        guard text.contains("http") else { return nil }
        let key = text as NSString
        if let kept = linkCache.object(forKey: key) { return kept.value }
        let found = findLink(text)
        linkCache.setObject(Kept(found), forKey: key, cost: textCost(key))
        return found
    }

    private static let linkCache: NSCache<NSString, Kept<URL?>> = textCache("chatFormat.links")

    private static func findLink(_ text: String) -> URL? {
        for block in blocks(text) {
            let spans: [Span]
            switch block {
            case .paragraph(let found), .quote(let found), .item(_, let found): spans = found
            case .code: continue
            }
            for span in spans where !span.code {
                if let link = span.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") { return link }
                guard let start = span.text.range(of: "https://") ?? span.text.range(of: "http://") else { continue }
                let rest = span.text[start.lowerBound...]
                let end = rest.firstIndex(where: { $0.isWhitespace || $0 == ">" || $0 == ")" }) ?? rest.endIndex
                var address = String(rest[..<end])
                // A sentence's own punctuation is no part of the address.
                while let last = address.last, ".,;:!?\"'".contains(last) { address.removeLast() }
                if let url = URL(string: address), url.host != nil { return url }
            }
        }
        return nil
    }

    /// The kind of a link by its file's extension; anything without a known one is a page.
    static func linkKind(_ url: URL) -> LinkKind {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp": return .image
        case "mp4", "mov", "m4v", "webm": return .video
        case "mp3", "m4a", "aac", "wav", "ogg", "opus", "flac": return .audio
        default: return .page
        }
    }

    /// A page whose preview is a video (a YouTube, Vimeo, TikTok or Instagram reel link): its card has a play mark.
    static func isVideoPage(_ url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        return ["youtube.com", "youtu.be", "vimeo.com", "tiktok.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            || (host.hasSuffix("instagram.com") && (path.hasPrefix("/reel") || path.hasPrefix("/tv/")))
    }

    /// A web address as a chat shows it in a line: its site and path without "https://", "www." or the query, cut short
    /// when long ("instagram.com/reel/DevP29EPzQg").
    static func shortLink(_ url: URL) -> String {
        guard url.scheme?.lowercased() != "mailto" else { return url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }
        let full = host + path
        return full.count > 48 ? String(full.prefix(47)) + "…" : full
    }

    /// The styled pieces that start at `index`, if a marker opens there, and where they end.
    private static func styled(_ text: String, at index: String.Index) -> ([Span], String.Index)? {
        let rest = text[index...]
        // A marker opens at the start, or after a space or punctuation, never inside a word.
        if index > text.startIndex {
            let before = text[text.index(before: index)]
            if before.isLetter || before.isNumber { return nil }
        }
        for (marker, style) in [("`", "code"), ("**", "bold"), ("__", "italic"), ("*", "bold"), ("_", "italic"), ("~", "strike")] {
            guard rest.hasPrefix(marker) else { continue }
            let inner = rest.dropFirst(marker.count)
            guard let first = inner.first, !first.isWhitespace, first != marker.first else { continue }
            guard let close = closing(marker, in: inner, code: style == "code") else { continue }
            let body = String(inner[..<close])
            let end = inner.index(close, offsetBy: marker.count)
            // It closes before a space or punctuation, never inside a word ("a*b*c" stays as it is).
            if end < text.endIndex, text[end].isLetter || text[end].isNumber { continue }
            if style == "code" { return ([Span(text: body, code: true)], end) }
            // Styles inside styles ("*_both_*") keep both.
            var spans = Self.spans(body)
            for i in spans.indices {
                switch style {
                case "bold": spans[i].bold = true
                case "italic": spans[i].italic = true
                default: spans[i].strike = true
                }
            }
            return (spans, end)
        }
        return nil
    }

    /// Where a marker closes on the same line: not right after a space (that is no closing marker).
    private static func closing(_ marker: String, in text: Substring, code: Bool) -> String.Index? {
        var search = text.startIndex
        while let range = text.range(of: marker, range: search..<text.endIndex) {
            let body = text[..<range.lowerBound]
            if body.contains("\n") { return nil }
            if let last = body.last, code || !last.isWhitespace { return range.lowerBound }
            search = range.upperBound
        }
        return nil
    }
}

/// A call as a chat notes it among the messages: voice or video, missed or not, who rang and how long it lasted, as far
/// as its app says. Every app's call reads the same way (`ChatFormat.call`) and shows as the same row in the chat.
struct ChatCall: Equatable, Sendable {
    var video = false
    /// Nobody answered (or it was declined).
    var missed = false
    /// You rang; nil when the app's line does not say, and the side of the message tells.
    var outgoing: Bool? = nil
    /// How long it lasted, when the app says.
    var seconds: Double? = nil

    /// What the chat calls it: "Video call", or "Missed voice call" for one you did not answer.
    func title(mine: Bool) -> String {
        if missed, !(outgoing ?? mine) { return tr(video ? "chat.call.missedVideo" : "chat.call.missedVoice") }
        return tr(video ? "chat.call.video" : "chat.call.voice")
    }

    /// The line under it: who rang, and how long it lasted or that nobody answered ("Incoming · 2:13").
    func detail(mine: Bool) -> String {
        let way = tr((outgoing ?? mine) ? "chat.call.outgoing" : "chat.call.incoming")
        if let seconds, seconds > 0, !missed { return "\(way) · \(Self.clock(seconds))" }
        if missed, outgoing ?? mine { return "\(way) · \(tr("chat.call.noAnswer"))" }
        return way
    }

    /// One line for the chat list and for Nook: "📞 Missed voice call".
    func summary(mine: Bool) -> String { "📞 " + title(mine: mine) }

    /// "0:42", "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, rest) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// The line an app's call reads as when it brings no words of its own (Telegram): `ChatFormat.call` reads it back.
    var line: String {
        var words = [missed ? "Missed" : (outgoing == true ? "Outgoing" : outgoing == false ? "Incoming" : ""),
                     video ? "video call" : "voice call"].filter { !$0.isEmpty }.joined(separator: " ")
        if let seconds, seconds > 0, !missed { words += " (\(Self.clock(seconds)))" }
        return words
    }
}

/// Someone coming into a group or going out of it, as its app notes it among the messages ("Ruben added David", "Anna
/// left"). Every app's change is put in this shape by its bridge and shows as the same centred line in the chat; it
/// counts as no new message and brings up no card (`InboxMessage.isIncoming`).
struct ChatMembership: Codable, Equatable, Sendable {
    enum Change: String, Codable, Sendable {
        /// Someone (`by`) added them.
        case added
        /// Someone (`by`) removed them.
        case removed
        /// They came in: by themselves, or the app does not say who added them.
        case joined
        /// They left by themselves.
        case left
        /// They are no longer in it, and the app does not say whether they left or were removed.
        case gone
    }

    var change: Change
    /// Who added or removed them, by name (`ChatMembership.me` for you); nil when the app does not say.
    var by: String?
    /// Who came in or went, by name (`ChatMembership.me` for you).
    var people: [String]

    /// You, among `by` and `people`: the line says "You" or "you" in your language.
    static let me = "\u{1}me"

    /// What the app says, put plainly: someone who added or removed only themselves joined or left, and an addition or
    /// removal without who did it is only a coming in or a going out. Names without letters are left out.
    init(_ change: Change, by: String? = nil, people: [String]) {
        let people = people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var unique: [String] = []
        for person in people where !unique.contains(person) { unique.append(person) }
        let by = by.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        self.people = unique
        self.by = by
        self.change = change
        let byThemselves = by.map { unique == [$0] } ?? false
        switch change {
        case .added where by == nil || byThemselves:
            self.change = .joined
            self.by = nil
        case .removed where byThemselves:
            self.change = .left
            self.by = nil
        case .removed where by == nil:
            self.change = .gone
        default:
            break
        }
    }

    /// The line the chat shows, in your language: "Ruben added David and Anna", "You removed Jan", "Ruben added you",
    /// "Anna left". A coming in or going out of several people is a sentence each, as some languages say it per person.
    var line: String {
        let names = people.isEmpty ? [tr("chat.member.someone")] : people
        switch change {
        case .added, .removed:
            let key = change == .added ? "chat.member.added" : "chat.member.removed"
            let by = self.by ?? tr("chat.member.someone")
            if by == Self.me { return tr(key + "ByYou", Self.list(names)) }
            if names == [Self.me] { return tr(key + "You", by) }
            return tr(key, by, Self.list(names))
        case .joined, .left, .gone:
            let key = "chat.member." + change.rawValue
            return names.map { $0 == Self.me ? tr(key + "You") : tr(key, $0) }.joined(separator: " · ")
        }
    }

    /// "David", "David and Anna", "David, Anna and you".
    static func list(_ names: [String]) -> String {
        // You last, as a person says it.
        let shown = names.filter { $0 != me } + (names.contains(me) ? [tr("chat.member.you")] : [])
        guard shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + tr("chat.member.and") + shown.last!
    }
}

/// A change to a group itself, as its app notes it among the messages: a new name, description or picture, someone made
/// admin or no longer, the group made, who may write. Every app's change is put in this shape by its bridge and shows as
/// the same centred line as a change in who is in it (`ChatMembership`); it counts as no new message.
struct ChatGroupChange: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A new name (`text`).
        case renamed
        /// A new description (`text`, when the app gives it), or the description taken away (`text` empty).
        case described
        /// A new picture.
        case photo
        /// The picture taken away.
        case photoRemoved
        /// `people` made admin.
        case promoted
        /// `people` no longer admin.
        case demoted
        /// The group made (`text` its first name, when the app says).
        case created
        /// Only admins may write now.
        case adminsOnly
        /// Everyone may write again.
        case everyone
        /// A message pinned to the top of the chat (`text` the start of it, when the app says).
        case pinned
        /// Messages now disappear after `text` seconds; "0" (or nothing) turns that off.
        case disappearing
    }

    var kind: Kind
    /// Who did it, by name (`ChatMembership.me` for you); nil when the app does not say.
    var by: String? = nil
    /// The new name or description.
    var text: String? = nil
    /// Who was made admin or no longer, by name (`ChatMembership.me` for you).
    var people: [String] = []

    init(_ kind: Kind, by: String? = nil, text: String? = nil, people: [String] = []) {
        self.kind = kind
        self.by = by.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        self.text = text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        self.people = people.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// The line the chat shows, in your language: "Ruben changed the group name to “Club”", "You changed the group
    /// description", "Anna is now an admin".
    var line: String {
        let who: String? = by
        func said(_ key: String, _ args: CVarArg...) -> String {
            // "You …" has a sentence of its own in most languages; someone else's takes their name first.
            if who == ChatMembership.me { return String(format: tr(key + "ByYou"), arguments: args) }
            let name = who ?? tr("chat.member.someone")
            return String(format: tr(key), arguments: [name] + args)
        }
        switch kind {
        case .renamed: return said("chat.group.renamed", text ?? "")
        case .described:
            // No text: the app does not say what it says now. An empty one: it was taken away.
            return text == "" ? said("chat.group.descriptionRemoved") : said("chat.group.described")
        case .photo: return said("chat.group.photo")
        case .photoRemoved: return said("chat.group.photoRemoved")
        case .created:
            guard let text, !text.isEmpty else { return said("chat.group.created") }
            return said("chat.group.createdNamed", text)
        case .adminsOnly: return said("chat.group.adminsOnly")
        case .everyone: return said("chat.group.everyone")
        case .pinned:
            guard let text, !text.isEmpty else { return said("chat.group.pinned") }
            return said("chat.group.pinnedText", String(text.prefix(60)))
        case .disappearing:
            let seconds = Double(text ?? "") ?? 0
            guard seconds > 0 else { return said("chat.group.disappearingOff") }
            return said("chat.group.disappearing", Self.duration(seconds))
        case .promoted, .demoted:
            let key = kind == .promoted ? "chat.group.promoted" : "chat.group.demoted"
            let names = people.isEmpty ? [tr("chat.member.someone")] : people
            return names.map { $0 == ChatMembership.me ? tr(key + "You") : tr(key, $0) }.joined(separator: " · ")
        }
    }
}

extension ChatGroupChange {
    /// "7 days", "24 hours", "1 hour, 30 minutes", in your language.
    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = seconds >= 7 * 86_400 && seconds.truncatingRemainder(dividingBy: 7 * 86_400) == 0
            ? [.weekOfMonth] : [.day, .hour, .minute, .second]
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: NookDates.appLocale)
        formatter.calendar = calendar
        return formatter.string(from: seconds) ?? "\(Int(seconds)) s"
    }
}

/// What a chat's app says about the chat itself besides its messages, shown in its info (`ChatInfoButton`): a group's
/// description, its admins, when and by whom it was made, whether only admins write; a person's own line (bio, status),
/// username, number, address and job title. Every field is nil while its app does not say it; names are as the chat shows
/// them. A newer read keeps what it does not say again (`merged(over:)`).
struct ChatProfile: Codable, Equatable, Sendable {
    /// A group's description or topic; a person's bio, status or "about" line.
    var about: String? = nil
    /// Who set the description, and when.
    var aboutBy: String? = nil
    var aboutSince: Date? = nil
    /// When the group was made, and by whom.
    var created: Date? = nil
    var createdBy: String? = nil
    /// The group's admins (owners too) by name, `ChatMembership.me` for you.
    var admins: [String]? = nil
    /// Only admins may write in it.
    var adminsOnly: Bool? = nil
    /// Only admins may change its name, description and picture.
    var locked: Bool? = nil
    /// A person's username ("@anna"), phone number, address and job title, as their app shows them.
    var username: String? = nil
    var phone: String? = nil
    var email: String? = nil
    var title: String? = nil
    /// How many people are in it, when the app counts them without listing them all (a large channel).
    var memberCount: Int? = nil
    /// The name a person gave themselves in the app (WhatsApp's push name, a display name), when it differs from how
    /// the chat names them.
    var ownName: String? = nil
    /// A business: its verified name, kind, address and website.
    var business: String? = nil
    var category: String? = nil
    var address: String? = nil
    var website: String? = nil
    /// Where they are and their own time zone, as their app says ("Amsterdam", "Europe/Amsterdam").
    var location: String? = nil
    var timeZone: String? = nil
    /// You blocked them in the app.
    var blocked: Bool? = nil
    /// A bot or an app rather than a person.
    var bot: Bool? = nil
    /// Verified by the app (a blue check, a verified business).
    var verified: Bool? = nil
    /// A web address that opens the chat or invites to it (a public username's or group's link).
    var link: String? = nil
    /// Messages disappear after this many seconds; 0 when that is off.
    var disappearAfter: Double? = nil

    var isEmpty: Bool { self == ChatProfile() }

    /// This read over what was known: what it says wins, what it leaves out stays.
    func merged(over old: ChatProfile?) -> ChatProfile {
        guard let old else { return self }
        var merged = self
        merged.about = about ?? old.about
        merged.aboutBy = aboutBy ?? old.aboutBy
        merged.aboutSince = aboutSince ?? old.aboutSince
        merged.created = created ?? old.created
        merged.createdBy = createdBy ?? old.createdBy
        merged.admins = admins ?? old.admins
        merged.adminsOnly = adminsOnly ?? old.adminsOnly
        merged.locked = locked ?? old.locked
        merged.username = username ?? old.username
        merged.phone = phone ?? old.phone
        merged.email = email ?? old.email
        merged.title = title ?? old.title
        merged.memberCount = memberCount ?? old.memberCount
        merged.ownName = ownName ?? old.ownName
        merged.business = business ?? old.business
        merged.category = category ?? old.category
        merged.address = address ?? old.address
        merged.website = website ?? old.website
        merged.location = location ?? old.location
        merged.timeZone = timeZone ?? old.timeZone
        merged.blocked = blocked ?? old.blocked
        merged.bot = bot ?? old.bot
        merged.verified = verified ?? old.verified
        merged.link = link ?? old.link
        merged.disappearAfter = disappearAfter ?? old.disappearAfter
        return merged
    }

    /// Text without anything in it is no text: a blank description is none.
    static func text(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

extension ChatFormat {
    /// A message that is a call: the line an app puts in the chat for one ("Incoming call", "Missed video call",
    /// "Gemiste spraakoproep", "Appel vocal (2:13)"), in English, Dutch, German, French and Spanish. Nil for anything
    /// else, also a sentence that only talks about calling ("Call me?").
    static func call(_ text: String) -> ChatCall? {
        guard text.count <= 60, !text.contains("?"), !text.contains("\n") else { return nil }
        let lower = text.lowercased()
        var call = ChatCall()
        if let clock = lower.range(of: #"\d{1,2}:\d{2}(:\d{2})?"#, options: .regularExpression) {
            let parts = lower[clock].split(separator: ":").compactMap { Double($0) }
            call.seconds = parts.reduce(0) { $0 * 60 + $1 }
        } else if let minutes = lower.range(of: #"\d+\s*min"#, options: .regularExpression) {
            call.seconds = Double(lower[minutes].prefix { $0.isNumber }).map { $0 * 60 }
        }
        let words = lower.split { !$0.isLetter }.map(String.init)
            .filter { !Self.callUnits.contains($0) }
        guard !words.isEmpty, words.contains(where: Self.callWords.contains),
              words.allSatisfy({ Self.callWords.contains($0) || Self.callModifiers.contains($0) }),
              words.contains(where: Self.callModifiers.contains) || call.seconds != nil else { return nil }
        call.video = words.contains { $0.hasPrefix("video") || $0.hasPrefix("vidéo") }
        call.missed = words.contains(where: Self.missedWords.contains)
        if words.contains(where: Self.incomingWords.contains) { call.outgoing = false }
        if words.contains(where: Self.outgoingWords.contains) { call.outgoing = true }
        return call
    }

    private static let callWords: Set<String> = [
        "call", "anruf", "sprachanruf", "videoanruf", "gruppenanruf", "oproep", "spraakoproep", "videooproep",
        "groepsoproep", "gesprek", "videogesprek", "spraakgesprek", "appel", "llamada", "videollamada", "facetime",
    ]
    private static let missedWords: Set<String> = [
        "missed", "declined", "gemiste", "gemist", "geweigerde", "geweigerd", "verpasster", "verpasst", "abgelehnter",
        "abgelehnt", "manqué", "refusé", "perdida", "rechazada",
    ]
    private static let incomingWords: Set<String> = ["incoming", "inkomende", "inkomend", "eingehender", "eingehend", "entrant", "entrante"]
    private static let outgoingWords: Set<String> = ["outgoing", "uitgaande", "uitgaand", "ausgehender", "ausgehend", "sortant", "saliente"]
    private static let callModifiers: Set<String> = missedWords.union(incomingWords).union(outgoingWords).union([
        "voice", "audio", "video", "group", "spraak", "groeps", "vocal", "vidéo", "de", "voz", "grupal",
        // One word that already says which kind of call it is ("Videoanruf", "Spraakoproep").
        "sprachanruf", "videoanruf", "spraakoproep", "videooproep", "videogesprek", "spraakgesprek", "videollamada",
    ])
    /// The words of a duration ("2 min", "45 sec"), left out before the rest is read.
    private static let callUnits: Set<String> = [
        "min", "mins", "minute", "minutes", "minuut", "minuten", "minuto", "minutos", "sec", "secs", "s", "second",
        "seconds", "seconde", "seconden", "sekunde", "sekunden", "secondes", "segundo", "segundos", "h", "hr", "uur", "std",
    ]
}

/// Tags by number ("@31612345678", as WhatsApp and the apps bridged to it write them) by name, the same for every chat
/// app: each app gives `named(_:name:)` its own way to find who a number is. Slack, Teams, Telegram, Messages and Signal
/// write a tag by name already.
enum ChatMentions {
    /// The text with every tag a name is known for as "@Name"; a tag nobody knows keeps its number. A tag is "@" and six
    /// digits at least, not glued to a word before it (a mail address) or to more digits after.
    static func named(_ text: String, name: (String) -> String?) -> String {
        guard text.contains("@") else { return text }
        var result = ""
        var rest = text[...]
        while let at = rest.firstIndex(of: "@") {
            result += rest[..<at]
            let digits = rest[rest.index(after: at)...].prefix { $0.isASCII && $0.isNumber }
            let glued = at > text.startIndex && text[text.index(before: at)].isLetter
            if digits.count >= 6, !glued, let found = name(String(digits)) {
                result += "@" + found
            } else {
                result += rest[at..<digits.endIndex]
            }
            rest = rest[digits.endIndex...]
        }
        return result + rest
    }

    /// How a number is looked up: its last nine digits, as Contacts matches a number with or without its country code.
    /// Nil for something too short to be a number.
    static func key(_ number: String) -> String? {
        let digits = number.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 6 else { return nil }
        return String(digits.suffix(9))
    }
}

/// Someone a message can tag: their name as the chat shows it and their id in their app (a WhatsApp JID, a Slack user
/// id, a Telegram user id, a Teams user id, a Matrix user id for the chat helper). Apps without tags use the name.
struct ChatTagPerson: Equatable, Sendable {
    var name: String
    var id: String
}

/// Tagging someone from Nook, the same in every chat app: "@" in the answer field lists the chat's people
/// (`typing(in:)`, `matches`), choosing one writes "@Name" (`inserting`), and on its way out each app turns every
/// "@Name" into its own tag (`replacing`, `found`): "@31612345678" for WhatsApp, "<@U1>" for Slack, a mention entity for
/// Telegram, a mention for Teams, a Matrix pill for the chat helper. Messages, Snapchat and Mail have no tags: there
/// "@Name" goes as words.
enum ChatTags {
    /// The tag being typed at the end of the text: what follows its "@" ("" right after it). Nil when the text does not
    /// end in one: no "@" at a word's start, or a new line after it.
    static func typing(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let query = text[text.index(after: at)...]
        guard !query.contains(where: \.isNewline), query.count <= 40, !query.hasPrefix(" ") else { return nil }
        return String(query)
    }

    /// The people whose name, or a word of it, starts with `query` (any case, any accents), each once, at most `limit`.
    static func matches(_ query: String, in people: [ChatTagPerson], limit: Int = 6) -> [ChatTagPerson] {
        let wanted = fold(query)
        var seen = Set<String>()
        return Array(people.filter { person in
            guard !person.name.isEmpty, seen.insert(person.name).inserted else { return false }
            guard !wanted.isEmpty else { return true }
            let name = fold(person.name)
            return name.hasPrefix(wanted) || name.split(separator: " ").contains { $0.hasPrefix(wanted) }
        }.prefix(limit))
    }

    /// The text with the tag being typed at its end replaced by "@Name " for `person`.
    static func inserting(_ person: ChatTagPerson, in text: String) -> String {
        guard let at = text.lastIndex(of: "@") else { return text + "@" + person.name + " " }
        return String(text[..<at]) + "@" + person.name + " "
    }

    /// Every "@Name" of someone in `people`, in the order they stand: "@" at a word's start, then a name (the longest
    /// that fits, any case) that does not go on into a longer word.
    static func found(in text: String, people: [ChatTagPerson]) -> [(range: Range<String.Index>, person: ChatTagPerson)] {
        let named = people.filter { !$0.name.isEmpty }.sorted { $0.name.count > $1.name.count }
        guard !named.isEmpty, text.contains("@") else { return [] }
        var result: [(range: Range<String.Index>, person: ChatTagPerson)] = []
        var index = text.startIndex
        while let at = text[index...].firstIndex(of: "@") {
            let start = text.index(after: at)
            index = start
            if at > text.startIndex, text[text.index(before: at)].isLetter || text[text.index(before: at)].isNumber { continue }
            let rest = text[start...]
            for person in named {
                guard let end = rest.index(rest.startIndex, offsetBy: person.name.count, limitedBy: rest.endIndex),
                      rest[rest.startIndex..<end].compare(person.name, options: [.caseInsensitive]) == .orderedSame else { continue }
                if end < text.endIndex, text[end].isLetter || text[end].isNumber { continue }
                result.append((at..<end, person))
                index = end
                break
            }
        }
        return result
    }

    /// The text with every "@Name" written as `write` makes it for that person.
    static func replacing(in text: String, people: [ChatTagPerson], with write: (ChatTagPerson) -> String) -> String {
        var result = ""
        var last = text.startIndex
        for tag in found(in: text, people: people) {
            result += text[last..<tag.range.lowerBound]
            result += write(tag.person)
            last = tag.range.upperBound
        }
        return result + text[last...]
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }
}
