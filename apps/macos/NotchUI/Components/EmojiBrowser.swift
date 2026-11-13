import SwiftUI

/// Every emoji to choose from, as a chat app's emoji picker: a search on top (English names, and Nook's own names in
/// your language where it has them), a tab per group (smileys, people, animals…) that jumps there, and the emoji in a
/// grid under the name of their group. The ones you use most come first, under "Frequently used" (see `EmojiUsage`), and
/// lead a search's results. The one already chosen is marked. Used by the reaction picker's "+" under a chat bubble and
/// by the composer's smiley, for every chat integration.
struct EmojiBrowser: View {
    /// The emoji already chosen (your reaction), marked in the grid.
    var chosen: String? = nil
    let choose: (String) -> Void

    static let recentGroup = "emoji.group.recent"

    @State private var query = ""
    @State private var group = EmojiCatalog.groups.first?.id ?? ""
    /// The ones you use most, read when the picker opens: choosing one while it is open does not move them under the
    /// pointer.
    @State private var recent: [EmojiCatalog.Emoji] = []
    @FocusState private var searching: Bool

    private static let columnCount = 9
    private static let cell: CGFloat = 32
    private let columns = Array(repeating: GridItem(.fixed(EmojiBrowser.cell), spacing: NookTheme.Spacing.xxs),
                                count: EmojiBrowser.columnCount)

    private var results: [EmojiCatalog.Emoji] {
        EmojiUsage.shared.usedFirst(EmojiCatalog.search(query), character: \.character)
    }

    /// Counts the choice (not taking your reaction back), then passes it on.
    private func pick(_ character: String) {
        if character != chosen { EmojiUsage.shared.record(character) }
        choose(character)
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                searchField
                if query.isEmpty { tabs(proxy) }
                ScrollView(showsIndicators: true) {
                    if query.isEmpty {
                        LazyVStack(alignment: .leading, spacing: NookTheme.Spacing.sm, pinnedViews: [.sectionHeaders]) {
                            if !recent.isEmpty {
                                Section {
                                    grid(recent)
                                } header: {
                                    header(Self.recentGroup)
                                }
                                .id(Self.recentGroup)
                            }
                            ForEach(EmojiCatalog.groups) { group in
                                Section {
                                    grid(group.emoji)
                                } header: {
                                    header(group.id)
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
        .onAppear {
            recent = EmojiUsage.shared.ranked().map(EmojiCatalog.emoji(for:))
            if !recent.isEmpty { group = Self.recentGroup }
            searching = true
        }
    }

    private func header(_ key: String) -> some View {
        Text(tr(key))
            .font(NookTheme.TextStyle.label)
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.vertical, NookTheme.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NookTheme.surface)
            .accessibilityAddTraits(.isHeader)
    }

    private var searchField: some View {
        NookSearchField(prompt: tr("emoji.search"), text: $query, focus: $searching,
                        onSubmit: { if let first = results.first { pick(first.character) } })
    }

    /// A tab per group, after a clock for the ones you use most (when there are any): a click jumps to it.
    private func tabs(_ proxy: ScrollViewProxy) -> some View {
        let tabs = (recent.isEmpty ? [] : [(id: Self.recentGroup, symbol: "clock")])
            + EmojiCatalog.groups.map { (id: $0.id, symbol: $0.symbol) }
        return HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(tabs, id: \.id) { tab in
                EmojiGroupTab(symbol: tab.symbol, label: tr(tab.id), selected: tab.id == group) {
                    group = tab.id
                    withAnimation(NookTheme.scroll) { proxy.scrollTo(tab.id, anchor: .top) }
                }
            }
        }
    }

    private func grid(_ emoji: [EmojiCatalog.Emoji]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            ForEach(emoji) { emoji in
                EmojiCell(emoji: emoji, chosen: emoji.character == chosen) { pick(emoji.character) }
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
            Image(icon: symbol)
                .font(NookTheme.font(12, .semibold))
                .foregroundStyle(selected ? NookTheme.paper : (hovering ? NookTheme.textStrong : NookTheme.textTertiary))
                .frame(width: 30, height: 26)
                .hoverRowFill($hovering, selected: selected, radius: NookTheme.Radius.chip)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
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
                .roundedBackground(chosen ? NookTheme.mint.opacity(0.2) : (hovering ? NookTheme.smoke : Color.clear),
                                   radius: NookTheme.Radius.control)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .onHover { hovering = $0 }
        .help(emoji.name)
        .accessibilityLabel(emoji.name)
    }
}
