import Foundation

/// HTML character references decoded in one pass: numeric ones ("&#233;", "&#xE9;") and the named ones mail, chat apps,
/// GitHub and web pages use. One pass decodes each reference once, so an escaped one stays text: "&amp;lt;" is "&lt;",
/// not "<". Unknown names are left as they are.
enum HTMLEntities {
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "rarr": "→", "larr": "←", "check": "✓", "times": "×",
    ]

    private static let reference = try? NSRegularExpression(pattern: "&(?:#([0-9]{1,7})|#[xX]([0-9A-Fa-f]{1,6})|([A-Za-z]{2,8}));")

    static func decode(_ text: String) -> String {
        guard text.contains("&"), let reference else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in reference.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let value = value(of: match, in: source) else { continue }
            result += source.substring(with: NSRange(location: last, length: match.range.location - last)) + value
            last = NSMaxRange(match.range)
        }
        guard last > 0 else { return text }
        return result + source.substring(from: last)
    }

    private static func value(of match: NSTextCheckingResult, in source: NSString) -> String? {
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : source.substring(with: range)
        }
        if let name = group(3) { return named[name] }
        guard let code = group(1).flatMap({ UInt32($0) }) ?? group(2).flatMap({ UInt32($0, radix: 16) }),
              let scalar = Unicode.Scalar(code) else { return nil }
        return String(Character(scalar))
    }
}
