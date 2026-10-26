import Foundation

// Syntax colors for code in diffs: a small tokenizer for the languages agents touch most (Swift, TypeScript and
// JavaScript, Python, Rust, Go, JSON, YAML, shell, CSS, HTML and Markdown). It reads one line at a time, carrying a block
// comment or a multi-line string over to the next, and returns token ranges in UTF-16 offsets. It never has to be
// right about everything: an unknown construct simply stays plain. Foundation only, so it is tested on its own and runs
// off the main thread (`DiffSyntax`).

enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, typescript, python, rust, go, json, yaml, shell, css, html, markdown

    /// The language of a file by its name; nil for one the tokenizer does not know (it is shown plain).
    static func detect(path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc": return .shell
        default: break
        }
        switch (name as NSString).pathExtension {
        case "swift": return .swift
        case "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs": return .typescript
        case "py", "pyi": return .python
        case "rs": return .rust
        case "go": return .go
        case "json", "jsonc", "json5": return .json
        case "yml", "yaml": return .yaml
        case "sh", "bash", "zsh": return .shell
        case "css", "scss", "less": return .css
        case "html", "htm", "xml", "svg", "vue", "svelte", "plist": return .html
        case "md", "markdown", "mdx": return .markdown
        default: return nil
        }
    }
}

struct SyntaxToken: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case keyword, string, comment, number, type, property, tag, attribute
    }
    var kind: Kind
    /// UTF-16 offsets into the line.
    var start: Int
    var end: Int
}

enum SyntaxTokenizer {
    /// What a line leaves open for the next one.
    enum Carry: Equatable, Sendable {
        case none
        case blockComment
        /// Inside a string that spans lines, closed by this delimiter (Python's `"""`, a JavaScript template).
        case string(String)
        /// Inside an HTML tag whose attributes go on over several lines.
        case tag
        /// Inside a fenced code block of Markdown.
        case fence
    }

    static func tokenize(_ line: String, language: SyntaxLanguage, carry: Carry = .none) -> (tokens: [SyntaxToken], carry: Carry) {
        let units = Array(line.utf16)
        switch language {
        case .html: return html(units, carry: carry)
        case .markdown: return markdown(units, carry: carry)
        default:
            var lexer = Lexer(units: units, spec: Spec.of(language))
            return lexer.run(carry: carry)
        }
    }

    // MARK: Languages

    struct Spec {
        var lineComments: [String] = []
        var block: (open: String, close: String)? = nil
        var quotes: Set<UInt16> = [quote, apostrophe]
        /// Python's `"""` and `'''`.
        var tripleQuotes = false
        /// A backtick string may span lines (JavaScript templates, Go raw strings).
        var multilineBacktick = false
        var keywords: Set<String> = []
        /// Literals shown like numbers (true, false, nil).
        var literals: Set<String> = []
        /// A capitalized name is a type.
        var capitalizedTypes = false
        /// `@name` is an attribute (Swift attributes, Python decorators, CSS at-rules).
        var attributes = false
        /// `$name` and `${…}` are variables (shell).
        var variables = false
        /// A name or string right before `:` is a key (JSON, YAML, CSS properties).
        var keys = false
        /// `-` may belong to a name (CSS, YAML keys).
        var dashInNames = false
        /// `#fff` is a number (CSS colors).
        var hashNumbers = false
        /// `-12` is a number (JSON, YAML).
        var signedNumbers = false
        /// A `#` comment only starts at the line's start or after a space (shell, YAML: `${#x}`, `a#b`).
        var hashNeedsSpace = false

