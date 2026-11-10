import Foundation

// Diagrams and math in a message on the phone, as on the Mac (docs/COMPANION.md, "Diagrams and math"): a message is cut
// into prose, Mermaid diagrams (```mermaid), display math ($$…$$, ```math) and paragraphs with inline math ($…$). Only
// those parts are drawn in a web view, with the scripts that ship in the app (no network); the rest stays plain text.
// Foundation only, so it is tested on the Mac (NookTests).

enum MessageSegment: Equatable, Sendable {
    /// Prose (with any other code fences) as the phone always shows it.
    case text(String)
    /// A paragraph with inline math.
    case inlineMath(String)
    /// Display math, without its delimiters.
    case math(String)
    case mermaid(String)

    /// Whether it needs the web view.
    var isRich: Bool {
        if case .text = self { return false }
        return true
    }
}

enum MessageSegments {
    static let mathFences: Set<String> = ["math", "latex", "katex", "tex"]

    /// Cheap check first: a message without a fence, `$$` or `$` is one text segment, and nothing is parsed.
    static func mayBeRich(_ text: String) -> Bool {
        text.contains("$") || text.contains("```mermaid") || text.contains("```math") || text.contains("```latex")
            || text.contains("```katex") || text.contains("```tex")
    }

    static func split(_ text: String) -> [MessageSegment] {
        guard mayBeRich(text) else { return [.text(text)] }
        var segments: [MessageSegment] = []
        var prose: [String] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            for part in paragraphs(prose) { append(part, to: &segments) }
            prose = []
        }

        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                var body: [String] = []
                var end = index + 1
                while end < lines.count, !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[end])
                    end += 1
                }
                let closed = end < lines.count
                if closed, language == "mermaid" || mathFences.contains(language) {
                    flushProse()
                    let code = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !code.isEmpty { segments.append(language == "mermaid" ? .mermaid(code) : .math(code)) }
                } else {
                    // Another fence (or one left open while the answer streams) stays text, as always.
                    prose.append(contentsOf: lines[index...min(end, lines.count - 1)])
                }
                index = end + 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                // Display math: on one line ($$x$$), or up to the line that closes it.
                let rest = String(trimmed.dropFirst(2))
                if let close = rest.range(of: "$$") {
                    let tex = rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !tex.isEmpty {
                        flushProse()
                        segments.append(.math(tex))
                        index += 1
                        continue
                    }
                } else if let end = lines[(index + 1)...].firstIndex(where: { $0.contains("$$") }) {
                    let last = lines[end]
                    let tail = last.range(of: "$$").map { String(last[..<$0.lowerBound]) } ?? ""
                    let tex = ([rest] + lines[(index + 1)..<end] + [tail]).joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tex.isEmpty {
                        flushProse()
                        segments.append(.math(tex))
                        index = end + 1
                        continue
                    }
                }
            }
            prose.append(line)
            index += 1
        }
        flushProse()
        return segments.isEmpty ? [.text(text)] : segments
    }

    /// Prose lines as paragraphs, each with its trailing blank lines, so joining them back gives the same text.
    private static func paragraphs(_ lines: [String]) -> [String] {
        var result: [String] = []
        var current: [String] = []
        var inFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            current.append(line)
            if !inFence, line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(current.joined(separator: "\n"))
                current = []
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    /// A paragraph joins the text before it, or becomes inline math when it holds some (and is not a code fence).
    private static func append(_ paragraph: String, to segments: inout [MessageSegment]) {
        let fenced = paragraph.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
        if !fenced, inlinePieces(paragraph).contains(where: \.math) {
            segments.append(.inlineMath(paragraph.trimmingCharacters(in: .whitespacesAndNewlines)))
            return
        }
        if case .text(let before)? = segments.last {
            segments[segments.count - 1] = .text(before + "\n" + paragraph)
        } else {
            segments.append(.text(paragraph))
        }
    }

    struct Piece: Equatable, Sendable {
        var text: String
        var math: Bool
    }

    /// A paragraph as text and inline math. `$…$` is math when it opens before a non-space, closes after a non-space and
    /// is not followed by a digit ("$5 and $10" stays money); `\$` is a dollar; nothing inside `code` counts.
    static func inlinePieces(_ text: String) -> [Piece] {
        let chars = Array(text)
        var pieces: [Piece] = []
        var plain = ""
        var index = 0
        var inCode = false
        while index < chars.count {
            let char = chars[index]
            if char == "`" { inCode.toggle() }
            if char == "\\", index + 1 < chars.count, chars[index + 1] == "$" {
                plain.append("$")
                index += 2
                continue
            }
            if !inCode, char == "$", index + 1 < chars.count, chars[index + 1] != "$", !chars[index + 1].isWhitespace,
               let close = closing(chars, from: index + 1) {
                if !plain.isEmpty { pieces.append(Piece(text: plain, math: false)) }
                plain = ""
                pieces.append(Piece(text: String(chars[(index + 1)..<close]), math: true))
                index = close + 1
                continue
            }
            plain.append(char)
            index += 1
        }
        if !plain.isEmpty { pieces.append(Piece(text: plain, math: false)) }
        return pieces
    }

    private static func closing(_ chars: [Character], from start: Int) -> Int? {
        var index = start
        while index < chars.count {
            let char = chars[index]
            if char == "\n" { return nil }
            if char == "\\" { index += 2; continue }
            if char == "$" {
                let before = chars[index - 1]
                let after: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                if before.isWhitespace || after == "$" { return nil }
                if let after, after.isNumber { return nil }
                return index
            }
            index += 1
        }
        return nil
    }
}

