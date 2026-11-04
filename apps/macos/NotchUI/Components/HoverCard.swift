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
/// A click closes it again. While `suppressed` (the pointer is on the row's own buttons) it stays closed: an open popover
/// takes the first click outside it to close itself, so a click on such a button would otherwise do nothing.
private struct HoverCardModifier<Card: View>: ViewModifier {
    let arrowEdge: Edge
    let suppressed: Bool
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
            .onChange(of: suppressed) { _, _ in schedule(hovering) }
            .onDisappear { delay?.cancel() }
            // Only on the row under the pointer: a popover on every row of a long list was carried along while it
            // scrolled. Behind the view, at its size, so the card points at the same place.
            .background {
                if hovering || showCard {
                    Color.clear.popover(isPresented: $showCard, arrowEdge: arrowEdge) { card() }
                }
            }
    }

    private func schedule(_ inside: Bool) {
        delay?.cancel()
        guard inside, !suppressed else {
            showCard = false
            return
        }
        delay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            if !Task.isCancelled, hovering { showCard = true }
        }
    }
}

/// A part of a row with a card of its own: underlined as soon as the pointer is on it, so you see which part it found
/// before the card opens.
private struct DetailCardModifier<Card: View>: ViewModifier {
    let onDetail: Binding<Bool>
    let card: () -> Card
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                NookDivider(tint: NookTheme.textSecondary)
                    .offset(y: NookTheme.Spacing.xxs)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
            .pointerStyle(.link)
            .onHover { inside in
                withAnimation(NookTheme.hover) { hovering = inside }
                onDetail.wrappedValue = inside
            }
            .hoverCard(card)
    }
}

extension View {
    /// A part of a row with its own card (the changed files, the pull request): while the pointer is on it, `onDetail`
    /// is set so the row holds its own card back, and this part's card opens instead. Off: the view as it is.
    @ViewBuilder
    func detailCard<Card: View>(enabled: Bool = true, onDetail: Binding<Bool>,
                                @ViewBuilder _ card: @escaping () -> Card) -> some View {
        if enabled {
            modifier(DetailCardModifier(onDetail: onDetail, card: card))
        } else {
            self
        }
    }

    /// Shows `card` in a popover after the pointer rests on this view for a moment, unless `suppressed`.
    func hoverCard<Card: View>(arrowEdge: Edge = .trailing, suppressed: Bool = false,
                               @ViewBuilder _ card: @escaping () -> Card) -> some View {
        modifier(HoverCardModifier(arrowEdge: arrowEdge, suppressed: suppressed, card: card))
    }
}