        static func of(_ language: SyntaxLanguage) -> Spec {
            switch language {
            case .swift:
                return Spec(lineComments: ["//"], block: ("/*", "*/"), quotes: [quote], tripleQuotes: true,
                            keywords: swiftKeywords, literals: ["true", "false", "nil"], capitalizedTypes: true, attributes: true)
            case .typescript:
                return Spec(lineComments: ["//"], block: ("/*", "*/"), quotes: [quote, apostrophe, backtick],
                            multilineBacktick: true, keywords: typescriptKeywords,
                            literals: ["true", "false", "null", "undefined", "NaN"], capitalizedTypes: true, attributes: true)
            case .python:
                return Spec(lineComments: ["#"], tripleQuotes: true, keywords: pythonKeywords,
                            literals: ["True", "False", "None"], capitalizedTypes: true, attributes: true)
            case .rust:
                return Spec(lineComments: ["//"], block: ("/*", "*/"), quotes: [quote], keywords: rustKeywords,
                            literals: ["true", "false"], capitalizedTypes: true)
            case .go:
                return Spec(lineComments: ["//"], block: ("/*", "*/"), quotes: [quote, apostrophe, backtick],
                            multilineBacktick: true, keywords: goKeywords, literals: ["true", "false", "nil", "iota"],
                            capitalizedTypes: true)
            case .json:
                return Spec(lineComments: ["//"], block: ("/*", "*/"), quotes: [quote], literals: ["true", "false", "null"],
                            keys: true, signedNumbers: true)
            case .yaml:
                return Spec(lineComments: ["#"], literals: ["true", "false", "null", "yes", "no", "on", "off", "~"],
                            keys: true, dashInNames: true, signedNumbers: true, hashNeedsSpace: true)
            case .shell:
                return Spec(lineComments: ["#"], keywords: shellKeywords, literals: ["true", "false"], variables: true,
                            hashNeedsSpace: true)
            case .css:
                return Spec(block: ("/*", "*/"), keywords: ["important"], attributes: true, keys: true, dashInNames: true,
                            hashNumbers: true)
            case .html, .markdown:
                return Spec()
            }
        }
    }

    // MARK: The generic lexer

    private struct Lexer {
        let units: [UInt16]
        let spec: Spec
        /// The comment markers as UTF-16, worked out once per line instead of at every character.
        let lineComments: [(text: String, units: [UInt16])]
        let blockOpen: [UInt16]?
        var tokens: [SyntaxToken] = []
        var i = 0

        init(units: [UInt16], spec: Spec) {
            self.units = units
            self.spec = spec
            lineComments = spec.lineComments.map { ($0, Array($0.utf16)) }
            blockOpen = spec.block.map { Array($0.open.utf16) }
        }

