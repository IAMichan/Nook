import SwiftUI

/// The row of capsule tabs at the top of the panel (Nook, Agents, Music): the selected tab sits on a lifted capsule
/// that slides to the next one. Also used for tabs inside a page, such as a pull request's Conversation, Commits and Files,
/// and the side panel's Terminal, Browser and Changes next to a session.
struct NookTabBar<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let title: String
        /// An SF Symbol before the title, such as the side panel's terminal, browser and changes.
        var symbol: String? = nil
        /// A small dot after the title when the tab has something you have not looked at yet.
        var fresh = false
        /// How many things on the tab wait for you, such as agents asking for approval: a small amber count.
        var count = 0
        var help: String? = nil
        var id: Value { value }
    }

    let items: [Item]
    let selected: Value
    let onSelect: (Value) -> Void
    /// Tabs you open yourself can be closed again: a small cross on the selected tab and the one under the pointer.
    var onClose: ((Value) -> Void)? = nil
    @Namespace private var selection
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let closable = onClose != nil
                Button {
                    onSelect(item.value)
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol { Image(systemName: symbol).font(NookTheme.font(11, .medium)) }
                        Text(item.title).lineLimit(1)
                        if item.count > 0 {
                            Text("\(item.count)")
                                .font(NookTheme.font(10, .bold))
                                .foregroundStyle(NookTheme.ink)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Capsule().fill(NookTheme.amber))
                        } else if item.fresh {
                            Circle().fill(NookTheme.iris).frame(width: 5, height: 5)
                        }
                        // Room for the cross, so a tab keeps its width when the cross appears.
                        if closable { Color.clear.frame(width: 12, height: 12) }
                    }
                    .font(NookTheme.font(13, .medium))
                    .foregroundStyle(item.value == selected ? NookTheme.paper : NookTheme.textTertiary)
                    .padding(.leading, 12)
                    .padding(.trailing, closable ? 8 : 12)
                    .padding(.vertical, 5)
                    .background {
                        if item.value == selected {
                            Capsule()
                                .fill(NookTheme.smoke)
                                .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(item.help ?? "")
                .accessibilityLabel(item.count > 0 ? item.title + ", \(item.count)" : item.title)
                .accessibilityAddTraits(item.value == selected ? .isSelected : [])
                .overlay(alignment: .trailing) {
                    if let onClose, item.value == selected || hovered == item.value {
                        Button { onClose(item.value) } label: {
                            Image(systemName: "xmark")
                                .font(NookTheme.font(8, .bold))
                                .foregroundStyle(NookTheme.textSecondary)
                                // A bigger target than the glyph, centered where the glyph is.
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                        .help(tr("tab.close"))
                        .accessibilityLabel(tr("tab.close") + " " + item.title)
                    }
                }
                .onHover { inside in
                    if inside { hovered = item.value } else if hovered == item.value { hovered = nil }
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.04)))
    }
}
