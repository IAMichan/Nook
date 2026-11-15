import SwiftUI

/// A small symbol in its color, a title, and the line under it, with room at the end for what goes with it (a tag, a
/// button, a check): an MCP server's tool, a card's choice, why Nook's answer failed, a project to add. The symbol stands
/// on the title's baseline, so it lines up however tall the title's font is.
struct IconDetailRow<Trailing: View>: View {
    let symbol: String
    var tint: Color = NookTheme.textSecondary
    /// The symbol's point size; a row with a larger title takes a larger one.
    var symbolSize: CGFloat = 12
    let title: String
    var detail: String?
    /// The most lines the detail takes, nil for all of it; a path cut to one line is cut in the middle.
    var detailLines: Int?
    var detailTruncation: Text.TruncationMode = .tail
    @ViewBuilder var trailing: () -> Trailing

    init(symbol: String, tint: Color = NookTheme.textSecondary, symbolSize: CGFloat = 12, title: String,
         detail: String? = nil, detailLines: Int? = nil, detailTruncation: Text.TruncationMode = .tail,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.symbolSize = symbolSize
        self.title = title
        self.detail = detail
        self.detailLines = detailLines
        self.detailTruncation = detailTruncation
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
            Image(icon: symbol)
                .font(NookTheme.font(symbolSize, .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(detailLines)
                        .truncationMode(detailTruncation)
                        .fixedSize(horizontal: false, vertical: detailLines == nil)
                }
            }
            Spacer(minLength: NookTheme.Spacing.md)
            trailing()
        }
    }
}

extension IconDetailRow where Trailing == EmptyView {
    init(symbol: String, tint: Color = NookTheme.textSecondary, symbolSize: CGFloat = 12, title: String,
         detail: String? = nil, detailLines: Int? = nil, detailTruncation: Text.TruncationMode = .tail) {
        self.init(symbol: symbol, tint: tint, symbolSize: symbolSize, title: title, detail: detail,
                  detailLines: detailLines, detailTruncation: detailTruncation) { EmptyView() }
    }
}
