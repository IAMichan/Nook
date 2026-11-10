import SwiftUI

// Draws its own colors: the 256-color cube and RGB values a command chose (listed in UIConsistencyTests.ownColors).

/// A command's output in its terminal colors (`AnsiText`), in Nook's own shades of them.
enum TerminalColors {
    private static let cache = BoundedCache<String, AttributedString>(limit: 80)

    static func attributed(_ raw: String, base: Color) -> AttributedString {
        if let hit = cache.value(for: raw) { return hit }
        var result = AttributedString()
        for span in AnsiText.spans(raw) {
            var part = AttributedString(span.text)
            part.foregroundColor = (span.color.map(color) ?? base).opacity(span.dim ? 0.6 : 1)
            if span.bold { part.font = NookTheme.mono(11, .semibold) }
            result += part
        }
        cache.set(result, for: raw)
        return result
    }

    static func color(_ color: AnsiText.Color) -> Color {
        switch color {
        case .rgb(let r, let g, let b):
            return Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .palette(let index):
            // The 16 named colors in Nook's palette; the 256-color cube and greys as they are.
            switch index {
            case 0, 8: return NookTheme.textTertiary
            case 1, 9: return NookTheme.coral
            case 2, 10: return NookTheme.mint
            case 3, 11: return NookTheme.amber
            case 4, 12: return NookTheme.blue
            case 5, 13: return NookTheme.violet
            case 6, 14: return NookTheme.iris
            case 7, 15: return NookTheme.textStrong
            case 16...231:
                let value = index - 16
                let level = { (step: Int) in step == 0 ? 0.0 : (Double(step) * 40 + 55) / 255 }
                return Color(.sRGB, red: level(value / 36), green: level(value / 6 % 6), blue: level(value % 6))
            default:
                let grey = (Double(max(0, index - 232)) * 10 + 8) / 255
                return Color(.sRGB, white: grey)
            }
        }
    }
}
