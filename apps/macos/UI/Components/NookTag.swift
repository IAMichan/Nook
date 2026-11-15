import SwiftUI

/// A short word on a soft chip beside a title, in a row or on a group heading: "Draft", "Reviews", "Recommended",
/// "Optional", "Outdated". With a `tint` the word wears that state color on a faint wash of it; without one it is a
/// neutral grey tag on `smoke`. `small` sits in a list row or a header line, `regular` beside a setting or a control.
/// A session's or a connection's status is not a tag: that is a `StatusBadgeLabel` (a mark and a word, no fill).
struct NookTag: View {
    enum Size { case small, regular }

    let text: String
    var tint: Color?
    var size: Size = .small

    init(_ text: String, tint: Color? = nil, size: Size = .small) {
        self.text = text
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Text(text)
            .font(size == .small ? NookTheme.TextStyle.caption : NookTheme.TextStyle.label)
            .foregroundStyle(tint ?? NookTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, size == .small ? NookTheme.Spacing.xs : NookTheme.Spacing.sm)
            .padding(.vertical, size == .small ? 1 : NookTheme.Spacing.xxs)
            .roundedBackground(tint.map { $0.opacity(0.14) } ?? NookTheme.smoke, radius: NookTheme.Radius.chip)
            .fixedSize()
    }
}
