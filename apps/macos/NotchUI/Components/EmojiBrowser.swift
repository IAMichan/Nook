import SwiftUI

/// Every emoji to choose from, as a chat app's emoji picker: a search on top (English names, and Nook's own names in
/// your language where it has them), a tab per group (smileys, people, animals…) that jumps there, and the emoji in a
/// grid under the name of their group. The one already chosen is marked. Used by the reaction picker's "+" under a chat
/// bubble.
struct EmojiBrowser: View {
    /// The emoji already chosen (your reaction), marked in the grid.
    var chosen: String? = nil
    let choose: (String) -> Void

    @State private var query = ""
    @State private var group = EmojiCatalog.groups.first?.id ?? ""
    @FocusState private var searching: Bool

    private static let columnCount = 9
    private static let cell: CGFloat = 32
    private let columns = Array(repeating: GridItem(.fixed(EmojiBrowser.cell), spacing: NookTheme.Spacing.xxs),
                                count: EmojiBrowser.columnCount)

    private var results: [EmojiCatalog.Emoji] { EmojiCatalog.search(query) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                searchField
                if query.isEmpty { tabs(proxy) }
                ScrollView(showsIndicators: true) {
                    if query.isEmpty {
                        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm, pinnedViews: [.sectionHeaders]) {
                            ForEach(EmojiCatalog.groups) { group in
                                Section {
                                    grid(group.emoji)
                                } header: {
                                    Text(tr(group.id))
                                        .font(NookTheme.TextStyle.caption)
                                        .foregroundStyle(NookTheme.textTertiary)
                                        .padding(.vertical, NookTheme.Spacing.xxs)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(NookTheme.surface)
                                        .accessibilityAddTraits(.isHeader)
                                }
                                .id(group.id)
                            }
                        }
                    } else if results.isEmpty {
                        Text(tr("emoji.noMatch", query))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, NookTheme.Spacing.xl)
                    } else {
                        grid(results)
                    }
                }
                .frame(height: 260)
            }
        }
        // The grid, and room for the scroll bar beside it.
        .frame(width: CGFloat(Self.columnCount) * (Self.cell + NookTheme.Spacing.xxs) + NookTheme.Spacing.lg)
        .padding(NookTheme.Spacing.md)
        .background(NookTheme.surface)
        .onAppear { searching = true }
    }

    private var searchField: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
                .accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(tr("emoji.search")).foregroundStyle(NookTheme.textTertiary))
                .textFieldStyle(.plain)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .focused($searching)
                .onSubmit { if let first = results.first { choose(first.character) } }
            if !query.isEmpty {
                ToolbarIconButton("xmark.circle.fill", tr("emoji.clear")) { query = "" }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, NookTheme.Spacing.sm)
        .cardBackground(NookTheme.field, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.control)
    }

    /// A tab per group: a click jumps to it.
    private func tabs(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(EmojiCatalog.groups) { group in
                EmojiGroupTab(symbol: group.symbol, label: tr(group.id), selected: group.id == self.group) {
                    self.group = group.id
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(group.id, anchor: .top) }
                }
            }
        }
    }

    private func grid(_ emoji: [EmojiCatalog.Emoji]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ForEach(emoji) { emoji in
                EmojiCell(emoji: emoji, chosen: emoji.character == chosen) { choose(emoji.character) }
            }
        }
    }
}

private struct EmojiGroupTab: View {
    let symbol: String
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(selected ? NookTheme.paper : (hovering ? NookTheme.textStrong : NookTheme.textTertiary))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                    .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct EmojiCell: View {
    let emoji: EmojiCatalog.Emoji
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji.character)
                .font(NookTheme.font(22))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
                    .fill(chosen ? NookTheme.mint.opacity(0.2) : (hovering ? NookTheme.smoke : Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(emoji.name)
        .accessibilityLabel(emoji.name)
    }
}
