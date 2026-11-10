import Foundation

/// TeX in an answer: `$…$` and `\(…\)` inside a line, `$$…$$` and `\[…\]` on their own, outside of code. Finds it and
/// splits a text around it, so the rest stays plain text and only a message that has math pays for typesetting
/// (`MathView`, with the KaTeX that ships with Nook).
///
/// Dollar amounts stay text: an opening `$` must touch what follows it and a closing `$` what comes before it, and a
/// closing `$` followed by a digit is not one ("$5 and $10" is two prices). `\$` is a literal dollar sign.
enum MathText {
    /// Settings › Appearance › Render math (kept in sync by `AppSettings.renderMath`). Off, answers show the TeX as written.
    nonisolated(unsafe) static var renderingEnabled = true

    enum Piece: Equatable {
        case text(String)
        case inline(String)
        case display(String)
    }

    /// A quick look before the real split: no `$` and no `\(` or `\[` means no math, which is nearly every message.
    static func mightContainMath(_ text: String) -> Bool {
        text.contains("$") || text.contains("\\(") || text.contains("\\[")
    }

    /// Whether a line of running text holds inline or display math.
    static func containsMath(_ text: String) -> Bool {
        guard renderingEnabled, mightContainMath(text) else { return false }
        return split(text).contains { if case .text = $0 { return false } else { return true } }
    }

    /// The text in pieces: plain text and formulas, in order. Code spans (`` `…` ``) are left alone. A formula that is
    /// never closed (still streaming in) stays text until it is.
    static func split(_ text: String) -> [Piece] {
        guard mightContainMath(text) else { return [.text(text)] }
        let chars = Array(text)
        var pieces: [Piece] = []
        var plain = ""
        var i = 0

        func flush() {
            if !plain.isEmpty { pieces.append(.text(plain)) }
            plain = ""
        }

        /// The index of `closing` from `start` on, outside escapes; nil when it is not there.
        func find(_ closing: [Character], from start: Int, inline: Bool) -> Int? {
            var j = start
            while j + closing.count <= chars.count {
                if chars[j] == "\\", closing != ["\\", ")"], closing != ["\\", "]"] { j += 2; continue }
                if inline, chars[j] == "\n" { return nil }
                if Array(chars[j..<(j + closing.count)]) == closing { return j }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            // A code span: copied as it is, math markers inside included.
            if c == "`" {
                var ticks = 0
                while i + ticks < chars.count, chars[i + ticks] == "`" { ticks += 1 }
                let fence = Array(repeating: Character("`"), count: ticks)
                if let end = find(fence, from: i + ticks, inline: false) {
                    plain += String(chars[i..<(end + ticks)])
                    i = end + ticks
                } else {
                    plain += String(fence)
                    i += ticks
                }
                continue
            }
            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "$" {
                    plain.append("$")
                    i += 2
                    continue
                }
                if next == "(" || next == "[" {
                    let closing: [Character] = ["\\", next == "(" ? ")" : "]"]
                    if let end = find(closing, from: i + 2, inline: next == "("),
                       !String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flush()
                        let body = String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                        pieces.append(next == "(" ? .inline(body) : .display(body))
                        i = end + 2
                        continue
                    }
                }
                plain.append(c)
                plain.append(next)
                i += 2
                continue
            }
            if c == "$" {
                // $$…$$: display math, across lines.
                if i + 1 < chars.count, chars[i + 1] == "$" {
                    if let end = find(["$", "$"], from: i + 2, inline: false),
                       !String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flush()
                        pieces.append(.display(String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)))
                        i = end + 2
                        continue
                    }
                    plain += "$$"
                    i += 2
                    continue
                }
                // $…$: the opening one touches what follows, the closing one what precedes and no digit follows it.
                if i + 1 < chars.count, !chars[i + 1].isWhitespace, let end = inlineEnd(chars, from: i + 1) {
                    flush()
                    pieces.append(.inline(String(chars[(i + 1)..<end])))
                    i = end + 1
                    continue
                }
            }
            plain.append(c)
            i += 1
        }
        flush()
        return pieces
    }

    /// The closing `$` of an inline formula that opened before `start`.
    private static func inlineEnd(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            let c = chars[j]
            if c == "\n" { return nil }
            if c == "\\" { j += 2; continue }
            if c == "$" {
                if j + 1 < chars.count, chars[j + 1] == "$" { return nil }
                guard j > start, !chars[j - 1].isWhitespace else { return nil }
                if j + 1 < chars.count, chars[j + 1].isNumber { return nil }
                return j
            }
            j += 1
        }
        return nil
    }

    /// Text for an HTML page: `&`, `<`, `>`, `"` and `'` written as entities.
    static func escapeHTML(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// The body of a page that shows `text` with its formulas: text as escaped HTML with its bold, italic and code, each
    /// formula as an element that holds its TeX (`data-tex`) for KaTeX to typeset. `display` makes the whole text one
    /// display formula (a ```math block or a `$$` block).
    static func html(_ text: String, display: Bool = false) -> String {
        if display { return formula(text, display: true) }
        return split(text).map { piece in
            switch piece {
            case .text(let words): return inlineHTML(words)
            case .inline(let tex): return formula(tex, display: false)
            case .display(let tex): return formula(tex, display: true)
            }
        }.joined()
    }

    private static func formula(_ tex: String, display: Bool) -> String {
        "<span class=\"tex\(display ? " display" : "")\" data-tex=\"\(escapeHTML(tex))\">\(escapeHTML(tex))</span>"
    }

    /// Plain Markdown text as HTML: `**bold**`, `*italic*` / `_italic_`, `` `code` `` and line breaks; everything escaped.
    static func inlineHTML(_ text: String) -> String {
        var html = escapeHTML(text)
        func replace(_ pattern: String, _ template: String) {
            html = html.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        replace("`([^`]+)`", "<code>$1</code>")
        replace("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>")
        replace("(?<![\\w*])\\*([^*\\s][^*]*)\\*(?![\\w*])", "<em>$1</em>")
        replace("(?<!\\w)_([^_\\s][^_]*)_(?!\\w)", "<em>$1</em>")
        return html.replacingOccurrences(of: "\n", with: "<br>")
    }
}
