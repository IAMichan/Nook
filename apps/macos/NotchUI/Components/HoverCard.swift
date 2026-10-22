import SwiftUI

/// The card a list row shows on hover, as in the Claude app: a title, then a few lines with an icon each.
/// Used by the session rows in the Agents tab and the conversation rows in the Chat tab.
struct HoverCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(title)
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, NookTheme.Spacing.xxs)
            content
        }
        .padding(NookTheme.Spacing.lg + NookTheme.Spacing.xxs)
        .frame(minWidth: 220, maxWidth: 320, alignment: .leading)
        .background(DropdownStyle.panel)
        .accessibilityElement(children: .combine)
    }
}

/// One line of a hover card: an SF Symbol and a single line of text, cut in the middle when it is too long.
struct HoverCardRow: View {
    let symbol: String
    let text: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            Image(systemName: symbol)
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 16)
            Text(text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(NookTheme.TextStyle.detail)
        .foregroundStyle(NookTheme.textSecondary)
        .help(help ?? "")
    }
}

/// Opens a card next to the view once the pointer rests on it a moment, so sweeping over a list stays quiet.
/// A click closes it again.
private struct HoverCardModifier<Card: View>: ViewModifier {
    let arrowEdge: Edge
    let card: () -> Card
    @State private var hovering = false
    @State private var showCard = false
    @State private var delay: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                schedule(inside)
            }
            .simultaneousGesture(TapGesture().onEnded { schedule(false) })
            .onDisappear { delay?.cancel() }
            .popover(isPresented: $showCard, arrowEdge: arrowEdge) { card() }
    }

    private func schedule(_ inside: Bool) {
        delay?.cancel()
        guard inside else {
            showCard = false
            return
        }
        delay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled, hovering { showCard = true }
        }
    }
}

extension View {
    /// Shows `card` in a popover after the pointer rests on this view for a moment.
    func hoverCard<Card: View>(arrowEdge: Edge = .trailing, @ViewBuilder _ card: @escaping () -> Card) -> some View {
        modifier(HoverCardModifier(arrowEdge: arrowEdge, card: card))
    }
}
