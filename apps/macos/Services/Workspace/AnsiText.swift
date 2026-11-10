import Foundation

/// A command's output with its terminal colors read from the SGR escape codes (`ESC[31m`, `ESC[1;32m`, 256 colors and
/// RGB), so a tool call's output shows red errors and green passes as the terminal did, instead of raw `[31m` codes.
/// Other escape codes are dropped, and a line a progress bar redraws with `\r` keeps only how it ended (as
/// `CommandConsole.output` does for plain text). Foundation only: the view turns the spans into colored text.
enum AnsiText {
    /// One of the terminal's 16 colors (0–7 normal, 8–15 bright), a 256-color index, or an RGB value.
    enum Color: Equatable, Sendable {
        case palette(Int)
        case rgb(UInt8, UInt8, UInt8)
    }

    struct Span: Equatable, Sendable {
        var text: String
        var color: Color? = nil
        var bold = false
        var dim = false
    }

    private static let escape = try? NSRegularExpression(
        pattern: "\u{1B}(?:\\[([0-9;?]*)([ -/]*)([@-~])|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[()][A-Za-z0-9])")

    /// Whether the text holds escape codes at all; without them it shows as it is.
    static func hasCodes(_ text: String) -> Bool { text.contains("\u{1B}") }

    /// The text in runs of one look each; codes other than colors and weight are left out.
    static func spans(_ raw: String) -> [Span] {
        let text = collapseReturns(raw)
        guard hasCodes(text), let escape else { return text.isEmpty ? [] : [Span(text: text)] }
        var spans: [Span] = []
        var current = Span(text: "")
        let ns = text as NSString
        var cursor = 0

        func flush() {
            guard !current.text.isEmpty else { return }
            if let last = spans.last, last.color == current.color, last.bold == current.bold, last.dim == current.dim {
                spans[spans.count - 1].text += current.text
            } else {
                spans.append(current)
            }
            current.text = ""
        }

        for match in escape.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.range.location > cursor {
                current.text += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            }
            cursor = match.range.location + match.range.length
            // Only "ESC [ … m" sets the look.
            guard match.range(at: 3).location != NSNotFound, ns.substring(with: match.range(at: 3)) == "m" else { continue }
            flush()
            let parameters = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            apply(parameters, to: &current)
        }
        if cursor < ns.length { current.text += ns.substring(from: cursor) }
        flush()
        return spans
    }

    /// The text without any escape codes.
    static func plain(_ raw: String) -> String { spans(raw).map(\.text).joined() }

    private static func apply(_ parameters: String, to span: inout Span) {
        var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: span.color = nil; span.bold = false; span.dim = false
            case 1: span.bold = true
            case 2: span.dim = true
            case 22: span.bold = false; span.dim = false
            case 30...37: span.color = .palette(code - 30)
            case 90...97: span.color = .palette(code - 90 + 8)
            case 39: span.color = nil
            case 38:
                // 38;5;n (256 colors) or 38;2;r;g;b.
                if index + 2 < codes.count, codes[index + 1] == 5 {
                    span.color = .palette(max(0, min(255, codes[index + 2])))
                    index += 2
                } else if index + 4 < codes.count, codes[index + 1] == 2 {
                    let clamp = { (value: Int) in UInt8(max(0, min(255, value))) }
                    span.color = .rgb(clamp(codes[index + 2]), clamp(codes[index + 3]), clamp(codes[index + 4]))
                    index += 4
                }
            case 48:
                // Backgrounds are not drawn; skip their arguments.
                if index + 1 < codes.count { index += codes[index + 1] == 5 ? 2 : codes[index + 1] == 2 ? 4 : 0 }
            default: break
            }
            index += 1
        }
    }

    /// `\r\n` as a line break, and of a line a progress bar redrew with `\r`, only what it showed last.
    private static func collapseReturns(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard text.contains("\r") else { return text }
        return text.components(separatedBy: "\n").map { line in
            line.components(separatedBy: "\r").last { !$0.isEmpty } ?? ""
        }.joined(separator: "\n")
    }
}
