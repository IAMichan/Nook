import SwiftUI

/// One number with what it means, on a statistics page.
struct NookStatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Label(title, systemImage: symbol).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
            Text(value).font(NookTheme.rounded(24, .semibold)).monospacedDigit().foregroundStyle(NookTheme.paper)
            Text(detail).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NookTheme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.surface))
    }
}