        mutating func run(carry: Carry) -> (tokens: [SyntaxToken], carry: Carry) {
            switch carry {
            case .blockComment:
                if let close = spec.block?.close, let end = find(close, from: 0) {
                    add(.comment, 0, end)
                    i = end
                } else {
                    add(.comment, 0, units.count)
                    return (tokens, .blockComment)
                }
            case .string(let delimiter):
                if let end = findClosing(delimiter, from: 0) {
                    add(.string, 0, end)
                    i = end
                } else {
                    add(.string, 0, units.count)
                    return (tokens, carry)
                }
            case .none, .tag, .fence:
                break
            }
            let n = units.count
            while i < n {
                let c = units[i]
                if isSpace(c) { i += 1; continue }
                if let comment = lineComments.first(where: { matches($0.units, at: i) }),
                   !(spec.hashNeedsSpace && comment.text == "#" && i > 0 && !isSpace(units[i - 1])) {
                    add(.comment, i, n)
                    break
                }
                if let block = spec.block, let open = blockOpen, matches(open, at: i) {
                    if let end = find(block.close, from: i + block.open.utf16.count) {
                        add(.comment, i, end)
                        i = end
                        continue
                    }
                    add(.comment, i, n)
                    return (tokens, .blockComment)
                }
                if spec.tripleQuotes, c == quote || c == apostrophe, i + 2 < n, units[i + 1] == c, units[i + 2] == c {
                    let delimiter = String(repeating: c == quote ? "\"" : "'", count: 3)
                    if let end = findClosing(delimiter, from: i + 3) {
                        add(.string, i, end)
                        i = end
                        continue
                    }
                    add(.string, i, n)
                    return (tokens, .string(delimiter))
                }
                if spec.quotes.contains(c) {
                    let start = i
                    if let end = findClosing(String(decoding: [c], as: UTF16.self), from: i + 1) {
                        i = end
                    } else {
                        add(.string, start, n)
                        if c == backtick && spec.multilineBacktick { return (tokens, .string("`")) }
                        break
                    }
                    add(spec.keys && nextIsColon(from: i) ? .property : .string, start, i)
                    continue
                }
                if isDigit(c) || (c == dot && i + 1 < n && isDigit(units[i + 1]) && (i == 0 || !isNameChar(units[i - 1])))
                    || (spec.signedNumbers && c == minus && i + 1 < n && isDigit(units[i + 1]) && (i == 0 || !isNameChar(units[i - 1]))) {
                    let start = i
                    i += 1
                    while i < n, isNameChar(units[i]) || units[i] == dot || (isSign(units[i]) && isExponent(units[i - 1])) { i += 1 }
                    add(.number, start, i)
                    continue
                }
                if spec.hashNumbers, c == hash, i + 1 < n, isHex(units[i + 1]) {
                    let start = i
                    i += 1
                    while i < n, isNameChar(units[i]) { i += 1 }
                    add(.number, start, i)
                    continue
                }
                if spec.attributes, c == at, i + 1 < n, isNameStart(units[i + 1]) {
                    let start = i
                    i += 1
                    while i < n, isNameChar(units[i]) || (spec.dashInNames && units[i] == minus) || units[i] == dot { i += 1 }
                    add(.attribute, start, i)
                    continue
                }
                if spec.variables, c == dollar, i + 1 < n {
                    let start = i
                    i += 1
                    if units[i] == openBrace {
                        while i < n, units[i] != closeBrace { i += 1 }
                        i = min(i + 1, n)
                    } else {
                        while i < n, isNameChar(units[i]) || (i == start + 1 && isSpecialVariable(units[i])) { i += 1 }
                    }
                    if i > start + 1 { add(.property, start, i) }
                    continue
                }
                if isNameStart(c) {
                    let start = i
                    i += 1
                    while i < n, isNameChar(units[i]) || (spec.dashInNames && units[i] == minus && i + 1 < n && isNameChar(units[i + 1])) {
                        i += 1
                    }
                    let word = String(decoding: units[start..<i], as: UTF16.self)
                    if spec.keywords.contains(word) {
                        add(.keyword, start, i)
                    } else if spec.literals.contains(word) {
                        add(.number, start, i)
                    } else if spec.keys && nextIsColon(from: i) {
                        add(.property, start, i)
                    } else if spec.capitalizedTypes, isUpper(units[start]) {
                        add(.type, start, i)
                    }
                    continue
                }
                i += 1
            }
            return (tokens, .none)
        }

        private mutating func add(_ kind: SyntaxToken.Kind, _ start: Int, _ end: Int) {
            guard end > start else { return }
            tokens.append(SyntaxToken(kind: kind, start: start, end: end))
        }

        private func matches(_ text: String, at index: Int) -> Bool { matches(Array(text.utf16), at: index) }

        private func matches(_ pattern: [UInt16], at index: Int) -> Bool {
            guard index + pattern.count <= units.count else { return false }
            for (offset, unit) in pattern.enumerated() where units[index + offset] != unit { return false }
            return true
        }

        /// The offset just past `text`, searching from `index`.
        private func find(_ text: String, from index: Int) -> Int? {
            var j = index
            let pattern = Array(text.utf16)
            let length = pattern.count
            while j + length <= units.count {
                if matches(pattern, at: j) { return j + length }
                j += 1
            }
            return nil
        }

        /// Like `find`, skipping delimiters escaped with a backslash.
        private func findClosing(_ delimiter: String, from index: Int) -> Int? {
            var j = index
            let pattern = Array(delimiter.utf16)
            let length = pattern.count
            while j + length <= units.count {
                if units[j] == backslash { j += 2; continue }
                if matches(pattern, at: j) { return j + length }
                j += 1
            }
            return nil
        }

