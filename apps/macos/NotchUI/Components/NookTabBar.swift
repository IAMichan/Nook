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
        var help: String? = nil
        var id: Value { value }
    }

    let items: [Item]
    let selected: Value
    let onSelect: (Value) -> Void
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    onSelect(item.value)
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = item.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                        Text(item.title).lineLimit(1)
                        if item.fresh { Circle().fill(NookTheme.iris).frame(width: 5, height: 5) }
                    }
                    .font(NookTheme.font(13, .medium))
                    .foregroundStyle(item.value == selected ? NookTheme.paper : NookTheme.textTertiary)
                    .padding(.horizontal, 12)
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
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(item.value == selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.white.opacity(0.04)))
    }
}
