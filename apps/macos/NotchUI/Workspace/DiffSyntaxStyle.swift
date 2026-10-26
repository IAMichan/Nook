import SwiftUI

/// Syntax-colored lines for `DiffText`: tokenized off the main thread (`DiffSyntax`), turned into attributed lines with
/// `NookTheme.Syntax` colors, and kept per file and content hash, so flipping back to a diff shows its colors at once.
enum DiffSyntaxStyle {
    /// Colored lines by row index; a row without tokens is left to `DiffText`'s plain rendering.
    typealias Lines = [Int: AttributedString]

    static let cache = BoundedCache<DiffSyntax.Key, Lines>(limit: 40)

    /// The colored lines of a diff, from the cache or worked out in a detached task (the diff is parsed again there, so
    /// nothing but the text crosses threads).
    static func lines(for text: String, path: String?, key: DiffSyntax.Key) async -> Lines {
        if let cached = cache.value(for: key) { return cached }
        let lines = await Task.detached(priority: .utility) { build(text: text, path: path) }.value
        cache.set(lines, for: key)
        return lines
    }

    private static func build(text: String, path: String?) -> Lines {
        let rows = UnifiedDiff.rows(text)
        var result: Lines = [:]
        for (index, tokens) in DiffSyntax.tokens(rows: rows, path: path) {
            guard !Task.isCancelled else { return [:] }
            let row = rows[index]
            let units = Array(row.text.utf16)
            let tint: Color? = row.kind == .add ? NookTheme.mint : row.kind == .remove ? NookTheme.coral : nil
            var line = AttributedString()
            for segment in DiffSyntax.segments(length: units.count, tokens: tokens, changed: tint == nil ? nil : row.changed) {
                var part = AttributedString(String(decoding: units[segment.start..<segment.end], as: UTF16.self))
                if let kind = segment.kind { part.foregroundColor = color(kind) }
                // The changed part of an edited line keeps its stronger tint, as in the plain rendering.
                if segment.changed, let tint { part.backgroundColor = tint.opacity(0.32) }
                line += part
            }
            result[index] = line
        }
        return result
    }

    static func color(_ kind: SyntaxToken.Kind) -> Color {
        switch kind {
        case .keyword: return NookTheme.Syntax.keyword
        case .string: return NookTheme.Syntax.string
        case .comment: return NookTheme.Syntax.comment
        case .number: return NookTheme.Syntax.number
        case .type: return NookTheme.Syntax.type
        case .property: return NookTheme.Syntax.property
        case .tag: return NookTheme.Syntax.tag
        case .attribute: return NookTheme.Syntax.attribute
        }
    }
}