        /// The next character that is not a space is a `:` (and not `::`).
        private func nextIsColon(from index: Int) -> Bool {
            var j = index
            while j < units.count, units[j] == space || units[j] == tab { j += 1 }
            guard j < units.count, units[j] == colon else { return false }
            return j + 1 >= units.count || units[j + 1] != colon
        }
    }

    // MARK: HTML

    private static func html(_ units: [UInt16], carry: Carry) -> (tokens: [SyntaxToken], carry: Carry) {
        var tokens: [SyntaxToken] = []
        let n = units.count
        var i = 0
        var inTag = carry == .tag
        func add(_ kind: SyntaxToken.Kind, _ start: Int, _ end: Int) {
            if end > start { tokens.append(SyntaxToken(kind: kind, start: start, end: end)) }
        }
        func find(_ text: String, from index: Int) -> Int? {
            let pattern = Array(text.utf16)
            var j = index
            while j + pattern.count <= n {
                if Array(units[j..<(j + pattern.count)]) == pattern { return j + pattern.count }
                j += 1
            }
            return nil
        }
        if carry == .blockComment {
            guard let end = find("-->", from: 0) else { return ([SyntaxToken(kind: .comment, start: 0, end: n)], .blockComment) }
            add(.comment, 0, end)
            i = end
        }
        while i < n {
            let c = units[i]
            if inTag {
                if isSpace(c) { i += 1; continue }
                if c == greater || (c == slash && i + 1 < n && units[i + 1] == greater) {
                    let end = c == slash ? i + 2 : i + 1
                    add(.tag, i, end)
                    i = end
                    inTag = false
                    continue
                }
                if c == quote || c == apostrophe {
                    let start = i
                    i += 1
                    while i < n, units[i] != c { i += 1 }
                    i = min(i + 1, n)
                    add(.string, start, i)
                    continue
                }
                if isNameStart(c) {
                    let start = i
                    while i < n, isNameChar(units[i]) || units[i] == minus || units[i] == colon { i += 1 }
                    add(.property, start, i)
                    continue
                }
                i += 1
                continue
            }
            if c == less, i + 3 < n, units[i + 1] == bang, units[i + 2] == minus, units[i + 3] == minus {
                guard let end = find("-->", from: i + 4) else {
                    add(.comment, i, n)
                    return (tokens, .blockComment)
                }
                add(.comment, i, end)
                i = end
                continue
            }
            if c == less, i + 1 < n, isNameStart(units[i + 1]) || units[i + 1] == slash || units[i + 1] == bang || units[i + 1] == question {
                let start = i
                i += 1
                if units[i] == slash || units[i] == bang || units[i] == question { i += 1 }
                while i < n, isNameChar(units[i]) || units[i] == minus || units[i] == colon { i += 1 }
                add(.tag, start, i)
                inTag = true
                continue
            }
            i += 1
        }
        return (tokens, inTag ? .tag : .none)
    }

    // MARK: Markdown