/// The page a diagram or math is drawn in: the bundled script added by the web view, nothing that can reach the network,
/// the colors of Nook's dark theme, and the height posted back so the view takes the room it needs.
enum RichPage {
    static let policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data: file:"

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The body of a segment's page; nil for plain text.
    static func body(_ segment: MessageSegment) -> String? {
        switch segment {
        case .text: return nil
        case .mermaid(let code):
            return "<pre class=\"mermaid\">\(escaped(code))</pre>"
        case .math(let tex):
            return "<div class=\"m\" data-display=\"1\" data-tex=\"\(escaped(tex))\">\(escaped(tex))</div>"
        case .inlineMath(let paragraph):
            let parts = MessageSegments.inlinePieces(paragraph).map { piece in
                piece.math ? "<span class=\"m\" data-tex=\"\(escaped(piece.text))\">\(escaped(piece.text))</span>"
                    : escaped(piece.text).replacingOccurrences(of: "\n", with: "<br>")
            }
            return "<p>" + parts.joined() + "</p>"
        }
    }

    static func html(_ segment: MessageSegment, css: String = "") -> String? {
        guard let body = body(segment) else { return nil }
        let mermaid: Bool
        if case .mermaid = segment { mermaid = true } else { mermaid = false }
        let run = mermaid
            ? "mermaid.initialize({startOnLoad:false,theme:'dark',securityLevel:'strict'});mermaid.run().then(post,post);"
            : "document.querySelectorAll('.m').forEach(function(e){try{katex.render(e.dataset.tex,e,{displayMode:e.dataset.display==='1',throwOnError:false});}catch(x){}});post();"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        <style>\(css)
        html,body{margin:0;padding:0;background:transparent;color:#F4F3F7;font:17px -apple-system;line-height:1.45;-webkit-text-size-adjust:none}
        p{margin:0}.m[data-display="1"]{overflow-x:auto;padding:4px 0}pre.mermaid{margin:0;text-align:center}
        </style></head><body>\(body)
        <script>function post(){window.webkit.messageHandlers.size.postMessage(document.body.scrollHeight);}
        window.addEventListener('load',function(){\(run)});</script></body></html>
        """
    }
}