    private static func markdown(_ units: [UInt16], carry: Carry) -> (tokens: [SyntaxToken], carry: Carry) {
        let n = units.count
        var start = 0
        while start < n, isSpace(units[start]) { start += 1 }
        let fence = start + 2 < n && ((units[start] == backtick && units[start + 1] == backtick && units[start + 2] == backtick)
            || (units[start] == tilde && units[start + 1] == tilde && units[start + 2] == tilde))
        if fence { return ([SyntaxToken(kind: .comment, start: 0, end: n)], carry == .fence ? .none : .fence) }
        // Inside a code block nothing is Markdown.
        if carry == .fence { return ([], .fence) }
        guard start < n else { return ([], .none) }
        if units[start] == hash {
            var j = start
            while j < n, units[j] == hash { j += 1 }
            if j - start <= 6, j == n || isSpace(units[j]) { return ([SyntaxToken(kind: .keyword, start: start, end: n)], .none) }
        }
        if units[start] == greater { return ([SyntaxToken(kind: .comment, start: start, end: n)], .none) }
        var tokens: [SyntaxToken] = []
        var i = start
        // A list marker: "- ", "* ", "+ ", "1. ".
        if (units[i] == minus || units[i] == star || units[i] == plus), i + 1 < n, isSpace(units[i + 1]) {
            tokens.append(SyntaxToken(kind: .keyword, start: i, end: i + 1))
            i += 2
        } else {
            var j = i
            while j < n, isDigit(units[j]) { j += 1 }
            if j > i, j + 1 < n, units[j] == dot, isSpace(units[j + 1]) {
                tokens.append(SyntaxToken(kind: .keyword, start: i, end: j + 1))
                i = j + 2
            }
        }
        while i < n {
            let c = units[i]
            if c == backtick {
                let begin = i
                i += 1
                while i < n, units[i] != backtick { i += 1 }
                if i < n {
                    i += 1
                    tokens.append(SyntaxToken(kind: .string, start: begin, end: i))
                }
                continue
            }
            // A link's address: "](https://…)".
            if c == closeBracket, i + 1 < n, units[i + 1] == openParen {
                let begin = i + 2
                var j = begin
                while j < n, units[j] != closeParen { j += 1 }
                if j < n, j > begin { tokens.append(SyntaxToken(kind: .property, start: begin, end: j)) }
                i = j + 1
                continue
            }
            i += 1
        }
        return (tokens, .none)
    }

    // MARK: Characters

    private static let space: UInt16 = 0x20, tab: UInt16 = 0x09, quote: UInt16 = 0x22, apostrophe: UInt16 = 0x27
    private static let backtick: UInt16 = 0x60, backslash: UInt16 = 0x5C, dot: UInt16 = 0x2E, minus: UInt16 = 0x2D
    private static let plus: UInt16 = 0x2B, star: UInt16 = 0x2A, hash: UInt16 = 0x23, at: UInt16 = 0x40
    private static let dollar: UInt16 = 0x24, colon: UInt16 = 0x3A, less: UInt16 = 0x3C, greater: UInt16 = 0x3E
    private static let slash: UInt16 = 0x2F, bang: UInt16 = 0x21, question: UInt16 = 0x3F, tilde: UInt16 = 0x7E
    private static let openBrace: UInt16 = 0x7B, closeBrace: UInt16 = 0x7D, openParen: UInt16 = 0x28
    private static let closeParen: UInt16 = 0x29, closeBracket: UInt16 = 0x5D

    private static func isSpace(_ c: UInt16) -> Bool { c == space || c == tab || c == 0x0D }
    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isUpper(_ c: UInt16) -> Bool { c >= 0x41 && c <= 0x5A }
    private static func isHex(_ c: UInt16) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
    private static func isSign(_ c: UInt16) -> Bool { c == plus || c == minus }
    private static func isExponent(_ c: UInt16) -> Bool { c == 0x65 || c == 0x45 }
    private static func isSpecialVariable(_ c: UInt16) -> Bool { [0x23, 0x3F, 0x40, 0x2A, 0x21, 0x24].contains(c) || isDigit(c) }
    /// Letters, `_`, and anything beyond ASCII (names in other scripts).
    private static func isNameStart(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F }
    private static func isNameChar(_ c: UInt16) -> Bool { isNameStart(c) || isDigit(c) }

    // MARK: Keywords

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience",
        "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func",
        "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let",
        "mutating", "nonisolated", "nonmutating", "open", "operator", "override", "private", "protocol", "public", "repeat",
        "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch",
        "throw", "throws", "try", "typealias", "var", "weak", "unowned", "where", "while", "willSet", "didSet", "consuming",
        "borrowing", "sending",
    ]
    private static let typescriptKeywords: Set<String> = [
        "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger",
        "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from", "function", "get",
        "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "of", "private",
        "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "try",
        "type", "typeof", "var", "void", "while", "with", "yield",
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",
        "raise", "return", "self", "try", "while", "with", "yield",
    ]
    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if",
        "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
        "super", "trait", "type", "unsafe", "use", "where", "while",
    ]
    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto",
        "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
    ]
    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return",
        "local", "export", "readonly", "set", "unset", "source", "exit", "echo", "cd", "shift", "trap", "eval", "exec",
    ]
}

// MARK: Diffs

/// Syntax tokens for a whole diff, computed off the main thread and cached by `BoundedCache`.
enum DiffSyntax {
    /// The path of the first file a diff names ("diff --git a/x b/x", else "+++ b/x"), for its language.
    static func firstPath(in diff: String) -> String? {
        for line in diff.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            if line.hasPrefix("diff --git ") { return UnifiedDiff.filePath(String(line)) }
            if line.hasPrefix("+++ ") {
                let path = line.dropFirst(4)
                if path == "/dev/null" { continue }
                return String(path.hasPrefix("b/") ? path.dropFirst(2) : path)
            }
        }
        return nil
    }

    /// Tokens per code row (by index into `rows`). Each file section gets its own language (from its file row, or
    /// `path` for a diff of one file); a hunk or file starts with nothing carried over. Rows in a language the
    /// tokenizer does not know have no entry.
    static func tokens(rows: [UnifiedDiff.Row], path: String?) -> [Int: [SyntaxToken]] {
        var result: [Int: [SyntaxToken]] = [:]
        var language = path.flatMap(SyntaxLanguage.detect)
        var carry = SyntaxTokenizer.Carry.none
        for (index, row) in rows.enumerated() {
            switch row.kind {
            case .file:
                language = SyntaxLanguage.detect(path: row.text)
                carry = .none
            case .hunk:
                carry = .none
            case .note:
                continue
            case .context, .add, .remove:
                guard let language else { continue }
                let (tokens, next) = SyntaxTokenizer.tokenize(row.text, language: language, carry: carry)
                carry = next
                if !tokens.isEmpty { result[index] = tokens }
            }
        }
        return result
    }

    /// One run of a line with the same look: its token kind (nil: plain) and whether it is inside the changed part.
    struct Segment: Equatable, Sendable {
        var start: Int
        var end: Int
        var kind: SyntaxToken.Kind?
        var changed: Bool
    }

    /// Splits a line of `length` UTF-16 units into runs at every token and changed-range boundary, so the view can
    /// color each run once. Overlapping or out-of-range tokens are clipped; the runs always cover the whole line.
    static func segments(length: Int, tokens: [SyntaxToken], changed: Range<Int>?) -> [Segment] {
        guard length > 0 else { return [] }
        var kinds = [SyntaxToken.Kind?](repeating: nil, count: length)
        for token in tokens {
            let start = max(0, token.start), end = min(length, token.end)
            if start < end { for offset in start..<end where kinds[offset] == nil { kinds[offset] = token.kind } }
        }
        let changedRange = changed.map { max(0, $0.lowerBound)..<min(length, max($0.lowerBound, $0.upperBound)) }
        var segments: [Segment] = []
        for offset in 0..<length {
            let kind = kinds[offset]
            let inChange = changedRange?.contains(offset) ?? false
            if var last = segments.last, last.kind == kind, last.changed == inChange {
                last.end = offset + 1
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(start: offset, end: offset + 1, kind: kind, changed: inChange))
            }
        }
        return segments
    }

    /// The cache key of a diff: its file and a hash of its text, so an unchanged diff is never tokenized twice.
    struct Key: Hashable, Sendable {
        var path: String
        var length: Int
        var hash: Int

        init(path: String?, text: String) {
            self.path = path ?? ""
            length = text.utf16.count
            var hasher = Hasher()
            hasher.combine(text)
            hash = hasher.finalize()
        }
    }
}

/// A small thread-safe cache that forgets the least recently used entry once it holds `limit` of them.
final class BoundedCache<Key: Hashable, Value>: @unchecked Sendable {
    private let limit: Int
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private let lock = NSLock()

    init(limit: Int) { self.limit = max(1, limit) }

    func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    func set(_ value: Value, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        touch(key)
        while order.count > limit {
            let oldest = order.removeFirst()
            values[oldest] = nil
        }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
